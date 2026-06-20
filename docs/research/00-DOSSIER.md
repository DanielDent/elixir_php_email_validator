# RESEARCH DOSSIER: Bug-for-Bug Elixir Port of PHP `filter_var` `FILTER_VALIDATE_EMAIL`

*Lead-researcher synthesis of 5 detailed reports + 2 adversarial verifications. Compiled 2026-06-19.*

## 1. Executive Summary

- **What it actually is.** PHP's `filter_var($email, FILTER_VALIDATE_EMAIL)` is not an RFC parser — it is a **byte-size pre-check (`> 320` → reject) followed by one of two frozen PCRE regexes** (selected by the `FILTER_FLAG_EMAIL_UNICODE` flag), matched against the **raw input bytes**. The regex is a flattened, routeable-domain-only adaptation of Michael Rushton's 2009–2010 validator; PHP deliberately dropped Rushton's recursive `(?1)(?2)` CFWS/comment subroutines and require a dotted FQDN domain (so `a@b` and `user@localhost` are **rejected**). Source: [`ext/filter/logical_filters.c`](https://github.com/php/php-src/blob/master/ext/filter/logical_filters.c).
- **Cross-version stability: PROVEN.** Both regex literals and the `> 320` guard are **byte-for-byte identical across PHP 8.1, 8.2, 8.3, 8.4, 8.5 and `master`** (and unchanged back to 7.1 for the unicode variant, 5.3.10 for the ASCII variant). Verified by SHA-256 over 11–17 git refs. No regex change is staged in `master`. The last edit to either literal was **2015** (the unicode flag, commit `8f4050709c`).
- **An Elixir equivalent does NOT exist.** A Hex search for `filter_var` returns zero packages; no Hex package references `FILTER_VALIDATE_EMAIL`. Every format validator on Hex (`ecto_commons`, `email_checker`, `email_validator`, `email_address`) uses a different regex family/paradigm and was **empirically shown to disagree with PHP 8.5** on multiple input classes. Adversarial Verification 1 independently confirmed this ("confirmed", high confidence).
- **The closest near-miss confirms the gap rather than filling it.** `MailChecker` shares PHP's exact Rushton ancestry but (a) is **not on Hex**, (b) is frozen on an **older** Rushton revision that rejects valid double-hyphen domains PHP accepts (`a@b--c.com`), and (c) layers a burner blocklist on top.
- **A faithful port is achievable and proven.** Erlang/OTP 28's `:re` (now PCRE2-backed) compiling PHP's **exact extracted literals** with the correct option mapping reproduces PHP 8.5.5 verdicts **byte-identically** (31/31 ASCII corpus, 10/10 unicode corpus, 135/135 quirks corpus). This parity is the only known route to genuine bug-for-bug equivalence.
- **The fragility is the engine, not the strings.** Current parity is partly luck: OTP 28.4.2 and PHP 8.5.5 both ride **PCRE2 10.47 / Unicode 16.0.0**. The durable risks are PCRE2-version skew and Unicode-table drift (affecting only the `\pL\pN` unicode path) — invisible to a small static corpus.
- **Recommended path.** Build a new from-scratch Hex package that **vendors PHP's literal regex strings** (with provenance + a generator), enforces the 320-byte pre-check in Elixir, matches `regexp1` on raw bytes and `regexp0` on UTF-8 with `[:unicode, :ucp]`, and is guarded by a **three-job CI suite**: golden differential vs a real PHP 8.1–8.5 matrix, an upstream-diff drift detector, and StreamData fuzzing against a live PHP oracle.

## 2. The Exact PHP Algorithm

From `php_filter_validate_email` in `ext/filter/logical_filters.c` (PHP-8.5, line numbers from the extracted source):

1. **Length pre-check (C, before any regex):**
   ```c
   if (Z_STRLEN_P(value) > 320) { RETURN_VALIDATION_FAILED }
   ```
   Comment: *"The maximum length of an e-mail address is 320 octets, per RFC 2821."* This is a **byte-count** check (`byte_size`), not a character count.

2. **Regex selection by flag:**
   ```c
   if (flags & FILTER_FLAG_EMAIL_UNICODE) { regexp = regexp0; } else { regexp = regexp1; }
   ```

3. **Match on raw bytes:** `pcre2_match(re, Z_STRVAL_P(value), Z_STRLEN_P(value), 0, 0, ...)` — no transcoding. Verdict is `!== false` (match) vs `false` (no match).

**The two regexes** (post-C-unescape, including PHP `/…/FLAGS` delimiters):

- **`regexp1`** (default / ASCII), suffix **`/iD`**, SHA-256 `441ced67865bdd1975f9518c4bf41cb0c510cc7edd395769ec4acd34d384c86f`:
  ```
  /^(?!(?:(?:\x22?\x5C[\x00-\x7E]\x22?)|(?:\x22?[^\x5C\x22]\x22?)){255,})(?!(?:(?:\x22?\x5C[\x00-\x7E]\x22?)|(?:\x22?[^\x5C\x22]\x22?)){65,}@)(?:(?:[\x21\x23-\x27\x2A\x2B\x2D\x2F-\x39\x3D\x3F\x5E-\x7E]+)|(?:\x22(?:[\x01-\x08\x0B\x0C\x0E-\x1F\x21\x23-\x5B\x5D-\x7F]|(?:\x5C[\x00-\x7F]))*\x22))(?:\.(?:...))*@(?:(?:(?!.*[^.]{64,})(?:(?:(?:xn--)?[a-z0-9]+(?:-+[a-z0-9]+)*\.){1,126}){1,}(?:(?:[a-z][a-z0-9]*)|(?:(?:xn--)[a-z0-9]+))(?:-+[a-z0-9]+)*)|(?:\[(?:(?:IPv6:...)|...)\]))$/iD
  ```
- **`regexp0`** (`FILTER_FLAG_EMAIL_UNICODE`), suffix **`/iDu`**, SHA-256 `f40b5b868fe53fc3d820e4500032360528eb3c9af223753c6c197c1513bfe320`. **Identical to `regexp1` except** the four local-part character classes additionally include `\pL\pN` (any Unicode letter/number) and the `u` flag is set. **The domain part is byte-identical** — Unicode is allowed in the local part only.

**Inline flag → PCRE / Erlang `:re` option mapping** (deterministic, total over the flags PHP uses):

| PHP flag | PCRE meaning | `:re` option |
|---|---|---|
| `i` | caseless | `:caseless` |
| `D` | `DOLLAR_ENDONLY` (`$` never matches before a trailing `\n`) | `:dollar_endonly` |
| `u` | `PCRE2_UTF \| PCRE2_UCP` | `:unicode` **and** `:ucp` (both) |

So: `regexp1` → `[:caseless, :dollar_endonly]` (byte mode, no `:unicode`); `regexp0` → `[:caseless, :dollar_endonly, :unicode, :ucp]` (UTF-8 subject).

**Key behavioral consequences (from the 136-case quirks catalog, all ground-truthed on PHP 8.5.5):**
- **Effective length cap is 254, not 320.** The regex's first lookahead `(?:...){255,}` counts the *entire* string (its `[^\x5C\x22]` alternative matches almost any byte including `@` and the domain), so any structurally-valid 255+ byte address is rejected by the **regex** before the 320 C-gate ever binds. The 320 gate only short-circuits pathological/malformed input ≥ 321 bytes.
- Single-label domains (`a@b`, `user@localhost`) and bare/unbracketed IPs (`a@127.0.0.1`) are **rejected**; bracketed IPv4 (`a@[127.0.0.1]`) and IPv6 literals (`a@[IPv6:::1]`) are **accepted**.
- Quoted local parts are accepted; an unescaped space inside quotes is **rejected** (0x20 is not in the quoted class), but a backslash-escaped space is accepted. Control bytes 0x01–0x08, 0x0B, 0x0C are accepted in quotes; 0x09 (TAB), 0x0A, 0x0D are not.
- Unicode letters/numbers (`\pL\pN`) accepted in the local part **only with the flag**; the domain always stays ASCII (`test@日本語.com` rejected even with the flag). Emoji/symbols (`\pS`) and combining marks (`\pM`) are rejected even with the flag.

## 3. Cross-Version Stability Conclusion

**Conclusion: an Elixir port pinned to the PHP-8.5 literals is simultaneously correct for every PHP ≥ 7.1 (default + unicode), and for the default/ASCII verdicts of every PHP ≥ 5.3.10.**

- **Versions covered (regex + length check byte-identical):** PHP 8.1, 8.2, 8.3, 8.4, 8.5, `master` — proven across 11 refs (Report 1) and independently re-proven across 17 refs incl. tags `php-7.4.0`, `php-8.0.0` (Verification 2). Both verifications return **"confirmed", high confidence.**
- **SHA evidence (the load-bearing proof):** for every ref there is exactly **one** distinct SHA-256 per literal. Report 1's canonical hashes (post-C-unescape, including delimiters/flags) are the drift baselines: `regexp1 = 441ced67…`, `regexp0 = f40b5b86…`. The `> 320` guard with the RFC-2821 comment is byte-identical everywhere. Even the **raw C-source literal bytes** (pre-unescape) hash to one value per literal.
- **Last change to either literal:** 2015 (`8f4050709c`, unicode flag). Last change to `regexp1` was 2011 (`dfa08dc325` / bug #55478, the `-` → `-+` hyphen fix). No change is pending in `master`.
- **What to watch for drift:** monitor `ext/filter/logical_filters.c`, function `php_filter_validate_email`, the two literals `regexp1`/`regexp0`, the `Z_STRLEN_P(value) > 320` guard, and the `if (flags & FILTER_FLAG_EMAIL_UNICODE)` selection. Canonical check: fetch `https://raw.githubusercontent.com/php/php-src/<REF>/ext/filter/logical_filters.c`, re-extract, C-unescape, compare SHA-256 to the baselines above. **Beyond the strings, watch the *engine*:** PCRE2 version skew between PHP's and OTP's bundled PCRE2, and the Unicode version backing `\pL\pN` (the #1 long-term divergence vector, affecting only the unicode path).

## 4. Elixir Landscape Verdict

**No Hex package is equivalent — or close.** Empirically measured against PHP 8.5 (disagreement counts from Report 3, corroborated by Verification 1):

| Package (Hex) | Method | PHP-parity verdict | Why it diverges |
|---|---|---|---|
| **PHP `filter_var`** (reference) | Rushton PCRE `/iD` + 320-byte cap | — | — |
| `ecto_commons` `:html_input` (default) | WHATWG `<input type=email>` regex | **NO** (13/31 differ) | No IP-literal branch, no quoted-local branch, accepts `a@b`/`user@localhost`/bare IPv4, no length gate |
| `ecto_commons` `:pow` | RFC-3696 procedural parser | **NO** (11/31 differ) | Bans IP literals entirely, permits Unicode unconditionally, char-counts not byte-counts |
| `email_checker` (Format) | emailregex.com RFC-5322-style regex (+MX/SMTP) | **NO** (6/31 differ) | No IPv6-literal branch, accepts unbracketed IPv4, no 320 cap, default path does DNS/SMTP |
| `mailchecker` (**not on Hex**) | PHP-Rushton regex (older fork) + burner blocklist | **NO** | Frozen older Rushton: rejects `a@b--c.com`; uses `\A\z` not `^$/D`; bolts on a blocklist; not installable from Hex |
| `email_validator` (rbkmoney) | Erlang ABNF RFC-5321/5322 parser | **NO** (different paradigm) | Strict RFC parser, not a PHP-regex mirror |
| `email_address` (amberbit) | lenient display-name parser | **NO** (far too permissive) | `[^\s<;,]+@[^\s;,>]+`; meant for `Name <a@b>` parsing |
| `burnex` / `email_guard` | disposable-domain blocklist | **N/A** (not a validator) | No format check |

**Prior art for true parity exists only outside Elixir:** [`mpyw/FILTER_VALIDATE_EMAIL.js`](https://github.com/mpyw/FILTER_VALIDATE_EMAIL.js) (JS/TS, npm) — confirms demand, confirms the Elixir gap is unfilled. Both verification agents independently inspected actual source (not memory) and ran each candidate's real regex through OTP 28 `:re` against live PHP verdicts.

## 5. Recommendation

**Build a new from-scratch Hex package.** This is a genuine, unfilled niche; the parity method is proven; the regex is stable enough to pin.

### Proposed names
1. **`php_email_validator`** (recommended primary) — most discoverable; README must state "byte-for-byte parity with PHP `filter_var($e, FILTER_VALIDATE_EMAIL)`".
2. `filter_var_email` — evokes the PHP API directly; good for migrators.
3. `rushton_email` / `squiloople` — honors the regex origin; less discoverable, use as alias mention only.
*(Check Hex for collisions first: `mix hex.search php_email`.)*

### License / copyright handling (mandatory)
The vendored regex carries Michael Rushton's notice (*"Copyright © Michael Rushton 2009-10 — Feel free to use and redistribute this code. But please keep this copyright notice."*) and the PHP source file is under **PHP License 3.01**. Because the regex is redistributed in your package:
- License **your** Elixir code Apache-2.0 or MIT.
- Ship a **`NOTICE`** file reproducing the Rushton notice + PHP-3.01 attribution, and a `priv/php_regex/PROVENANCE.md` (php-src ref, URL, SHA-256 of `logical_filters.c`).
- In `mix.exs`: `licenses: ["Apache-2.0", "PHP-3.01"]` (verify the SPDX id `PHP-3.01` renders on hex.pm; if not, fall back to `["Apache-2.0"]` + prominent NOTICE).

### Implementation essentials
- **Vendor the literal strings, do not hand-transcribe.** Ship a `mix php_email.gen.regex --ref php-8.5.x` generator that curls `logical_filters.c`, extracts both `const char regexpN[]` literals, C-unescapes (`\\`→`\`, `\"`→`"`) to the PCRE level, and records the source SHA-256.
- **Compile once, cache the live tuple in `:persistent_term`** at app start. **Never persist the compiled `re_pattern` tuple** — its binary format is not portable across OTP versions/nodes.
- **Match `regexp1` on the raw binary with no `:unicode` option** (byte mode = PHP default); match `regexp0` on a valid-UTF-8 binary with `[:unicode, :ucp]`. Use `{:capture, :none}`.
- **Enforce `byte_size(email) > 320 -> false` in Elixir** before matching (the gate lives in C, not the regex).
- **Target OTP 28+** (first PCRE2-backed `:re`). Document that older OTP (PCRE1) is not guaranteed; optionally add OTP 26/27 to the CI matrix to let CI prove/disprove PCRE1 parity.

### Proof-of-correctness + drift-detection methodology (the durable safety net — three CI jobs)
- **Job A — Golden differential vs a real PHP matrix.** `shivammathur/setup-php` for PHP **8.1, 8.2, 8.3, 8.4, 8.5**; generate golden verdicts from real `filter_var` (both default and `FILTER_FLAG_EMAIL_UNICODE`) over a base64-encoded corpus (base64 so NUL/newlines/UTF-8 survive the file boundary); assert the Elixir output equals the golden per version. Corpus must include the quirks-catalog cases **plus recently-added Unicode 15/16 codepoints** (to make Unicode-table drift visible), the 254/255/320/321-byte boundaries, embedded NUL, trailing newline, IP literals, and quoted local parts.
- **Job B — Upstream-diff drift detector.** Weekly cron: re-fetch `logical_filters.c` for each supported ref, re-extract `regexp0`/`regexp1`, **fail loudly if they differ from the vendored `.txt`** (compare SHA-256 to `441ced67…` / `f40b5b86…`). Today this is green across 8.1–8.5. A failure means PHP changed semantics → re-run the generator and bump the version.
- **Job C — Property/fuzz differential vs a long-lived PHP oracle.** StreamData generates random email-ish strings (ASCII specials, `@`, dots, quotes, backslashes, brackets, `IPv6:`, `xn--`, multibyte UTF-8, **and invalid UTF-8** like `<<0xC3,0x28>>`) and diffs Elixir vs a single long-lived PHP process reading base64 lines on stdin. Shrunk failures become permanent regression tests. A fixed corpus cannot find engine-level drift; the fuzzer can.

## 6. Open Risks / Caveats and How the Suite Mitigates Them

| Risk | Detail | Mitigation |
|---|---|---|
| **PCRE2 version skew** | PHP can build `--with-external-pcre` (distro-varying); OTP pins its own vendored PCRE2 (10.45→10.46→10.47 *within* the OTP-28 line). Current parity relies on both being PCRE2 **10.47**. | **Job A** runs against real PHP per version, so any engine-level divergence shows up as a golden mismatch; pin/record both `PCRE_VERSION` (PHP) and `re:version()` (OTP) in CI logs. |
| **Unicode table drift (`\pL\pN`)** | Affects only `regexp0`. PHP 8.5.5 reports Unicode 16.0.0; OTP's PCRE2 has its own Unicode version. A newer/older table on either side flips exactly the newly-added codepoints — **invisible to a small fixed corpus.** | Corpus **must include recently-added Unicode 15/16 letters/numbers** (Job A); **Job C** fuzzes multibyte UTF-8. This is flagged as the #1 long-term divergence vector. |
| **Backtrack / recursion limits** | PHP exposes `pcre.backtrack_limit=1000000`, `pcre.recursion_limit=100000`; OTP `:re` has its own limits + `match_limit` run options. A pathological input could hit a limit on one engine but not the other. | The 320-byte cap bounds input size, making this unlikely; **Job C fuzzing** is the only way to *know*, and shrinking captures any minimal trigger. |
| **JIT vs interpreter** | PHP enables PCRE JIT; OTP `:re` does not. | Correctness-equivalent for a correct PCRE (low risk); covered by Jobs A/C regardless. |
| **PCRE2 stricter syntax** | If php-src ever edits the pattern, re-vendoring could surface a `re:compile` error. | **Job B** catches the upstream change; compile-at-load surfaces any compile error immediately. |
| **Invalid-UTF-8 policy on the unicode path** | PHP runs PCRE2 on malformed UTF-8 under `u`; Elixir behavior must be pinned. | **Job C** includes `<<0xC3,0x28>>`, forcing the policy to be decided, documented, and regression-tested. |

## Contradictions Between Reports and Verifications (explicitly flagged)

The reports and verifications are **mutually consistent on every load-bearing claim** (regex byte-identity, the 320-gate, no equivalent Elixir package, OTP-28 `:re` parity). The differences are clarifications/refinements, not conflicts:

1. **"Recursive `(?1)(?2)` regex was in PHP" — a shared *correction*, not a contradiction.** Reports 1 and 2 both explicitly debunk the common premise that php-src ever shipped Rushton's recursive form. php-src adopted a *flattened* variant in 2010 and has kept it flat. The recursive form lived only on squiloople.com. (Both reports agree; flagging because the task framing implied otherwise.)

2. **Different SHA-256 values across reports — different normalizations, NOT a conflict.** Report 1 / Verification 2's `regexp1=441ced67…`/`regexp0=f40b5b86…` are the canonical post-C-unescape strings **including** the `/…/iD` delimiters and flags. Report 2's `930750babe00` and Verification 2's secondary `90c656bb…`/`0a6c8fb1…` are hashes of *different representations* (raw `const char` line / C-escaped literal content). Each report's hash is internally consistent and single-valued across all refs; they are not meant to match each other. **Use Report 1's hashes as the drift baseline** (they correspond to the actual operative PCRE strings).

3. **"Currently-supported PHP versions" — a scope nuance.** Report 1 lists 8.1–8.5 as "currently-supported." Verification 2 correctly notes that as of 2026-06-19, **PHP 8.1 is EOL (since 2025-12-31)** and 8.2 is security-only; strictly only 8.2–8.5 are supported. **This does not affect the port**: the regex is byte-identical in 8.1 (and back to 7.1/7.4/8.0) anyway, so pinning to it remains valid for the entire range. (CI's matrix is endoflife-driven, so 8.1 now drops off automatically; the vendored regex stays valid for it regardless.)

4. **The 320 vs 254 effective cap — complementary, not contradictory.** Report 4 establishes the *practical* cap is 254 (the regex `{255,}` lookahead binds first); Reports 1/5 and Verification 1 describe the *documented* 320 C-gate. Both are true and both must be implemented — the 320 byte-check in Elixir code, the 254 effect emergent from the regex. Verification 1 notes it could not isolate a single input that flips *solely* at 320 (other regex constraints fire first), consistent with Report 4's finding that 320 only ever rejects pathological ≥321-byte input.

5. **OTP `:re` engine claims — Report 5 pre-empts two pieces of stale noise:** an earlier escript "MISMATCH" was a false alarm (escript stdio Unicode translation, not a verdict difference — compare verdict columns or write via `file:write_file`), and any "OTP uses RE2" claim is outdated roadmap noise (OTP 28 shipped **PCRE2**, not RE2; RE2 lacks the lookarounds Rushton's pattern requires).

---

### Primary sources cited across the dossier
- php-src file & history: https://github.com/php/php-src/blob/master/ext/filter/logical_filters.c · commit history: https://github.com/php/php-src/commits/master/ext/filter/logical_filters.c
- Pinned commits: flat-Rushton intro `fcbb8e96f4` (bug https://bugs.php.net/bug.php?id=49576) · `-`→`-+` `dfa08dc325` (bug https://bugs.php.net/bug.php?id=55478) · unicode flag / last regex change `8f4050709c` (PR https://github.com/php/php-src/pull/1577 · bug https://bugs.php.net/bug.php?id=72244 · RFC https://datatracker.ietf.org/doc/html/rfc6531) · PCRE2 swap `a5bc5aed71`
- PHP docs: https://www.php.net/manual/en/filter.filters.validate.php · https://www.php.net/manual/en/filter.constants.php · https://www.php.net/manual/en/function.filter-var.php
- OTP `:re`/PCRE2: https://www.erlang.org/doc/apps/stdlib/re_incompat.html · https://www.erlang.org/blog/highlights-otp-28/ · https://www.erlang.org/doc/apps/erts/notes.html
- Elixir landscape: https://github.com/achedeuzot/ecto_commons · https://github.com/maennchen/email_checker · https://github.com/FGRibreau/mailchecker · https://github.com/rbkmoney/email_validator · https://github.com/amberbit/email_address · https://github.com/Betree/burnex
- Prior art (other ecosystem): https://github.com/mpyw/FILTER_VALIDATE_EMAIL.js
- Tooling: https://github.com/shivammathur/setup-php · https://github.com/erlef/setup-beam · https://hexdocs.pm/stream_data
- Rushton origin: http://squiloople.com/2009/12/20/email-address-validation/ (dead/404; Wayback https://web.archive.org/web/20150910045413/http://squiloople.com/2009/)
- Security context: https://www.cvedetails.com/cve/CVE-2007-1900/ · https://seclists.org/fulldisclosure/2022/Mar/52
