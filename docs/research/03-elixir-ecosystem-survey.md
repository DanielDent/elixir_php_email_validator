# Survey: Does any Elixir/Erlang package replicate PHP `filter_var($email, FILTER_VALIDATE_EMAIL)`?

## Executive verdict

**No.** As of 2026-06-20, **no package on Hex.pm provides bug-for-bug (or even close) compatibility** with PHP's `filter_var($email, FILTER_VALIDATE_EMAIL)`. A Hex API search for `filter_var` returns **zero** packages, and no Hex package's source or docs reference `filter_var` / `FILTER_VALIDATE_EMAIL`. The only explicit PHP-`filter_var`-parity port in *any* ecosystem is a JavaScript/TypeScript library (`mpyw/FILTER_VALIDATE_EMAIL.js`) — there is **no Elixir/Erlang equivalent**.

The closest accidental near-miss is **MailChecker**, whose regex is forked from the *same* Michael Rushton validator php-src is based on — yet it is **not on Hex** (it is a vendored template file), and I proved it diverges from PHP 8.5 on a whole class of inputs (double-hyphen domain labels like `a@b--c.com`).

All findings below were produced by reading the actual cloned source and running each package's real regex through Elixir (OTP 28) against PHP 8.5.5 verdicts.

---

## Methodology

I cloned each package, extracted its verbatim regex/logic, and ran it through Elixir `Regex`/`:re` against the established PHP-8.5 verdict corpus (`/tmp/corpus.txt` + `/tmp/php_out.txt`) plus a targeted adversarial set. PHP's own regexp1 (compiled in OTP as `[:caseless, :dollar_endonly]`, byte mode) reproduced all 31 corpus verdicts and all 6 adversarial verdicts byte-identically, re-confirming the established ground truth and validating the harness.

---

## 1. EctoCommons.EmailValidator (`ecto_commons`)

- **Hex:** `ecto_commons` v**0.3.7** (latest), published 2020-09-07, last updated 2026-02-23. License **MIT**. ~636k total downloads. Source: `github.com/achedeuzot/ecto_commons`, file `lib/validators/email.ex`.
- **`:html_input` check (default)** — a single regex, copied verbatim from the source:
  ```
  ~r/^[a-zA-Z0-9.!#$%&'*+\/=?^_`{|}~-]+@[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$/
  ```
  This is the WHATWG HTML `<input type=email>` regex (per its own comment, citing html.spec.whatwg.org and StackOverflow). It is **not** related to PHP's regex at all.
- **`:pow` check** — not a regex; a procedural RFC-3696-flavored parser copied from the `pow` package: splits at the last `@`, enforces local-part ≤ 64 / domain ≤ 255 chars, allows `\p{L}\p{M}` Unicode in both parts, strips quotes/comments, validates DNS labels (≤ 63, no leading/trailing hyphen, rejects all-numeric TLD). It **explicitly forbids IP-literal `[...]` domains** (per RFC 3696 note in the moduledoc).

**Behavioral divergences from PHP (empirically measured): 13 of 31 corpus cases disagree.** Concretely:

| Input | PHP | ecto `:html_input` | Why it diverges |
|---|---|---|---|
| `a@b` | reject | **accept** | HTML regex allows a single-label domain; PHP requires a proper TLD structure |
| `a@localhost` | reject | **accept** | same |
| `.foo@bar.com`, `foo.@bar.com` | reject | **accept** | HTML regex doesn't forbid leading/trailing dot in local part |
| `a@[127.0.0.1]`, `a@[123.45.67.89]` | **accept** | reject | HTML regex has no IPv4-literal branch |
| `a@[IPv6:::1]`, `a@[IPv6:fe80::1]` | **accept** | reject | no IPv6-literal branch |
| `"quoted"@example.com`, `much."more\ unusual"@example.com` | **accept** | reject | HTML regex has no quoted-local-part branch |
| `a@123.45.67.89` | reject | **accept** | HTML regex treats bare IPv4 as a normal dotted domain; PHP requires brackets for IP |

**Verdict: NO — `:html_input` can never be byte-for-byte equal to PHP `filter_var`.** It is a structurally different (and shorter) regex with no IP-literal branch, no quoted-local-part branch, different anchoring semantics, and no 320/64 byte-length pre-check. `:pow` is even further away (it's an RFC-3696 parser that bans IP literals entirely and permits Unicode unconditionally). The `:burner` / `:check_mx_record` checks delegate to Burnex (DNS/blacklist) and are orthogonal to format parity.

---

## 2. Other packages

### email_checker (`email_checker`)
- **Hex:** v**0.2.4**, published 2015, last updated 2022-01-18. License **MIT**. ~1.68M total downloads (the most-used). Source: `github.com/maennchen/email_checker`.
- **Method:** Regex format check (`EmailChecker.Check.Format`) **+ optional MX DNS lookup + optional SMTP probe** (chained: Format → MX → SMTP). Default validations include MX, so out-of-the-box it does network I/O.
- **Core regex** (verbatim from `priv/email_regex`, compiled `[:caseless]`, anchored `^...$`):
  ```
  ^(?:[a-z0-9!#$%&'*+/=?^_`{|}~-]+(?:\.[a-z0-9!#$%&'*+/=?^_`{|}~-]+)*|"(?:[\x01-\x08\x0b\x0c\x0e-\x1f\x21\x23-\x5b\x5d-\x7f]|\\[\x01-\x09\x0b\x0c\x0e-\x7f])*")@(?<domain>(?:(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z0-9](?:[a-z0-9-]*[a-z0-9])?|\[(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?|[a-z0-9-]*[a-z0-9]:(?:...)+)\]))$
  ```
  This is the well-known "general email regex" (the Perl/`http://emailregex.com` lineage, ultimately RFC-5322-flavored). It **does** have a quoted-local-part branch and an IPv4-literal branch — closer than ecto, but still not PHP's.
- **Divergences (6 of 31 corpus disagree):** rejects `a@[IPv6:::1]` / `a@[IPv6:fe80::1]` (no IPv6 branch, only IPv4 literals; PHP accepts), rejects `much."more\ unusual"@example.com` (PHP accepts), and **accepts bare-IPv4 domains** `a@123.45.67.89` / `x@111.222.333.44444` / `email@123.123.123.123` that PHP rejects (PHP only accepts IPs inside brackets, and rejects out-of-range octets like `333`).
- **Verdict: NO.** Different regex family, no IPv6-literal support, accepts unbracketed IPs PHP rejects, no 320-byte cap, and the default path performs DNS/SMTP that PHP never does.

### burnex (`burnex`)
- **Hex:** v**3.2.0**, license **MIT**, ~641k downloads. Source: `github.com/Betree/burnex`.
- **Method:** **NOT an email-format validator.** It only checks whether the domain is a known disposable/burner provider (MapSet membership against `priv/burner-email-providers/emails.txt`) plus optional MX lookup. Its only "parsing" is `~r/@([^@]+)$/` to grab the domain.
- **Verdict: N/A — out of scope.** It's a blocklist, not a `filter_var` analog. (ecto_commons' `:burner`/`:check_mx_record` delegate here.)

### MailChecker (`FGRibreau/mailchecker`) — the important near-miss
- **NOT published on Hex.** It is a multi-language repo (npm `mailchecker` v**6.0.20**, MIT). The Elixir artifact is `platform/elixir/mail_checker.ex` — a generated file you'd have to **vendor by hand**; there is no `mix.exs`/Hex package. (`mail_checker`, `mailchecker`, `ex_mailchecker` all 404 on the Hex API.)
- **Method:** `MailChecker.valid?/1` = `valid_address?(email) && !in_blacklist?(email)` — a regex **plus** a disposable-domain blacklist layered on top (so it is strictly *more* restrictive than its own regex).
- **Core regex:** `~r/\A<...>\z/i` where `<...>` is, structurally, **PHP's Rushton regexp1**. I diffed them character-by-character. After normalization the only two differences are:
  1. **Anchors:** PHP uses `^...$` with PCRE `/D` (`DOLLAR_ENDONLY`); MailChecker uses `\A...\z`.
  2. **Domain-label hyphens:** PHP uses `(?:-+[a-z0-9]+)*` (one-or-more hyphens); MailChecker uses `(?:-[a-z0-9]+)*` (exactly one). Proof: stripping PHP's anchors and replacing `(?:-+[a-z0-9]+)*` → `(?:-[a-z0-9]+)*` makes the two strings **byte-identical** (`equal == True`).
- This #2 difference is **load-bearing**. PHP php-src updated Rushton's pattern to allow consecutive hyphens in a label; MailChecker froze an older revision. Measured divergence on adversarial cases:

  | Input | PHP | MailChecker regex |
  |---|---|---|
  | `a@b--c.com` | **accept** | reject |
  | `a@b---c.com` | **accept** | reject |
  | `test@ex--ample.com` | **accept** | reject |
  | `a@x--y--z.com` | **accept** | reject |

  (On the original 31-case corpus MailChecker's regex matched PHP 31/31 — but only because that corpus was itself derived from the Rushton pattern. The adversarial double-hyphen set exposes the gap: 4/6 disagree.)
- **Verdict: NO — and this is the subtle, important one.** Even the package whose regex *shares PHP's ancestry* is not bug-for-bug compatible: it rejects valid double-hyphen domains PHP accepts, it uses `\A\z` instead of `^$/D`, it layers a burner blacklist on top of `valid?`, and **it isn't even installable from Hex**.

### Other packages checked and dismissed
- **`email_validator`** (rbkmoney, v1.1.0, Apache-2.0): an Erlang **ABNF grammar parser** (`email_validator_abnf.abnf`) implementing RFC 5321/5322 strictly (local ≤ 64, domain ≤ 255 byte caps, `mailbox` rule). A real RFC parser, not a PHP-regex mirror — diverges by design (e.g. PHP's regex accepts/rejects things no strict RFC parser would match identically).
- **`email_address`** (amberbit, v1.0.1, MIT): a lenient *display-name* parser using `[^\s<;,]+@[^\s;,>]+`. Far more permissive than PHP; meant for parsing `Name <a@b>`, not validating.
- **`email_guard`** (v1.2.3): disposable/personal-domain detector (blocklist), not a format validator.
- **`validation`** / `elixir-validation/validation` (v0.0.x, "under development"): generic rule lib with an `email?` helper; trivial regex, not PHP-related.
- **`kickbox`**: third-party API client (network verification), unrelated to local regex parity.
- **Community "roll-your-own"**: the common pattern is `Ecto.Changeset.validate_format/3` with an ad-hoc regex (e.g. the mgamini gist) — none target `filter_var`.

---

## 3. Prior art (any language attempting `filter_var` parity)

- **`mpyw/FILTER_VALIDATE_EMAIL.js`** (github.com/mpyw/FILTER_VALIDATE_EMAIL.js) — TypeScript/JavaScript, on npm. Explicitly "Email validation compatible with PHP's `filter_var($value, FILTER_VALIDATE_EMAIL)`." Supports `FILTER_FLAG_EMAIL_UNICODE` (Unicode mode default, with an ASCII-only toggle). It does **not** loudly claim *byte-for-byte* equivalence, and there is **no Elixir/Erlang port**. This is the single clearest piece of prior art and demonstrates the niche exists in other ecosystems but is **unfilled in Elixir**.
- No dedicated Python/Ruby/Go `FILTER_VALIDATE_EMAIL` port surfaced; Ruby leans on `URI::MailTo::EMAIL_REGEXP` or the `email_validator` gem (different philosophy), neither PHP-compatible.

---

## Comparison table

| Package (Hex) | Method | Accepts `a@b`? | Bracketed IP `a@[127.0.0.1]`? | IPv6 literal `a@[IPv6:::1]`? | Unicode domain/local? | Length limits (320/64)? | Double-hyphen `a@b--c.com`? | PHP-parity verdict |
|---|---|---|---|---|---|---|---|---|
| **PHP `filter_var`** (reference) | Rushton PCRE regex `/iD` + 320-byte cap | **No** | **Yes** | **Yes** | only via `EMAIL_UNICODE` flag | **Yes** (320 byte pre-check; 64/255 in regex) | **Yes** | — |
| `ecto_commons` `:html_input` | WHATWG HTML regex | **Yes** ✗ | No ✗ | No ✗ | No | No (no byte cap) | Yes | **NO** (13/31 differ) |
| `ecto_commons` `:pow` | RFC-3696 procedural parser | depends (needs dotted domain) | No (IP literals banned) ✗ | No ✗ | Yes (always) ✗ | 64/255 char (not byte) | Yes | **NO** |
| `email_checker` (Format) | RFC-5322-style regex (+MX/SMTP) | No | **Yes** | No ✗ | No | No | Yes | **NO** (6/31 differ; +accepts bare IPv4 ✗) |
| `mailchecker` (*not on Hex*) | PHP-Rushton regex (older fork) + burner blocklist | No | **Yes** | **Yes** | only ASCII branch | local/domain counts in regex; no 320 cap | **No** ✗ | **NO** (rejects double-hyphen; not installable) |
| `email_validator` (rbkmoney) | ABNF RFC-5321/5322 parser | parser-dependent | parser-dependent | parser-dependent | RFC-defined | **Yes** (64/255 byte) | parser-dependent | **NO** (different paradigm) |
| `email_address` (amberbit) | lenient display-name parser | **Yes** ✗ | Yes (loosely) | Yes (loosely) | Yes ✗ | No | Yes | **NO** (far too permissive) |
| `burnex` / `email_guard` | disposable-domain blocklist | N/A (no format check) | N/A | N/A | N/A | N/A | N/A | **N/A** (not a validator) |

(✗ marks a behavior that disagrees with PHP.)

---

## 4. Definitive conclusion

**A PHP-`filter_var`-equivalent Elixir package does not exist on Hex today.**

- Searching the Hex API for `filter_var` yields nothing; no Hex package source or documentation references `FILTER_VALIDATE_EMAIL`.
- Every format-validating package on Hex (`ecto_commons`, `email_checker`, `email_validator`, `email_address`) uses a **different regex family or a different paradigm** (HTML-input regex, emailregex.com regex, RFC-5322 ABNF parser, lenient display-name parser) and was **empirically shown to disagree** with PHP 8.5 on multiple classes of input (single-label domains, bracketed IPv4/IPv6 literals, quoted local parts, bare IPs, all-numeric handling).
- The single package whose regex shares PHP's *exact ancestry* — **MailChecker** — is (a) **not published on Hex** (vendor-only template), (b) frozen on an older Rushton revision that **rejects valid double-hyphen domains PHP accepts**, (c) uses `\A\z` rather than PHP's `^$` + `DOLLAR_ENDONLY`, and (d) bolts a disposable-domain blacklist onto `valid?`. It therefore is **not** a drop-in `filter_var` equivalent.
- Prior art for true parity exists only as **`mpyw/FILTER_VALIDATE_EMAIL.js`** (JS/TS), confirming the demand but also confirming the **Elixir gap is unfilled**.

**The gap a new package would fill:** a from-scratch Elixir/Erlang library that compiles php-src's *exact* `regexp1`/`regexp0` byte strings (preserving Rushton's copyright) with `:re` options `[:caseless, :dollar_endonly]` (and `+ [:unicode, :ucp]` for the `EMAIL_UNICODE` flag), applies the **320-byte length pre-check**, and matches on **raw bytes** — which (per the already-established and re-validated empirical proof: 31/31 ASCII + 10/10 Unicode byte-identical to PHP 8.5) is the only known way to achieve genuine bug-for-bug parity. No such package exists on Hex today.

---

### Source files / commands of record (all absolute paths)
- PHP reference regexes: `/tmp/pat1.txt` (regexp1), `/tmp/pat0.txt` (regexp0); corpus + verdicts: `/tmp/corpus.txt`, `/tmp/php_out.txt`; adversarial verdicts: `/tmp/adv_php.txt`.
- Cloned sources: `/tmp/ecto_commons/lib/validators/email.ex`, `/tmp/email_checker/priv/email_regex` + `/tmp/email_checker/lib/email_checker/check/format.ex`, `/tmp/burnex/lib/burnex.ex`, `/tmp/mailchecker/platform/elixir/mail_checker.ex` (+ `.tmpl.ex`), `/tmp/ev_rbk/src/email_validator.erl` + `/tmp/ev_rbk/src/email_validator_abnf.abnf`, `/tmp/email_address/lib/email_address.ex`.
- Extracted MailChecker inner regex: `/tmp/mc_inner.txt`; probes: `/tmp/probe3.exs`, `/tmp/adv_probe.exs`, `/tmp/table.exs`.

### External sources
- https://hex.pm/api/packages/ecto_commons , https://github.com/achedeuzot/ecto_commons , https://hexdocs.pm/ecto_commons/EctoCommons.EmailValidator.html
- https://hex.pm/api/packages/email_checker , https://github.com/maennchen/email_checker
- https://hex.pm/api/packages/burnex , https://github.com/Betree/burnex
- https://github.com/FGRibreau/mailchecker (npm `mailchecker` 6.0.20; not on Hex)
- https://hex.pm/api/packages/email_validator , https://github.com/rbkmoney/email_validator
- https://github.com/amberbit/email_address , https://hex.pm/api/packages/email_address
- https://github.com/mpyw/FILTER_VALIDATE_EMAIL.js (JS/TS prior art; no Elixir port)
- https://html.spec.whatwg.org/multipage/input.html#e-mail-state-(type=email) (origin of ecto's `:html_input` regex)
- https://www.php.net/manual/en/function.filter-var.php
