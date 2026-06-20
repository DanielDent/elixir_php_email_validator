# Elixir Hex Package: PHP `FILTER_VALIDATE_EMAIL` Bug‑for‑Bug Port — Implementation, Packaging & CI Guidance

## 0. Executive summary & what I re-verified locally

I independently re-confirmed the established ground truth on this machine (PHP 8.5.5 / Erlang OTP 28.4.2, erts‑16.3.1):

| Check | Result |
|---|---|
| `regexp1` inner pattern + `[caseless, dollar_endonly]` (byte mode) vs `filter_var(..., FILTER_VALIDATE_EMAIL)` over 31-case corpus | **Verdicts byte-identical (31/31).** When OTP output is written via `file:write_file` (no stdio translation), the *entire file* including UTF-8 subjects is byte-identical: SHA-256 `4374a4a3a93efa8d1fd38a210a3bea3e6cc2e5b745e69dda33018a2fe5249912` for both PHP and OTP output. |
| `regexp0` + `[caseless, dollar_endonly, unicode, ucp]` (UTF-8) vs `filter_var(..., FILTER_FLAG_EMAIL_UNICODE)` over 10-case unicode corpus | **Verdicts identical (10/10).** |

> Note for the verify agents: an earlier "MISMATCH" I saw was a **false alarm** — escript's `standard_io` applies Unicode IO translation to multibyte subjects on print. The *verdict column* (the only load-bearing output) matched in every case, and writing via `file:write_file/2` produces a byte-identical file. Re-checking should compare verdict columns or write raw via `file:write_file`, **not** `io:format("~s", ...)` to a UTF-8 terminal.

**The single most important finding for this port:** OTP 28 is the first release whose `re` module is backed by **PCRE2** (not the old PCRE1 8.x). On *this* machine `re:version()` returns `<<"10.47 2025-10-21">>` — the **exact same PCRE2 10.47** that PHP 8.5.5 links (`PCRE Library Version => 10.47 2025-10-21`, `PCRE Unicode Version => 16.0.0`). That version coincidence is *why* parity is currently byte-perfect, and it is also precisely the fragility a differential test suite must guard against (details in §1).

Source for C semantics (length cap, regex selection, Rushton copyright), extracted from `/tmp/lf_85.c`, function `php_filter_validate_email` (line 673):
- 320-byte pre-check: `if (Z_STRLEN_P(value) > 320) { RETURN_VALIDATION_FAILED }` (line 718), comment `/* The maximum length of an e-mail address is 320 octets, per RFC 2821. */`.
- Regex selection: `if (flags & FILTER_FLAG_EMAIL_UNICODE) { regexp = regexp0; } else { regexp = regexp1; }` (lines 709–715).
- Match on raw bytes: `pcre2_match(re, (PCRE2_SPTR)Z_STRVAL_P(value), Z_STRLEN_P(value), 0, 0, ...)` (line 732).
- Copyright comment (lines 694–696): `Copyright © Michael Rushton 2009-10 / http://squiloople.com/ / Feel free to use and redistribute this code. But please keep this copyright notice.`
Upstream: https://github.com/php/php-src/blob/PHP-8.5/ext/filter/logical_filters.c

---

## 1. Erlang `:re` vs PCRE — flag mapping, byte handling, and drift risks

### 1.1 Which PCRE does OTP's `re` bundle? (history)

`re` has always been backed by a **vendored** PCRE compiled into ERTS (no dynamic link — on this box `otool -L beam.smp` shows no `libpcre`, confirming static vendoring). The lineage:

- **PCRE1 8.x era** (OTP 17 → 27):
  - OTP 17.0 introduced PCRE **8.33** (2013); added options `ucp`, `notempty_atstart`, `no_start_optimize`. (https://www.erlang.org/patches/otp-17.0)
  - OTP 20.0 upgraded the internal PCRE **8.33 → 8.40**. (https://erlang.org/download/otp_src_20.0-rc2.readme)
  - Late OTP 27 / erts 15.2.5: "Uplift pcre 8.44 to pcre 8.45" (OTP-19565). (https://www.erlang.org/doc/apps/erts/notes.html)
  - PCRE1 was made a NIF and the team repeatedly noted PCRE1 is unmaintained. (https://github.com/erlang/otp/issues/3518)
- **PCRE2 era** (OTP 28+): OTP 28 / **erts 16.0** switched `re` to **PCRE2 10.45** (OTP-19541). Then:
  - erts 16.0.3: **10.45 → 10.46** (buffer-read-overflow fix, OTP-19755).
  - erts 16.2: **→ 10.47** (OTP-19880).
  - (Per the same notes, OTP 29 continues on PCRE2.)
  Sources: https://www.erlang.org/doc/apps/erts/notes.html ; https://www.erlang.org/blog/highlights-otp-28/ ; migration guide https://www.erlang.org/doc/apps/stdlib/re_incompat.html

**OTP 28 on this machine ships PCRE2 10.47 (Unicode 16.0.0), the same release PHP 8.5.5 links.** This is the happy case and the foundation of current parity — but the package must not *assume* it.

> An aside that earlier web search muddled: OTP at one point floated **RE2** as a candidate replacement. That did **not** happen for `re`; OTP 28 shipped **PCRE2**. RE2 lacks look-around and backreferences and could never run Rushton's regex (which is built entirely on negative look-aheads), so an RE2-backed `re` would have been a non-starter for this port. Treat any "OTP uses RE2" claim as outdated roadmap noise.

### 1.2 Precise flag → option mapping

PHP wraps both patterns as `/INNER/FLAGS`. The mapping is deterministic and total over the flags PHP actually uses:

| PHP/PCRE inline flag | Meaning | OTP `:re` option | Verified |
|---|---|---|---|
| `i` | `PCRE_CASELESS` | `caseless` | ✅ |
| `D` | `PCRE_DOLLAR_ENDONLY` (`$` matches only at very end, never before a trailing `\n`) | `dollar_endonly` | ✅ |
| `u` | `PCRE_UTF8 | PCRE_UCP` | `unicode` **and** `ucp` (both required) | ✅ |

So:
- **`regexp1`** (`/…/iD`) → `re:compile(Inner, [caseless, dollar_endonly])` — **byte mode** (no `unicode`).
- **`regexp0`** (`/…/iDu`) → `re:compile(Inner, [caseless, dollar_endonly, unicode, ucp])`.

My local parser confirms the wrapper strips cleanly: leading `/`, then `rfind('/')` splits inner from flags; `iD → [caseless, dollar_endonly]`, `iDu → [caseless, dollar_endonly, unicode, ucp]` (§2.2 has the generator).

### 1.3 Subject handling — match raw BYTES for `regexp1`, UTF‑8 for `regexp0`

PHP calls `pcre2_match` on `Z_STRVAL_P/Z_STRLEN_P` — **the raw input bytes**, with the 8-bit PCRE2 code unit width. There is no transcoding. Therefore in Elixir:

- **`regexp1` (default):** pass the **raw binary** to `re:run/3` with **no `unicode` option**. In byte mode each byte is one code unit, exactly like PHP's default. Multibyte UTF-8 is treated as opaque high bytes — which is correct: e.g. `日本語@example.com` is rejected by `regexp1` because the local-part classes (`\x21`–`\x7E` ranges) don't include bytes ≥ 0x80. (Confirmed: PHP verdict `0`, OTP verdict `0`.)
- **`regexp0` (FILTER_FLAG_EMAIL_UNICODE):** the subject must be a **valid UTF-8 binary** and you pass `[unicode, ucp]`. `\pL`/`\pN` then match Unicode letters/numbers in the local part. (Confirmed: `日本語@example.com` → `1`, `münchen@example.com` → `1`, `test@日本語.com` → `0` because the *domain* portion of the regex still only allows `[a-z0-9-]`/`xn--`.)

**Critical:** never set the `unicode` option for `regexp1`. Under PCRE2/OTP 28 the default is **pure ASCII** (not Latin-1), and `caseless`/character-properties operate strictly on bytes 0–127 — which matches PHP's byte-mode behavior. (https://www.erlang.org/doc/apps/stdlib/re_incompat.html)

Also enforce PHP's **320-octet pre-check in Elixir before matching**: `byte_size(input) > 320 -> :invalid`. Do not rely on the regex's internal `{255,}`/`{65,}` look-aheads to cover it — those are *separate* RFC-5321 local/total-length guards (I observed a 319-byte synthetic address rejected by the `{65,}@` local-part lookahead, independent of the 320 cap).

### 1.4 Drift risks (why parity today ≠ parity forever)

1. **PCRE version skew between PHP's PCRE2 and OTP's PCRE2.** PHP can be built `--with-external-pcre` (this Homebrew PHP is — its `Configure Command` shows `--with-external-pcre`, linking system PCRE2 10.47) or with its bundled PCRE2; distro PHPs vary. OTP pins its own vendored PCRE2 per release (10.45→10.46→10.47 within the OTP-28 line alone). When the two PCRE2 builds differ, behavior *can* diverge — most plausibly in:
2. **Unicode property tables (`\pL`/`\pN`) → Unicode version.** PHP 8.5.5 reports `PCRE Unicode Version => 16.0.0`; OTP's PCRE2 10.47 is built against a Unicode version too. These only affect `regexp0`. I probed a Unicode‑16 codepoint (U+10D40 Garay): **both** PHP and OTP returned no `\pL` match — i.e. they currently agree even on a v16 script. But a future OTP that ships a PCRE2 with a *newer* Unicode table than the target PHP (or vice-versa) would flip exactly such codepoints. This is the #1 long-term divergence vector and is **invisible to a small fixed corpus** unless it includes recently-added codepoints.
3. **JIT vs interpreter.** PHP enables PCRE JIT by default (`PCRE JIT Support => enabled`); OTP `re` does not JIT. JIT/interpreter must produce identical *match/no-match* results for a correct PCRE, so this is a low correctness risk — but it is a reason their performance and (theoretically) limit-related edge behavior could differ.
4. **Backtrack/recursion limits.** PHP exposes `pcre.backtrack_limit = 1000000`, `pcre.recursion_limit = 100000`. OTP `re` has its own internal limits and the `match_limit`/`match_limit_recursion` run options. On a pathological input one engine could hit a limit (returning no-match/error) where the other completes. The 320-byte cap bounds input size and makes this unlikely, but a differential fuzz suite is the only way to *know*.
5. **PCRE2 stricter syntax.** OTP 28's PCRE2 errors on constructs old PCRE tolerated. Rushton's pattern compiles cleanly today (proven), but if php-src ever edits the pattern, re-vendoring could surface a `re:compile` error — caught by the drift detector + compile-at-load (§2).

**Bottom line:** the regex strings are stable (PHP 8.4 and 8.5 `regexp0`/`regexp1` are byte-identical — I diffed them: `regexp1` 1152 bytes, `regexp0` 1185 bytes, equal). The *engine + Unicode tables underneath* are the moving parts. A **differential test matrix across real PHP versions + a fuzz differential against a live PHP** is the durable safety net; a static corpus is necessary but not sufficient.

---

## 2. Compilation strategy in Elixir

### 2.1 Compile once, reuse forever

`re:compile/2` returns an opaque `{re_pattern, ...}` tuple (confirmed locally: `element(1, MP) = re_pattern`). **Its compiled binary format is NOT portable across OTP versions or nodes** (OTP 28 release notes: "the internal format produced by `re:compile/2` has changed … cannot be reused across nodes or OTP versions"). Therefore:

- **Do NOT** persist a compiled pattern to disk or bake the compiled tuple into a module attribute that might be serialized.
- **DO** compile at runtime and cache the live tuple. Two good options:

**Option A — module attribute (compile-time), simplest.** Elixir's `Regex`/`:re` can compile at module-compile time. But because the compiled format is OTP-version-specific and module attributes are baked into the BEAM file at *your* compile time, this is only safe if the package is always compiled on the same OTP major it runs on (true for normal Hex deps compiled by the consumer). Acceptable, but `persistent_term` is more robust against cross-version surprises.

**Option B — `:persistent_term` at application start (recommended).** Compile in `Application.start/2` (or lazily on first use) and stash in `:persistent_term`, which is built for write-once/read-many global constants with zero-copy reads:

```elixir
defmodule PhpEmail.Patterns do
  @moduledoc false
  # Vendored from php-src ext/filter/logical_filters.c (see priv/php_regex/*.txt).
  @ascii_key {__MODULE__, :regexp1}
  @unicode_key {__MODULE__, :regexp0}

  def compile! do
    {inner1, opts1} = load!("regexp1")  # {pattern, [caseless, dollar_endonly]}
    {inner0, opts0} = load!("regexp0")  # {pattern, [caseless, dollar_endonly, unicode, ucp]}
    {:ok, mp1} = :re.compile(inner1, opts1)
    {:ok, mp0} = :re.compile(inner0, opts0)
    :persistent_term.put(@ascii_key, mp1)
    :persistent_term.put(@unicode_key, mp0)
    :ok
  end

  def ascii,   do: :persistent_term.get(@ascii_key)
  def unicode, do: :persistent_term.get(@unicode_key)

  defp load!(name), do: PhpEmail.Vendor.pattern_and_opts(name)
end
```

```elixir
defmodule PhpEmail do
  @max_octets 320  # RFC 2821 pre-check, mirrors php-src line 718

  @doc "Returns true iff PHP filter_var(email, FILTER_VALIDATE_EMAIL) would."
  def valid?(email, opts \\ []) when is_binary(email) do
    unicode? = Keyword.get(opts, :unicode, false)
    cond do
      byte_size(email) > @max_octets -> false
      unicode? -> match?(:match, run_unicode(email))
      true     -> match?(:match, run_ascii(email))
    end
  end

  # regexp1: raw bytes, NO unicode option
  defp run_ascii(email),   do: :re.run(email, PhpEmail.Patterns.ascii(),   [{:capture, :none}])
  # regexp0: must be valid UTF-8; unicode+ucp already compiled into the pattern
  defp run_unicode(email), do: :re.run(email, PhpEmail.Patterns.unicode(), [{:capture, :none}])
end
```

Notes:
- Pass the **raw binary** to `run_ascii` — do not convert to a charlist or apply any encoding.
- `{:capture, :none}` since we only need match/no-match (matches PHP's `rc >= 0`/`rc < 0` semantics).
- For `unicode`, you may optionally guard `String.valid?/1` first; PHP would still run PCRE2 on invalid UTF-8 and (under `u`) fail to match — test this corner explicitly if you want exact parity on malformed UTF-8.

### 2.2 Vendor the literal regex strings + a generator (don't hand-transcribe)

**Recommendation: vendor the PHP string literals verbatim, with provenance, and ship a generator that re-extracts them from a pinned php-src ref.** This keeps the PHP C source as the single source of truth and makes the pattern auditable.

Layout:
```
priv/php_regex/
  PROVENANCE.md        # php-src ref (tag php-8.5.x), URL, sha256 of logical_filters.c
  regexp0.txt          # the /…/iDu literal, exactly as in C (un-escaped to the PCRE level)
  regexp1.txt          # the /…/iD literal
```

The "un-escape" step is the one transformation: the C file stores the pattern as a **C string literal** with `\\x22`, `\\x5C`, `\\.` (doubled backslashes for C). After C parses the literal, PCRE sees `\x22`, `\x5C`, `\.`. Your `/tmp/re1.txt` and `/tmp/pat1.txt` are already at the **PCRE level** (single backslashes) — that is what you vendor and feed to `:re.compile`. The generator must perform exactly: read C → take the bytes inside `const char regexpN[] = "…";` → C-unescape (`\\` → `\`, `\"`→`"` etc.) → that's your `.txt`.

Deterministic wrapper→options parser (verified locally):

```elixir
defmodule PhpEmail.Vendor do
  @flag_map %{?i => :caseless, ?D => :dollar_endonly}

  @doc ~S"""
  Parse a vendored "/INNER/FLAGS" PHP regex literal into {inner, opts}.
  iD  -> [caseless, dollar_endonly]
  iDu -> [caseless, dollar_endonly, unicode, ucp]
  """
  def parse("/" <> _ = lit) do
    {inner, flags} = split_on_last_slash(lit)
    opts =
      flags
      |> String.to_charlist()
      |> Enum.flat_map(fn
        ?u -> [:unicode, :ucp]
        f  -> [Map.fetch!(@flag_map, f)]   # raises on any unmapped flag -> fail loud
      end)
      |> Enum.uniq()
    {inner, opts}
  end

  defp split_on_last_slash(lit) do
    body = String.slice(lit, 1..-1//1)
    idx  = body |> :binary.matches("/") |> List.last() |> elem(0)
    {binary_part(body, 0, idx), binary_part(body, idx + 1, byte_size(body) - idx - 1)}
  end

  def pattern_and_opts(name) do
    name |> read_vendored() |> parse()
  end

  defp read_vendored(name),
    do: Application.app_dir(:php_email, "priv/php_regex/#{name}.txt") |> File.read!() |> String.trim_trailing()
end
```

My Python proof of the same parse: `iD -> ['caseless', 'dollar_endonly'], inner_len=1068`; the unknown-flag path raises — that's the desired "fail loud if PHP adds a flag" behavior.

The generator (`mix php_email.gen.regex --ref php-8.5.5`) should: `curl` the pinned `logical_filters.c`, extract both literals, C-unescape, write the `.txt`s + record the source SHA-256 in `PROVENANCE.md`. This same logic powers the **drift detector** in §4.

---

## 3. Hex packaging best practices

### 3.1 Names (pick one; all convey "PHP filter_var email parity")

1. **`php_email_validator`** — most discoverable; says exactly what it is. (Check Hex for collisions first: `mix hex.search php_email`.)
2. **`filter_var_email`** — evokes the PHP API name directly; great for developers migrating from PHP.
3. **`rushton_email`** / **`squiloople`** — honors the regex's origin; quirkier, less discoverable. Prefer as an alias mention, not the primary name.

My pick: **`php_email_validator`** (primary), with the README prominently stating "byte-for-byte parity with PHP `filter_var($e, FILTER_VALIDATE_EMAIL)`."

### 3.2 Licensing & the Rushton copyright (must be preserved)

The embedded regex carries Michael Rushton's notice: `Copyright © Michael Rushton 2009-10 — Feel free to use and redistribute this code. But please keep this copyright notice.` Because the regex is redistributed in your package (in `priv/php_regex/*.txt`), you **must keep that notice**. The PHP file itself is under the PHP License 3.01 (file header, lines 1–7).

Recommended approach:
- License **your** Elixir code under a permissive license, e.g. **Apache-2.0** or **MIT** (your choice). Put it in `LICENSE`.
- Add a **`NOTICE`** file enumerating third-party content:
  ```
  This product includes a regular expression authored by Michael Rushton.

      Copyright © Michael Rushton 2009-10
      http://squiloople.com/
      Feel free to use and redistribute this code. But please keep this copyright notice.

  The regular expression is vendored from PHP's ext/filter/logical_filters.c
  (php-src), which is distributed under the PHP License v3.01:
  https://github.com/php/php-src/blob/PHP-8.5/ext/filter/logical_filters.c
  ```
- Keep the Rushton + PHP-License header **inline as a comment** at the top of `priv/php_regex/PROVENANCE.md` and reference it from `@moduledoc`.
- In `mix.exs`, declare licenses with SPDX ids. If you ship the Rushton/PHP-licensed regex, the honest set is e.g. `licenses: ["Apache-2.0", "PHP-3.01"]` (Hex shows all; Apache-2.0 covers your code, PHP-3.01 covers the vendored regex). Confirm the SPDX id `PHP-3.01` renders on hex.pm; if not, fall back to listing it in NOTICE and keep `licenses: ["Apache-2.0"]` with a prominent third-party note.

### 3.3 `mix.exs` metadata

```elixir
defmodule PhpEmailValidator.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/youruser/php_email_validator"
  # The PHP behavior generation this release targets:
  @php_target "8.1–8.5"

  def project do
    [
      app: :php_email_validator,
      version: @version,
      elixir: "~> 1.15",
      description:
        "Validate email addresses byte-for-byte identically to PHP " <>
          "filter_var($e, FILTER_VALIDATE_EMAIL) (and FILTER_FLAG_EMAIL_UNICODE). " <>
          "Targets PHP #{@php_target} behavior.",
      package: package(),
      docs: docs(),
      deps: deps(),
      name: "PhpEmailValidator",
      source_url: @source_url
    ]
  end

  def application, do: [extra_applications: [:logger], mod: {PhpEmailValidator.Application, []}]

  defp deps do
    [
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:stream_data, "~> 1.1", only: [:dev, :test]}
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0", "PHP-3.01"],
      links: %{
        "GitHub" => @source_url,
        "PHP filter_var" => "https://www.php.net/manual/en/filter.filters.validate.php",
        "Upstream regex (php-src)" =>
          "https://github.com/php/php-src/blob/PHP-8.5/ext/filter/logical_filters.c"
      },
      # Ship the vendored regex + provenance + notices; exclude test/CI noise.
      files: ~w(lib priv/php_regex mix.exs README.md LICENSE NOTICE CHANGELOG.md)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "NOTICE", "priv/php_regex/PROVENANCE.md", "CHANGELOG.md"],
      source_ref: "v#{@version}",
      source_url: @source_url
    ]
  end
end
```

### 3.4 Versioning & communicating "PHP 8.1–8.5"

- **SemVer.** A change in PHP-targeted behavior (e.g., re-vendoring a regex that php-src modified, or dropping/adding a PHP version) is at least a **minor** bump, and a **major** bump if verdicts change for previously-valid inputs. Patch = bug fixes that move you *closer* to PHP without changing already-correct verdicts.
- **State the target explicitly** in `@moduledoc`, README badge, and `CHANGELOG`: e.g. "Parity verified against PHP 8.1, 8.2, 8.3, 8.4, 8.5 (regex bytes identical across this range — `regexp0`/`regexp1` are unchanged from 8.4 to 8.5, verified)."
- **Caveat the Unicode path**: document that `FILTER_FLAG_EMAIL_UNICODE` parity depends on the Unicode tables in the runtime's PCRE2 (OTP) vs PHP's PCRE, and is verified by CI but theoretically version-sensitive (§1.4).
- Note PHP 8.1 ran on PCRE1 historically, but the **regex string is identical**; differences, if any, would be engine-level — which the CI matrix (§4) is designed to catch.

---

## 4. CI / differential-testing methodology

Two independent guarantees: **(A)** "we match real PHP" (golden differential across a PHP version matrix), and **(B)** "the vendored regex still equals upstream php-src" (drift detector). Plus **(C)** property-based fuzzing against a long-lived PHP process.

### 4.1 Job A — golden differential across PHP 8.1–8.5

Use `shivammathur/setup-php` to install each PHP, generate golden verdicts from real `filter_var` over a corpus, then assert ExUnit's Elixir output equals the golden for that PHP version.

`scripts/php_golden.php`:
```php
<?php
// Usage: php php_golden.php corpus.txt > golden.tsv  (tab: verdict \t verdict_unicode \t b64(input))
$fh = fopen($argv[1], 'r');
while (($line = fgets($fh)) !== false) {
    $s = rtrim($line, "\n");           // keep all other bytes, including UTF-8
    $a = filter_var($s, FILTER_VALIDATE_EMAIL) === false ? 0 : 1;
    $u = filter_var($s, FILTER_VALIDATE_EMAIL, FILTER_FLAG_EMAIL_UNICODE) === false ? 0 : 1;
    // base64 the input so tabs/newlines/binary survive the TSV round-trip
    fwrite(STDOUT, $a . "\t" . $u . "\t" . base64_encode($s) . "\n");
}
```

ExUnit reads the golden and diffs (base64 keeps binary/UTF-8 intact across the file boundary):
```elixir
defmodule PhpEmailValidator.GoldenTest do
  use ExUnit.Case, async: true

  golden = System.get_env("GOLDEN_FILE") || "test/golden/php-8.5.tsv"

  @cases golden
         |> File.read!()
         |> String.split("\n", trim: true)
         |> Enum.map(fn line ->
           [a, u, b64] = String.split(line, "\t")
           {Base.decode64!(b64), String.to_integer(a), String.to_integer(u)}
         end)

  for {input, exp_ascii, exp_unicode} <- @cases do
    test "ascii parity: #{Base.encode16(input)}" do
      assert (if PhpEmailValidator.valid?(unquote(input)), do: 1, else: 0) == unquote(exp_ascii)
    end

    test "unicode parity: #{Base.encode16(input)}" do
      got = if PhpEmailValidator.valid?(unquote(input), unicode: true), do: 1, else: 0
      assert got == unquote(exp_unicode)
    end
  end
end
```

`.github/workflows/parity.yml`:
```yaml
name: PHP parity
on: [push, pull_request]

jobs:
  golden:
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix:
        php: ['8.1', '8.2', '8.3', '8.4', '8.5']
    steps:
      - uses: actions/checkout@v4

      - name: Setup PHP ${{ matrix.php }}
        uses: shivammathur/setup-php@v2
        with:
          php-version: ${{ matrix.php }}
          extensions: filter
          coverage: none

      - name: Generate golden verdicts from real filter_var
        run: |
          php -r 'echo PHP_VERSION, " PCRE=", PCRE_VERSION, "\n";'
          php scripts/php_golden.php test/golden/corpus.txt > golden.tsv
          wc -l golden.tsv

      - uses: erlef/setup-beam@v1
        with:
          otp-version: '28'
          elixir-version: '1.18'

      - run: mix deps.get
      - name: Assert Elixir output matches PHP ${{ matrix.php }}
        env:
          GOLDEN_FILE: golden.tsv
        run: mix test test/golden_test.exs
```

Tips:
- `test/golden/corpus.txt` should include the §0 tricky cases **plus** recently-added Unicode codepoints (Unicode 15/16 letters and numbers) to make Unicode-table drift *visible* (§1.4). Include the 320/321-byte boundary, embedded NUL (`a@b\0c.com`), trailing newline, IP-literal forms, and quoted local parts.
- Pin `otp-version: '28'` (the first PCRE2 release) and document that older OTP (PCRE1) is **not** supported for guaranteed parity — or add OTP 26/27 to the BEAM matrix and let CI tell you whether PCRE1 also passes (it likely does for these patterns, but prove it).
- Alternatively to `setup-php`, use official `php:8.x-cli` Docker images in a container matrix; equivalent. `setup-php` is lighter on GitHub-hosted runners.

### 4.2 Job B — drift detector (vendored regex == upstream php-src)

Re-fetch `logical_filters.c` for each supported PHP release, re-extract the literals, and **fail if they differ from the vendored `.txt`**.

`.github/workflows/drift.yml`:
```yaml
name: Regex drift detector
on:
  schedule: [{ cron: '0 6 * * 1' }]   # weekly
  workflow_dispatch:
jobs:
  drift:
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix:
        ref: ['PHP-8.1', 'PHP-8.2', 'PHP-8.3', 'PHP-8.4', 'PHP-8.5']
    steps:
      - uses: actions/checkout@v4
      - name: Fetch upstream logical_filters.c
        run: |
          curl -fsSL \
            "https://raw.githubusercontent.com/php/php-src/${{ matrix.ref }}/ext/filter/logical_filters.c" \
            -o upstream.c
          echo "upstream sha256: $(sha256sum upstream.c)"
      - name: Extract regexp0/regexp1 and compare to vendored
        run: python3 scripts/extract_and_compare.py upstream.c priv/php_regex
```

`scripts/extract_and_compare.py` (mirrors the locally-verified extraction):
```python
import re, sys, codecs, pathlib

src = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
vendor = pathlib.Path(sys.argv[2])

def extract(name):
    m = re.search(r'const char ' + name + r'\[\]\s*=\s*"(.*?)";', src, re.S)
    if not m:
        sys.exit(f"FAIL: {name} not found in upstream")
    # C-unescape the literal to PCRE level (\\x22 -> \x22, \\ -> \, \" -> ")
    return codecs.decode(m.group(1), "unicode_escape").encode("latin-1").decode("latin-1")

ok = True
for name in ("regexp0", "regexp1"):
    upstream = extract(name)
    vendored = (vendor / f"{name}.txt").read_text(encoding="utf-8").rstrip("\n")
    # vendored stores the /…/FLAGS wrapper; strip it for comparison if needed
    if upstream != vendored:
        ok = False
        print(f"DRIFT in {name}:\n  upstream len={len(upstream)}\n  vendored len={len(vendored)}")
print("OK" if ok else "DRIFT DETECTED")
sys.exit(0 if ok else 1)
```

I verified the fetch and comparison work: pulling `PHP-8.4` and `PHP-8.5` and extracting both literals shows **`regexp0` and `regexp1` are byte-identical between 8.4 and 8.5** (`regexp1`=1152, `regexp0`=1185 bytes — the `const char` literal form including doubled C escapes). So today the drift detector is green across the range; if php-src ever edits the pattern, this job fails *loudly* and tells you to re-run the generator and bump the version.

### 4.3 Job C — property-based / fuzz differential (StreamData vs a long-lived PHP)

A fixed corpus can't find the divergences in §1.4. Generate random email-ish strings and diff Elixir vs PHP. For speed, keep **one** PHP process alive reading lines on stdin (avoid per-input process spawn):

`scripts/php_oracle.php` (long-lived oracle):
```php
<?php
// Reads base64 inputs, one per line; prints "ascii_verdict unicode_verdict\n".
while (($line = fgets(STDIN)) !== false) {
    $s = base64_decode(rtrim($line, "\n"));
    $a = filter_var($s, FILTER_VALIDATE_EMAIL) === false ? 0 : 1;
    $u = filter_var($s, FILTER_VALIDATE_EMAIL, FILTER_FLAG_EMAIL_UNICODE) === false ? 0 : 1;
    fwrite(STDOUT, "$a $u\n");
    flush();
}
```

StreamData property (start the port once per property run):
```elixir
defmodule PhpEmailValidator.FuzzTest do
  use ExUnit.Case
  use ExUnitProperties

  setup_all do
    port = Port.open({:spawn_executable, System.find_executable("php")},
             [:binary, {:line, 4096}, args: ["scripts/php_oracle.php"]])
    on_exit(fn -> Port.close(port) end)
    %{php: port}
  end

  # Generators that explore the interesting alphabet: ASCII specials, @, dots,
  # quotes, backslashes, brackets, IPv6 text, xn--, and multibyte UTF-8.
  defp emailish do
    pieces =
      one_of([
        string(:ascii, min_length: 0, max_length: 6),
        member_of(["@", ".", "\"", "\\", "[", "]", ":", "-", "xn--", "IPv6:", "::"]),
        member_of(["日", "ü", "α", "用户", "🎉", <<0xC3, 0x28>>]) # last = invalid UTF-8
      ])
    pieces |> list_of(max_length: 12) |> map(&IO.iodata_to_binary/1)
  end

  property "Elixir verdicts equal PHP for random email-ish strings", %{php: port} do
    check all input <- emailish(), max_runs: 5000 do
      send(port, {self(), {:command, Base.encode64(input) <> "\n"}})
      {pa, pu} = receive do
        {^port, {:data, {:eol, line}}} ->
          [a, u] = String.split(String.trim(line))
          {String.to_integer(a), String.to_integer(u)}
      after 2000 -> flunk("PHP oracle timeout")
      end

      assert (if PhpEmailValidator.valid?(input), do: 1, else: 0) == pa
      assert (if PhpEmailValidator.valid?(input, unicode: true), do: 1, else: 0) == pu
    end
  end
end
```

Run this in CI (Job C) gated behind a PHP install, with a larger `max_runs` nightly. On any mismatch, StreamData **shrinks** to a minimal failing input — exactly the kind of bug-for-bug edge case you want to capture as a permanent regression test. (Library: `stream_data` https://hexdocs.pm/stream_data.) Mind that for the `unicode: true` path, decide and document the policy on invalid UTF-8 inputs (PHP runs PCRE2 on them under `u`); the fuzzer including `<<0xC3, 0x28>>` will force you to nail that down.

---

## 5. Consolidated recommendations

1. **Engine:** target **OTP 28+ (`re` on PCRE2)**. Map `i→caseless`, `D→dollar_endonly`, `u→[unicode, ucp]`. Match `regexp1` on **raw bytes (no `unicode`)**, `regexp0` on **UTF-8 with `[unicode, ucp]`**. Enforce the **320-octet pre-check** in Elixir. Parity is byte-perfect here because OTP 28.4.2 and PHP 8.5.5 both ride **PCRE2 10.47 / Unicode 16** — verified.
2. **Compilation:** vendor the PHP regex **strings** (provenance + generator from a pinned php-src ref), parse the `/…/FLAGS` wrapper deterministically into options, compile **once at app start into `:persistent_term`** (never persist the compiled tuple — its format is OTP-version-specific).
3. **Packaging:** name **`php_email_validator`**; license your code Apache-2.0/MIT but **preserve the Rushton notice** (NOTICE + PROVENANCE + `licenses: ["Apache-2.0", "PHP-3.01"]`); rich `mix.exs` metadata + ExDoc; SemVer with explicit "targets PHP 8.1–8.5" messaging and a Unicode-path caveat.
4. **CI:** (A) **golden differential** across `setup-php` 8.1–8.5; (B) **drift detector** re-fetching `logical_filters.c` per release and failing on regex changes (today: 8.4≡8.5, green); (C) **StreamData fuzz** diffing against a long-lived PHP oracle, with shrinking → regression tests. This trio is the durable safety net against PCRE2/Unicode-version drift that no static corpus can guarantee.

### Sources
- php-src regex & C semantics: https://github.com/php/php-src/blob/PHP-8.5/ext/filter/logical_filters.c (and raw `PHP-8.4`/`PHP-8.5` refs, fetched and diffed locally)
- OTP `re` → PCRE2 migration & incompatibilities: https://www.erlang.org/doc/apps/stdlib/re_incompat.html
- OTP 28 highlights (PCRE2): https://www.erlang.org/blog/highlights-otp-28/
- ERTS release notes (PCRE2 10.45→10.46→10.47; pcre 8.44→8.45): https://www.erlang.org/doc/apps/erts/notes.html
- PCRE1 8.x history: https://www.erlang.org/patches/otp-17.0 ; https://erlang.org/download/otp_src_20.0-rc2.readme ; https://github.com/erlang/otp/issues/3518
- PHP `filter_var` docs: https://www.php.net/manual/en/filter.filters.validate.php
- Tooling: https://github.com/shivammathur/setup-php ; https://github.com/erlef/setup-beam ; https://hexdocs.pm/stream_data
- Local verifications (this run): PHP 8.5.5 `PCRE 10.47 / Unicode 16.0.0`; OTP 28.4.2 `re:version() = <<"10.47 2025-10-21">>`; regexp1 file SHA-256 parity `4374a4a3…`; regexp0 verdicts 10/10; 8.4≡8.5 regex bytes.
