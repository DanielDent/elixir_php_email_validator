# ElixirPhpEmailValidator

A **bug-for-bug compatible** Elixir port of PHP's
`filter_var($email, FILTER_VALIDATE_EMAIL)`.

It answers one question — "would PHP accept this string as an email address?" —
and returns the **exact same** `true`/`false` verdict PHP does, quirks and all.

```elixir
ElixirPhpEmailValidator.valid?("a@b.c")            #=> true
ElixirPhpEmailValidator.valid?("a@b")              #=> false   # PHP rejects: no TLD
ElixirPhpEmailValidator.valid?("user@1.2.3.4")     #=> false   # PHP rejects bare IPs
ElixirPhpEmailValidator.valid?("user@[1.2.3.4]")   #=> true    # …but accepts bracketed ones
ElixirPhpEmailValidator.valid?(~s("a b"@c.de))     #=> false   # bare space illegal even quoted
ElixirPhpEmailValidator.valid?("日本語@example.com")              #=> false
ElixirPhpEmailValidator.valid?("日本語@example.com", unicode: true) #=> true
```

> **This is not an RFC validator, and not a "good" email validator.** It is a
> faithful mirror of a specific, widely-deployed C function. If your goal is to
> match what a PHP backend (or anything else built on `filter_var`) accepts —
> e.g. for migrating a system, sharing validation rules across a polyglot stack,
> or reproducing a bug — this gives you byte-identical behaviour. If you just
> want "a reasonable email check", a normal regex or `EctoCommons.EmailValidator`
> is probably what you want instead.

[![Hex.pm](https://img.shields.io/hexpm/v/elixir_php_email_validator.svg)](https://hex.pm/packages/elixir_php_email_validator)
[![Hex Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/elixir_php_email_validator)
[![CI](https://github.com/DanielDent/elixir_php_email_validator/actions/workflows/ci.yml/badge.svg)](https://github.com/DanielDent/elixir_php_email_validator/actions/workflows/ci.yml)
[![Drift detector](https://github.com/DanielDent/elixir_php_email_validator/actions/workflows/drift.yml/badge.svg)](https://github.com/DanielDent/elixir_php_email_validator/actions/workflows/drift.yml)

## Installation

```elixir
def deps do
  [{:elixir_php_email_validator, "~> 1.0"}]
end
```

Zero runtime dependencies. Requires Elixir ~> 1.15. **OTP 28+ is recommended**
for guaranteed Unicode-mode (`FILTER_FLAG_EMAIL_UNICODE`) parity — OTP 28 is the
first release whose `:re` is backed by PCRE2, the same engine family PHP uses.
The default (ASCII) mode is engine-independent. CI validates the OTP matrix.

## API

```elixir
# boolean
ElixirPhpEmailValidator.valid?(email)                 # default flags
ElixirPhpEmailValidator.valid?(email, unicode: true)  # FILTER_FLAG_EMAIL_UNICODE

# PHP-style return: {:ok, email} on success (PHP returns the string), :error on failure
ElixirPhpEmailValidator.validate(email)               #=> {:ok, "a@b.c"} | :error

# provenance of the vendored PHP regex (php-src ref, checksums, etc.)
ElixirPhpEmailValidator.source_info()
```

`:unicode` mirrors PHP's `FILTER_FLAG_EMAIL_UNICODE`: it permits Unicode letters
and numbers in the **local part** only; the domain always stays ASCII.

## The quirks (the whole point)

PHP's validator has well-known surprises. This library reproduces every one:

| Input | `valid?` | Why |
| --- | --- | --- |
| `a@b.c` | `true` | a single-character TLD is fine |
| `a@b` | `false` | the domain needs a dot / a TLD label |
| `user@localhost` | `false` | single-label domains are rejected |
| `user@1.2.3.4` | `false` | a **bare** IP is not a valid domain |
| `user@[1.2.3.4]` | `true` | …but a **bracketed** IP literal is |
| `a@[IPv6:::1]` | `true` | bracketed IPv6 literals too |
| `"a b"@c.de` | `false` | a bare space is illegal **even inside quotes** |
| `much."more\ unusual"@x.com` | `true` | …but a backslash-escaped space is legal |
| `"a@b"@c.de` | `true` | `@` is fine inside a quoted local part |
| `a@b.123` | `false` | an all-numeric TLD is rejected |
| `a@b--c.com` | `true` | consecutive hyphens in a label are allowed |
| `a@b.com.` | `false` | a trailing dot is rejected |
| `USER@EXAMPLE.COM` | `true` | matching is case-insensitive |
| `"a\x07b"@x.com` | `true` | some control bytes (`0x01–0x08`, `0x0B`, `0x0C`) are legal in quotes… |
| `"a\tb"@x.com` | `false` | …but TAB (`0x09`), LF, CR are not |
| `a@b.c\n` | `false` | a trailing newline is rejected (the `D` flag) |
| 255-byte address | `false` | the regex caps total length at **254**, not 320 (see below) |
| `😀@x.com` | `false` (even `unicode: true`) | an emoji is a *symbol*, not a letter/number |

A full, categorized catalog of 136 ground-truthed cases lives in
[`docs/research/04-quirks-catalog.md`](https://github.com/DanielDent/elixir_php_email_validator/blob/main/docs/research/04-quirks-catalog.md), and
every one of them is an executed test case.

## How it works (and why it is faithful)

PHP implements `FILTER_VALIDATE_EMAIL` in C, in
[`ext/filter/logical_filters.c → php_filter_validate_email`](https://github.com/php/php-src/blob/PHP-8.5/ext/filter/logical_filters.c).
The algorithm is small:

1. **Reject** any input longer than **320 bytes**.
2. **Match** against one anchored PCRE regex with the inline flags `i` (caseless)
   and `D` (dollar-end-only). There are two regexes: an ASCII one by default, and
   a Unicode-aware one (adding `\pL\pN` to the local part, plus the `u` flag) used
   only with `FILTER_FLAG_EMAIL_UNICODE`.

This library **vendors PHP's exact regex strings, byte-for-byte** (see
[`priv/php/`](https://github.com/DanielDent/elixir_php_email_validator/tree/main/priv/php) and the checksums in
[`priv/php/MANIFEST.json`](https://github.com/DanielDent/elixir_php_email_validator/blob/main/priv/php/MANIFEST.json)) and performs only a
mechanical flag translation:

| PHP inline flag | Erlang `:re` option |
| --- | --- |
| `i` | `:caseless` |
| `D` (PCRE_DOLLAR_ENDONLY) | `:dollar_endonly` |
| `u` (PCRE_UTF8 + UCP) | `:unicode`, `:ucp` |

Both PHP (PCRE2) and Erlang's `:re` are PCRE-family engines, so the same pattern
yields the same matches. The library matches the **raw bytes** of the input
(exactly as PHP's `pcre2_match` does), enforces the 320-byte gate in Elixir, and
treats invalid-UTF-8 input on the unicode path as a non-match (which is what PHP
does when PCRE reports a UTF-8 error).

There is no hand-written validation logic to get subtly wrong: **the regex *is*
PHP's regex.** See [`COMPATIBILITY.md`](COMPATIBILITY.md) for the full argument.

## Performance & untrusted input

Validation is a single anchored PCRE match — instant for real addresses. But the
vendored pattern (PHP's own) can be driven into heavy backtracking by a
*deliberately crafted* input, even a short one: a worst-case string costs ~200 ms
of CPU inside the non-yielding `:re` NIF before the engine aborts the match. The
**verdict stays correct** (it's rejected, exactly as PHP rejects it) — the cost is
pure CPU, and the 320-byte limit caps input *length*, not per-call CPU.

So if you validate **untrusted** input at high volume, run validation off your
request-serving schedulers (e.g. a supervised `Task`) and/or rate-limit upstream.
The library deliberately does **not** cap PCRE's steps itself: a cap tight enough
to matter would also reject some legitimate addresses PHP accepts — breaking the
parity that is the whole point. See the module docs for detail.

## Verify it yourself

Correctness here is *demonstrated*, not asserted. Three layers of tests:

```bash
mix test                  # golden regression — no PHP needed
mix test --include php    # + live parity & differential fuzz vs your local php
mix php.test              # regenerate the golden from your php, then run everything
```

- **`mix test`** asserts the library reproduces, for ~165 corpus inputs, the
  verdicts recorded from real PHP in `test/fixtures/golden/php-*.tsv`. This runs
  anywhere, even with no PHP installed — the golden files are PHP's frozen
  testimony.
- **`mix test --include php`** additionally re-derives the verdicts from your
  installed `php` and runs a **differential fuzzer** (thousands of structured +
  random byte strings diffed against `filter_var`), catching any disagreement a
  hand-written corpus would miss.
- **CI** ([`.github/workflows/ci.yml`](https://github.com/DanielDent/elixir_php_email_validator/blob/main/.github/workflows/ci.yml)) runs the
  live suite against **every currently-supported PHP version** (auto-discovered
  from endoflife.date, so new releases are tested and EOL ones drop off), proving
  parity per version. It also runs weekly and watches the newest stable Elixir
  (a canary) and the newest stable OTP (a differential-vs-PHP watch job), so
  drift from a new PHP, Elixir, or OTP release surfaces on its own.

## How you'll know if PHP changes

```bash
mix php.drift             # fetch php-src for 8.1–8.5, re-extract the regex, diff vs vendored
```

This is the early-warning system. It re-fetches `logical_filters.c` from php-src
for each supported release, re-extracts the two regexes, and fails if they differ
from the vendored copy. A scheduled CI job
([`.github/workflows/drift.yml`](https://github.com/DanielDent/elixir_php_email_validator/blob/main/.github/workflows/drift.yml)) runs it weekly, so
if PHP ever edits the validator you find out immediately. To adopt an upstream
change: `mix php.extract <ref>` re-vendors the regex, then `mix php.test` confirms
(or surfaces) any behavioural difference.

## Which PHP does this match?

The validator's regex and the 320-byte check are **byte-identical across PHP 8.1,
8.2, 8.3, 8.4, 8.5 and `master`** (and unchanged upstream since 2011/2015). So a
single vendored copy is correct for the entire currently-supported PHP range
simultaneously. The provenance and per-version checksum evidence are in
[`docs/research/01-version-matrix.md`](https://github.com/DanielDent/elixir_php_email_validator/blob/main/docs/research/01-version-matrix.md).

## Documentation & research

- [`COMPATIBILITY.md`](COMPATIBILITY.md) — the correctness argument in full.
- [`docs/research/`](https://github.com/DanielDent/elixir_php_email_validator/tree/main/docs/research) — the underlying research dossier: PHP source
  analysis, cross-version proof, the Elixir-ecosystem survey (why nothing else is
  equivalent), the 136-case quirks catalog, and the PCRE/packaging notes.

## Verifying the published package (build provenance)

Each release is published by the automated pipeline with a **Sigstore-signed
[build-provenance attestation](https://docs.github.com/actions/security-for-github-actions/using-artifact-attestations/using-artifact-attestations-to-establish-provenance-for-builds)**
binding the tarball to the exact repository, commit, and workflow run that built
it. To check a release yourself (needs the [`gh` CLI](https://cli.github.com/)):

```bash
# fetch the exact published tarball from Hex, then verify GitHub's attestation for those bytes
mix hex.package fetch elixir_php_email_validator VERSION --output epev.tar
gh attestation verify epev.tar \
  --repo DanielDent/elixir_php_email_validator \
  --signer-workflow DanielDent/elixir_php_email_validator/.github/workflows/_release-build.yml
```

A passing check proves the tarball Hex served you was produced by this repo's
release workflow at a specific commit — not substituted or tampered with. The
Hex build is deterministic, so the attested bytes and the bytes Hex serves match.

**Scope (the honest version).** The attestation covers the artifact this repo
built; **Hex.pm does not yet store or surface provenance itself** (it's on the
[EEF "Hex Build Provenance" roadmap](https://security.erlef.org/aegis/roadmap/hex-build-provenance.html)),
so `mix deps.get` does **not** check it automatically — verification is a
deliberate, out-of-band step. It is [SLSA](https://slsa.dev) Build **L3** — the
build and the signing run in an isolated reusable workflow, so the build steps
can't reach the signing identity. Attestations exist only for releases published
after this step was added to the pipeline.

## Contributing & releases

This project releases itself: commits to `main` using
[Conventional Commits](https://www.conventionalcommits.org/) drive automatic
version bumps, changelog updates, tags, and publishing to Hex via GitHub Actions
(no credential is ever exposed). See [`RELEASING.md`](https://github.com/DanielDent/elixir_php_email_validator/blob/main/RELEASING.md) for the
pipeline and the one-time setup. The vendored regex is kept honest by a weekly
drift detector against php-src.

## License & attribution

Copyright © 2026 [Daniel Dent](https://danieldent.com). The Elixir code, tests,
tooling, and docs are MIT-licensed (see [`LICENSE`](LICENSE)). The vendored regex derives from Michael
Rushton's validator and is redistributed from PHP; its copyright notice is
preserved in [`NOTICE`](NOTICE), as its terms require.
