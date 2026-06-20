# Compatibility & Correctness

This document explains **why `ElixirPhpEmailValidator` is a faithful, bug-for-bug
equivalent** of PHP's `filter_var($email, FILTER_VALIDATE_EMAIL)`, how that
faithfulness is continuously proven, and the precise conditions under which it
could ever drift.

It is meant to be auditable: every claim below is checkable against the vendored
files in this repo, the PHP source it cites, and the test suite.

---

## 1. The claim

For any input string `s` and any currently-supported PHP version (the live
series, auto-discovered from endoflife.date):

```
ElixirPhpEmailValidator.valid?(s)                  ==  (filter_var(s, FILTER_VALIDATE_EMAIL) !== false)
ElixirPhpEmailValidator.valid?(s, unicode: true)   ==  (filter_var(s, FILTER_VALIDATE_EMAIL, FILTER_FLAG_EMAIL_UNICODE) !== false)
```

"Bug-for-bug" is deliberate: we reproduce PHP's behaviour **including** its
deviations from RFC 5321/5322. Being "more correct" than PHP would make this
library *wrong* for its purpose.

---

## 2. The exact PHP algorithm

From `php_filter_validate_email` in
[`ext/filter/logical_filters.c`](https://github.com/php/php-src/blob/PHP-8.5/ext/filter/logical_filters.c)
(the full function is vendored at [`priv/php/logical_filters.c`](https://github.com/DanielDent/elixir_php_email_validator/blob/main/priv/php/logical_filters.c)):

```c
/* The maximum length of an e-mail address is 320 octets, per RFC 2821. */
if (Z_STRLEN_P(value) > 320) {
    RETURN_VALIDATION_FAILED
}

if (flags & FILTER_FLAG_EMAIL_UNICODE) {
    regexp = regexp0;   /* /…/iDu  — adds \pL\pN to the local part */
} else {
    regexp = regexp1;   /* /…/iD   — ASCII only */
}

/* compile `regexp`, then: */
rc = pcre2_match(re, (PCRE2_SPTR) Z_STRVAL_P(value), Z_STRLEN_P(value), 0, 0, ...);
/* rc < 0  ->  RETURN_VALIDATION_FAILED ; otherwise SUCCESS */
```

So the whole function is: **a byte-length pre-check, then a single anchored PCRE
match against the raw input bytes.** No transcoding, no normalization, no DNS.

This library mirrors it exactly (`lib/elixir_php_email_validator.ex`):

```elixir
cond do
  byte_size(email) > 320 -> false
  true -> :re.run(email, compiled(mode), [{:capture, :none}]) == :match
end
```

---

## 3. The two regexes and the flag translation

PHP stores the patterns as two C string literals. We vendor them verbatim
(C-unescaped) as the **single source of truth**:

| File | Role | Flags | SHA-256 |
| --- | --- | --- | --- |
| [`priv/php/regexp1.pattern`](https://github.com/DanielDent/elixir_php_email_validator/blob/main/priv/php/regexp1.pattern) | default / ASCII | `/iD` | `7b1547fde43f…` |
| [`priv/php/regexp0.pattern`](https://github.com/DanielDent/elixir_php_email_validator/blob/main/priv/php/regexp0.pattern) | `FILTER_FLAG_EMAIL_UNICODE` | `/iDu` | `47c6586005ac…` |

(`*.full` siblings keep the patterns exactly as they appear in PHP, with the
`/…/iD` delimiters, for reference. `MANIFEST.json` records all of this.)

`regexp0` is identical to `regexp1` **except** that the four local-part character
classes additionally contain `\pL\pN` (any Unicode letter or number) and the `u`
flag is set. **The domain sub-pattern is byte-identical between them** — which is
exactly why a Unicode local part is accepted under the flag (`日本語@example.com`)
but a Unicode domain never is (`test@日本語.com` is rejected even with the flag).

The only transformation this library applies is translating PHP's inline regex
flags into Erlang `:re` compile options — a single, audited mapping that the
library applies at compile time and that **raises** on any flag we have not
vetted (so a future PHP change can't silently slip through):

| PHP / PCRE flag | Meaning | `:re` option |
| --- | --- | --- |
| `i` | caseless | `:caseless` |
| `D` | `PCRE2_DOLLAR_ENDONLY` — `$` never matches before a trailing `\n` | `:dollar_endonly` |
| `u` | `PCRE2_UTF` + `PCRE2_UCP` | `:unicode` **and** `:ucp` |

Therefore:

- `regexp1` → `:re.compile(pattern, [:caseless, :dollar_endonly])`
- `regexp0` → `:re.compile(pattern, [:caseless, :dollar_endonly, :unicode, :ucp])`

---

## 4. Byte semantics (this is subtle and matters)

PHP runs `pcre2_match` over the **raw bytes** of the PHP string.

- **Default path (`regexp1`).** PHP compiles without `u`, so PCRE2 runs in 8-bit
  byte mode. We mirror this by matching the raw binary with **no `:unicode`
  option** — `:re` then also operates byte-wise. Any byte ≥ `0x80` simply can't
  match the ASCII-only character classes, so it's rejected, identically.
- **Unicode path (`regexp0`).** PHP compiles with `u` (UTF-8 + UCP). We match the
  UTF-8 binary with `[:unicode, :ucp]`. If the input is **not valid UTF-8**, PHP's
  `pcre2_match` returns a UTF-8 error (`rc < 0` → `false`); Erlang's `:re.run`
  instead raises `badarg`. We catch that and return `false`, making the two
  byte-identical. (Verified: malformed UTF-8 like `<<0xC3, 0x28>>` is rejected in
  both engines.)

`{:capture, :none}` is used because, like PHP, we only care whether the anchored
pattern matched — not what it captured.

---

## 5. The length story: 320 vs 254

There are two length limits and they disagree — both are reproduced:

- **The documented one (320 bytes).** A literal `byte_size(email) > 320 -> false`
  pre-check, matching PHP's C gate. It is a **byte** count, not a character count,
  which is why it can reject a *short* Unicode string (e.g. 64 multi-byte letters
  = 130 characters but 322 bytes).
- **The effective one (254 characters).** The regex's first lookahead,
  `(?!(?:…){255,})`, counts essentially the whole string and rejects anything with
  255+ "atoms". For any structurally valid ASCII address the regex therefore caps
  length at **254** — the 320 byte-gate only ever fires for pathological/multi-byte
  input ≥ 321 bytes.

Both behaviours fall out automatically: the 254 cap from the vendored regex, the
320 gate from the explicit pre-check. The test corpus pins the 254/255 boundary
and a 322-byte / 130-char Unicode case that is rejected *solely* by the byte gate.

---

## 6. Engine equivalence and drift risks

The faithfulness rests on one fact: **PHP's PCRE2 and Erlang/OTP's `:re` are the
same regex engine family**, so the same pattern + equivalent options ⇒ the same
matches. This has been confirmed empirically (PHP 8.5.5 vs OTP 28, 0 disagreements
over the 136-case catalog **and** thousands of fuzzed inputs).

The honest caveats — and how the test suite neutralizes each:

| Risk | Why it exists | Mitigation in this repo |
| --- | --- | --- |
| **PCRE version skew** | PHP and OTP each bundle their own PCRE2 (PHP can even use a distro `--with-external-pcre`). | The differential CI job runs against **every currently-supported PHP series** (auto-discovered from endoflife.date); any engine-level difference surfaces as a golden mismatch. |
| **Unicode table drift** (`\pL\pN`) | The unicode path's letter/number classification depends on each engine's Unicode version. Only affects `unicode: true`. **This is the #1 long-term divergence vector.** | The corpus includes a spread of Unicode letters/numbers (CJK, Greek, Arabic-Indic, Roman numerals, fullwidth, math alphanumerics) and symbols/marks; the fuzzer emits multi-byte UTF-8. The OTP matrix in CI flags any OTP whose tables differ. |
| **Pre-PCRE2 OTP** | OTP ≤ 27 backs `:re` with PCRE1 (older Unicode). The ASCII path is unaffected; the unicode path *may* differ for edge codepoints. | **OTP 28+ recommended.** CI runs OTP 26/27/28 so the floor is empirically known, not guessed. |
| **Backtrack / recursion limits** | PHP (`pcre.backtrack_limit`) and `:re` have independent step limits. In practice this surfaces as **CPU cost, not a different verdict**: a crafted sub-320-byte input backtracks far longer under `:re` (~200 ms) than under PHP, but both still reject it. | Confirmed a non-divergence over ~196k differential inputs. The cost is bounded per call (the engine's step limit aborts the match) but a pathological input can pin a scheduler thread — see the module's *Performance and untrusted input* note. The 320-byte gate bounds input *length*, not per-call CPU. |
| **Upstream regex change** | PHP could edit the pattern in a future release. | `mix php.drift` + the weekly drift CI job fail loudly the moment the upstream regex differs from the vendored copy. |

---

## 7. How correctness is proven (and kept proven)

Four mechanisms, each guarding a different failure mode:

1. **Golden regression (`mix test`).** Verdicts captured from real PHP
   (`test/fixtures/golden/php-*.tsv`, generated by `mix php.golden`) are committed
   and asserted against. Runs with no PHP installed. Guards against *the library*
   regressing.
2. **Live differential + fuzz (`mix test --include php`).** Re-derives verdicts
   from the local `php` and diffs thousands of structured + random byte strings.
   Guards against gaps the static corpus doesn't cover, and against *your* PHP/OTP
   combination differing.
3. **PHP version matrix (CI).** The live suite runs against every
   currently-supported PHP series (auto-discovered from endoflife.date). Guards
   against per-version differences.
4. **Drift detector (`mix php.drift`, weekly CI).** Compares the vendored regex
   against live php-src for every supported branch. Guards against *PHP* changing
   under us.

The inputs flow `corpus.exs` + `corpus_catalog.b64` → (base64) → `php` →
`golden/*.tsv` → asserted in Elixir. Base64 framing lets the corpus carry any
bytes (NUL, newlines, invalid UTF-8) safely.

---

## 8. Cross-version stability evidence

The two regex literals and the `> 320` guard are **byte-for-byte identical across
PHP 8.1, 8.2, 8.3, 8.4, 8.5 and `master`**, and across every release tag in that
range — verified by SHA-256 over the extracted patterns from 11+ git refs. The
last change to either literal was in **2015** (the unicode flag); `regexp1` last
changed in **2011**. No change is staged in `master`. Full evidence, including
the per-ref checksum table and the relevant commits, is in
[`docs/research/01-version-matrix.md`](https://github.com/DanielDent/elixir_php_email_validator/blob/main/docs/research/01-version-matrix.md) and
[`docs/research/02-history-provenance.md`](https://github.com/DanielDent/elixir_php_email_validator/blob/main/docs/research/02-history-provenance.md).

Consequence: pinning to the PHP-8.5 regex is simultaneously correct for the whole
8.x line (and, for the default/ASCII path, all the way back to PHP 5.3.10).

---

## 9. Reproduce the audit from scratch

```bash
# 1. Re-vendor the regex straight from php-src and diff against what's committed:
mix php.extract PHP-8.5
git diff priv/php          # should be empty

# 2. Confirm the vendored bytes match every supported upstream branch:
mix php.drift PHP-8.1 PHP-8.2 PHP-8.3 PHP-8.4 PHP-8.5 master

# 3. Regenerate the golden from your own PHP and run the whole suite:
mix php.test

# 4. Inspect provenance the library reports about itself:
iex -S mix
iex> ElixirPhpEmailValidator.source_info()
```

Each step is independent of the others, so agreement between them is strong
evidence the chain (php-src → vendored regex → compiled `:re` → verdicts) is
intact.

---

## 10. References

- PHP source: <https://github.com/php/php-src/blob/PHP-8.5/ext/filter/logical_filters.c>
- PHP manual: <https://www.php.net/manual/en/filter.filters.validate.php>
- Erlang `:re` / PCRE2 in OTP 28: <https://www.erlang.org/blog/highlights-otp-28/>
- Full research dossier: [`docs/research/00-DOSSIER.md`](https://github.com/DanielDent/elixir_php_email_validator/blob/main/docs/research/00-DOSSIER.md)
