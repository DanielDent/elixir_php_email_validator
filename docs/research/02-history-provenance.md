# PHP `FILTER_VALIDATE_EMAIL` Regex — Full History & Provenance

*Compiled 2026-06-20. All `php-src` claims verified against a local partial clone of `github.com/php/php-src` and raw file fetches; key empirical claims re-run locally on PHP 8.5.5 and Erlang/OTP 28.*

## TL;DR / Correction to a common premise

A widely-repeated belief is that **PHP itself** once shipped a "large recursive PCRE with subpattern references `(?1)(?2)(?3)…` and possessive quantifiers" for `FILTER_VALIDATE_EMAIL`. **That is not true of any version PHP ever shipped.** I scanned every historical revision of `ext/filter/logical_filters.c` on `master`:

```
$ # for every commit that ever touched the file:
$ git show <rev>:ext/filter/logical_filters.c | grep -E '\(\?[0-9]\)|\(\?R\)|\+\+|\*\+'
→ NO commit on master ever contained (?1)/(?2)/(?R)/possessive quantifiers in this file
```

What actually happened:
- **PHP 5.2.0 – 5.2.13 / 5.3.0 – 5.3.2** used a *flat* regex copied from **PEAR's `HTML_QuickForm/QuickForm/Rule/Email.php` (rev 1.4)** — alternation-based, no recursion, no possessive quantifiers.
- **PHP 5.2.14 / 5.3.3 (both 2010-07-21)** replaced it with a *flat* adaptation of **Michael Rushton's** validator (the regex still in use today).

The recursive `(?1)…(?8)` regex with subroutine calls is **Michael Rushton's *own* original published regex** — PHP's maintainers deliberately *flattened* it (inlined the subroutines, dropped CFWS/comment handling) before adopting it. So the "recursive regex" is part of the provenance, but it lived on `squiloople.com`, never inside `php-src`.

A second key fact, verified by byte-identical hashing: the regex string literal has been **unchanged across PHP 7.1.0, 7.4, 8.0.0, 8.4.10 and 8.5** (`grep 'const char regexp' | shasum` → `930750babe00` for all). The only post-2011 change to the *matching engine* was the PCRE1→PCRE2 backend swap in PHP 7.3.

---

## 1. Michael Rushton's original validator (squiloople.com, 2009–2010)

**What it was.** Michael Rushton (`michael@squiloople.com`) published "Email Address Validation" on his blog on **2009-12-20** (`http://squiloople.com/2009/12/20/email-address-validation/`, now 404 on the live site — confirmed `curl` returns HTTP 404). It was part of the *Squiloople Framework*, version **1.0**, an `EmailAddressValidator` PHP class that builds a single PCRE matching **RFC 5321 / RFC 5322**-compliant addresses, with toggles for quoted strings, domain literals, IDN labels, and **CFWS (comments / folding whitespace)**. The class survives in ports such as [jorgecolonconsulting/emailaddressvalidator](https://github.com/jorgecolonconsulting/emailaddressvalidator) and in Dominic Sayers' is_email comparison set ([dominicsayers.com/php/isemail/others/MichaelRushton.php](https://github.com/dominicsayers/dominicsayers.com/blob/master/php/isemail/others/MichaelRushton.php)).

**Rushton's regex used PCRE recursion.** His pattern references capturing groups as subroutines (`(?1)`…`(?8)`, plus named `(?P>fws)`, `(?P>comment)`). The single-string form (as reproduced in [PHPMailer issue #439](https://github.com/PHPMailer/PHPMailer/issues/439)) begins:

```
/^(?!(?>(?1)"?(?>\\[ -~]|[^"])+"?(?1)){255,})(?!(?>(?1)"?(?>\\[ -~]|[^"])+"?(?1)){65,}@)
((?>(?>(?>((?>(?>(?>\x0D\x0A)?[\t ]+|(?>[\t ]*\x0D\x0A)?[\t ]+)?)(\((?>(?2)(?>[\x01-\x08\x0B\x0C\x0E-'*-\[\]-\x7F]|\\[\x00-\x7F]|(?3)))*(?2)\)))+(?2))|(?2))?)
([!#-'*+\/-9=?^-~-]+|"(?>(?2)(?>[\x01-\x08\x0B\x0C\x0E-!#-\[\]-\x7F]|\\[\x00-\x7F]))*(?2)")
(?>(?1)\.(?1)(?4))*(?1)@(?!(?1)[a-z0-9-]{64,})(?1)(?>([a-z0-9](?>[a-z0-9-]*[a-z0-9])?) …
```

Here `(?1)` is the CFWS subroutine, `(?2)` the comment body, `(?3)…(?8)` the nested IPv6/IPv4 pieces. This is the genuine "recursive `(?1)(?2)(?3)`" regex — it is **Rushton's**, not PHP's. (It is also why people hit *"reference to non-existent subpattern"* PCRE errors when copy-pasting it — see PHPMailer #439.) An independent comparison, [fightingforalostcause.net/.../compare-email-regex.php](https://fightingforalostcause.net/content/misc/2006/compare-email-regex.php), scores PHP's Rushton-derived `filter_var()` regex best of the field (valid 96/134, invalid 130/132) and states verbatim: *"The expression with the best score is currently the one used by PHP's filter_var(), which is based on a regex by Michael Rushton."*

**The exact copyright text PHP preserves** (verbatim from `ext/filter/logical_filters.c`, present identically from PHP 5.2.14 through 8.5):

```
* Michael's regex carries this copyright:
*
* Copyright © Michael Rushton 2009-10
* http://squiloople.com/
* Feel free to use and redistribute this code. But please keep this copyright notice.
```

**How PHP modified it** (verbatim comment block from the source, unchanged 5.2.14 → 8.5):

```
* The regex below is based on a regex by Michael Rushton.
* However, it is not identical.  I changed it to only consider routeable
* addresses as valid.  Michael's regex considers a@b a valid address
* which conflicts with section 2.3.5 of RFC 5321 which states that:
*
*   Only resolvable, fully-qualified domain names (FQDNs) are permitted
*   when domain names are used in SMTP.  In other words, names that can
*   be resolved to MX RRs or address (i.e., A or AAAA) RRs (as discussed
*   in Section 5) are permitted, as are CNAME RRs whose targets can be
*   resolved, in turn, to MX or address RRs.  Local nicknames or
*   unqualified names MUST NOT be used.
*
* This regex does not handle comments and folding whitespace.  While
* this is technically valid in an email address, these parts aren't
* actually part of the address itself.
```

So PHP's two deliberate departures from Rushton:
1. **Routeable-only domains.** The domain branch requires at least one dot-separated label followed by a TLD-like label (`(?:…\.){1,126}…`), so a **single-label domain is rejected**. Verified locally on PHP 8.5.5: `a@b` → **fail**, `a@b.c` → **pass**. This is the `a@b`-rejection the comment describes.
2. **No CFWS / comments.** Rushton's `(?1)`/`(?2)` comment-and-folding-whitespace subroutines were dropped entirely, which is most of what made his regex recursive. PHP's version is a flat pattern.

---

## 2. The PRE-Rushton PHP implementation (PEAR HTML_QuickForm regex) and the 2010 replacement

### The actual pre-2010 regex

From **PHP 5.2.0 (2006-11-01)**, `php_filter_validate_email` carried this comment and flat regex (verbatim, PHP 5.2.0 form):

```c
/* From http://cvs.php.net/co.php/pear/HTML_QuickForm/QuickForm/Rule/Email.php?r=1.4 */
const char regexp[] = "/^((\\\"[^\\\"\\f\\n\\r\\t\\v\\b]+\\\")|([\\w\\!\\#\\$\\%\\&\\'\\*\\+\\-\\~\\/\\^\\`\\|\\{\\}]+(\\.[\\w\\!\\#\\$\\%\\&\\'\\*\\+\\-\\~\\/\\^\\`\\|\\{\\}]+)*))@((\\[(((25[0-5])|(2[0-4][0-9])|([0-1]?[0-9]?[0-9]))\\.((25[0-5])|(2[0-4][0-9])|([0-1]?[0-9]?[0-9]))\\.((25[0-5])|(2[0-4][0-9])|([0-1]?[0-9]?[0-9]))\\.((25[0-5])|(2[0-4][0-9])|([0-1]?[0-9]?[0-9])))\\])|(((25[0-5])|(2[0-4][0-9])|([0-1]?[0-9]?[0-9]))\\.((25[0-5])|(2[0-4][0-9])|([0-1]?[0-9]?[0-9]))\\.((25[0-5])|(2[0-4][0-9])|([0-1]?[0-9]?[0-9]))\\.((25[0-5])|(2[0-4][0-9])|([0-1]?[0-9]?[0-9])))|((([A-Za-z0-9\\-])+\\.)+[A-Za-z\\-]+))$/";
```

This is the exact form right before the Rushton swap (verbatim, parent of the 2010 commit):

```c
/* From http://cvs.php.net/co.php/pear/HTML_QuickForm/QuickForm/Rule/Email.php?r=1.4 */
const char regexp[] = "/^((\\\"[^\\\"\\f\\n\\r\\t\\b]+\\\")|([A-Za-z0-9_][A-Za-z0-9_\\!\\#\\$\\%\\&\\'\\*\\+\\-\\~\\/\\=\\?\\^\\`\\|\\{\\}]*(\\.[A-Za-z0-9_\\!\\#\\$\\%\\&\\'\\*\\+\\-\\~\\/\\=\\?\\^\\`\\|\\{\\}]*)*))@((\\[(((25[0-5])| … )\\])|( … )|((([A-Za-z0-9])(([A-Za-z0-9\\-])*([A-Za-z0-9]))?(\\.(?=[A-Za-z0-9\\-]))?)+[A-Za-z]+))$/D";
```

It is **flat alternation** — `(local)@((IPv4-literal)|(IPv4)|(domain))` — with **no recursion** and **no possessive quantifiers**. Between 5.2.0 and the swap it received ~8 in-place bug-fix tweaks (the `=`/`?` chars, the `v` letter, leading/trailing `-`, locale fixes, etc.) listed in the timeline below.

### When/why it was replaced

- **Bug report:** [PHP #49576 "Filter var for validating email is not validating emails correctly"](https://bugs.php.net/bug.php?id=49576), opened **2009-09-17** by `mparkin`, complaining of false positives/negatives versus the Kohana framework's validator.
- **Fix commit:** `6d77506cfdf` — *"Update the FILTER_VALIDATE_EMAIL filter to fix bug #49576"*, by **Rasmus Lerdorf**, **2010-04-02**. This single commit deleted the PEAR regex and inserted the flat Rushton-derived regex plus the copyright comment (full diff confirmed locally). Backported to the 5.2 branch as `63bc90a3047`.
- **First releases containing it** (verified via `git tag --contains`): **PHP 5.3.3** and **PHP 5.2.14**, both tagged **2010-07-21**. (So 5.2.0–5.2.13 and 5.3.0–5.3.2 had the old PEAR regex; 5.2.14 / 5.3.3 onward have Rushton's.)

### Observable behavior differences (old PEAR vs new Rushton)

| Input | PEAR (≤5.3.2) intent | Rushton (≥5.3.3) | Note |
|---|---|---|---|
| `a@b` (single-label domain) | accepted | **rejected** | Rushton+PHP require routeable FQDN |
| `user@[127.0.0.1]` (IPv4 literal) | accepted | accepted | both support IPv4 literals |
| `user@[IPv6:…]` | **not supported** | accepted | Rushton added IPv6 literal support |
| quoted local `"a b"@x.com` | partial | accepted | Rushton has full quoted-string grammar |
| length caps (local ≤64, total ≤254) | none | **enforced** | the `{255,}`/`{65,}@` lookaheads |
| IDN/`xn--` labels | crude | explicit `xn--` handling | |

---

## 3. `FILTER_FLAG_EMAIL_UNICODE` (PHP 7.1.0)

- **Introduced by commit** `8f4050709c8` — *"Support Unicode characters in the local part of an e-mail address. See RFC 6531 … Add the FILTER_FLAG_EMAIL_RFC6531 flag."*, by **Leo Feyer** (Contao), **2015-10-15**.
- The internal name in that commit was `FILTER_FLAG_EMAIL_RFC6531`; it was **renamed to `FILTER_FLAG_EMAIL_UNICODE`** before release. In PHP 7.1.0's `ext/filter/filter.c`: `REGISTER_LONG_CONSTANT("FILTER_FLAG_EMAIL_UNICODE", …)`.
- **First release:** **PHP 7.1.0** (tagged 2016-11-30) — confirmed via `git tag --contains`.
- **Official docs confirm** ([php.net manual, validate filters](https://www.php.net/manual/en/filter.filters.validate.php) / [constants](https://www.php.net/manual/en/filter.constants.php)): *"FILTER_FLAG_EMAIL_UNICODE — Accepts Unicode characters in the local part. **Available as of PHP 7.1.0.**"*

**What it changes (verified locally on PHP 8.5.5).** The flag swaps to `regexp0`, which is identical to the default `regexp1` except it adds the Unicode property classes `\pL` (any letter) and `\pN` (any number) to the **local-part** character classes only, and compiles with `/iDu` (adds `u` = PCRE2 `PCRE_UTF8|PCRE_UCP`). The **domain stays ASCII** — it must still be `xn--`/punycode or plain ASCII labels. Empirical proof:

```
用户@例え.jp              ascii=fail  unicode=fail   ← non-ASCII *domain* still rejected
用户@xn--80ak6aa92e.com   filter_var(...,UNICODE) → "用户@xn--80ak6aa92e.com"  (PASS)
                          filter_var(...) [no flag] → false                    (fail)
```

So: Unicode letters/numbers allowed **in the local part only**; the domain must be ASCII/punycode. Exactly as the docs say.

---

## 4. Notable bug reports, behavior-change reports & security advisories

**Security**
- **CVE-2007-1900 / MOPB-24 (Stefan Esser, "Month of PHP Bugs" 2007):** CRLF-injection in `FILTER_VALIDATE_EMAIL` in **PHP 5.2.0 / 5.2.1** — the (then PEAR) email regex allowed control characters enabling header injection. Fixed by `cd32cab6806` *"Fixed ext/filter Email Validation Vulnerability (MOPB-24 by Stefan Esser)"*, Ilia Alshanetsky, **2007-05-03**. Refs: [CVE-2007-1900 (cvedetails)](https://www.cvedetails.com/cve/CVE-2007-1900/), [vulners MOPB advisory set](https://vulners.com/securityvulns/SECURITYVULNS:DOC:16320).
- **2022 `filter_var` integer-conversion bypass** (Jordy Zomer, [Full-Disclosure 2022-Mar](https://seclists.org/fulldisclosure/2022/Mar/52); [calif.io write-up](https://blog.calif.io/p/mad-bugs-finding-and-exploiting-a)): an `int len` vs `size_t len` bug in `_php_filter_validate_domain()`. *Adjacent, not the email path* — it affects `FILTER_VALIDATE_DOMAIN`/`FILTER_FLAG_HOSTNAME` — but commonly cited alongside the email filter and worth flagging for a port.

**Behavior / correctness bug reports (all on the PEAR-era regex, 2008–2009), each a `php-src` commit:**
- #44445 — domains starting/ending with `-` mishandled (2008-03-18)
- #47282 — valid addresses wrongly marked invalid (2009-02-02)
- #47598 — validation was **locale-aware** (2009-03-08)
- #47772 — `foo@bar.` wrongly accepted (2009-03-25)
- #48718 — digits in domain components rejected (2009-07-05)
- #48808 — some invalid syntaxes accepted (2009-07-07)
- #50158 — addresses with `=` or `?` wrongly rejected (2009-11-15)

**On the Rushton-era regex:**
- **#49576** ([bugs.php.net/bug.php?id=49576](https://bugs.php.net/bug.php?id=49576)) — the driver for the 2010 rewrite; later re-opened over the `user@localhost` rejection and closed **"Won't fix"** 2012-08-16 by Rasmus (intranet single-label domains are intentionally rejected as non-routeable).
- **#69140** ([bugs.php.net/bug.php?id=69140](https://bugs.php.net/bug.php?id=69140)) — *"FILTER_VALIDATE_EMAIL should accept `user@localhost`"* — the canonical "surprising rejection" report; declined. Downstream pain documented in [Drupal #1427516](https://www.drupal.org/project/drupal/issues/1427516) (rejects `mesut@özil.de`, `admin@localhost`, etc.).
- **#55478** — *"FILTER_VALIDATE_EMAIL fails with IDN addresses containing >1 `-`"*, Ilia Alshanetsky, **2011-12-04** (commit `932f8d4cbdd`). This changed the domain-label hyphen quantifier from `-` to **`-+`** (`(?:-+[a-z0-9]+)*`) so punycode labels with consecutive hyphens validate. This is the only change to the Rushton regex *string* after 2010 — and it has been stable ever since (the literal hash is identical 7.1→8.5).

---

## 5. Behavior across PHP 5.x / 7.x / 8.x — which era does the Elixir port target?

| Era | Regex in effect | Engine | Observable behavior |
|---|---|---|---|
| **5.2.0 – 5.2.13, 5.3.0 – 5.3.2** | PEAR HTML_QuickForm flat regex | PCRE1 (`pcre_exec`) | Looser; accepts single-label domains, no IPv6 literals, no length caps; several known false-pos/neg (the #44445–#50158 series); was locale-aware. **Not** the target. |
| **5.2.14 / 5.3.3 → 7.0.x** | Rushton-derived flat regex (no Unicode flag) | PCRE1 | The modern behavior begins here. `a@b` rejected, IPv6 literals accepted, length caps enforced. From PHP 5.3.4 onward includes the #55478 `-+` fix. |
| **7.1.0 → 7.2.x** | Same regex **+** `FILTER_FLAG_EMAIL_UNICODE` (adds `regexp0` with `\pL\pN` in local part) | PCRE1 | Adds opt-in Unicode local part. Default behavior unchanged. |
| **7.3.0 → 7.4.x** | Same regex (string byte-identical) | **PCRE2** (`pcre2_match`, commit `a5bc5aed71`, 2017-10-12, PHP 7.3) | Engine swap only; matching semantics for these patterns are equivalent. |
| **8.0.0 → 8.5** | **Byte-identical** regex literals (`shasum` of the two `const char regexp` lines = `930750babe00` for 7.1.0, 7.4, 8.0.0, 8.4.10, 8.5) | PCRE2 | **No observable change** to `FILTER_VALIDATE_EMAIL` across the 8.x line. |

**Bottom line for the port:** the observable behavior is **stable and identical from PHP 7.1.0 through 8.5** (and matches 5.3.4–7.0 for the default/ASCII case, since only the opt-in Unicode flag was added at 7.1). An Elixir port reproducing PHP 8.5 therefore equally reproduces **any PHP ≥ 7.1**, and reproduces the default (non-Unicode) verdicts of any PHP ≥ 5.3.4. It does **not** match the looser PEAR-era behavior of PHP ≤ 5.3.2 / ≤ 5.2.13.

---

## Empirical verification re-run locally (for the verify agents)

- **PHP 8.5.5 CLI** verdicts: `a@b`→fail, `a@b.c`→pass, `test@example.com`→pass, `foo@bar.`→fail, `user@[127.0.0.1]`→pass, `"quoted"@example.com`→pass; `用户@xn--80ak6aa92e.com` → **pass with `FILTER_FLAG_EMAIL_UNICODE`, fail without**; `用户@例え.jp` → fail both (non-ASCII domain).
- **Erlang/OTP 28 `re`** compiled with PHP's exact `regexp1` inner pattern + `[caseless, dollar_endonly]` reproduces the ASCII verdicts byte-identically; `regexp0` + `[caseless, dollar_endonly, unicode, ucp]` reproduces the Unicode verdicts (incl. `用户@xn--80ak6aa92e.com` → PASS when the raw UTF-8 bytes are fed correctly). *Caveat for re-checkers:* feed raw UTF-8 **bytes** (e.g. an Erlang binary `<<16#e7,16#94,16#a8,…>>`), not a `"\xNN"` Erlang string literal — the latter is mangled under `unicode` mode and produces a spurious `nomatch`.

## Key primary sources
- php-src file & history: [`ext/filter/logical_filters.c`](https://github.com/php/php-src/blob/master/ext/filter/logical_filters.c), [commit history](https://github.com/php/php-src/commits/master/ext/filter/logical_filters.c). Pinned commits: `6d77506cfdf` (Rushton swap, 2010-04-02), `cd32cab6806` (MOPB-24 fix, 2007-05-03), `932f8d4cbdd` (#55478 `-+`, 2011-12-04), `8f4050709c8` (Unicode flag, 2015-10-15), `a5bc5aed71` (PCRE2, 2017-10-12).
- Bugs: [#49576](https://bugs.php.net/bug.php?id=49576), [#69140](https://bugs.php.net/bug.php?id=69140).
- Docs: [validate filters](https://www.php.net/manual/en/filter.filters.validate.php), [filter constants](https://www.php.net/manual/en/filter.constants.php).
- Rushton: blog `http://squiloople.com/2009/12/20/email-address-validation/` (dead, 404 live), ported source [dominicsayers MichaelRushton.php](https://github.com/dominicsayers/dominicsayers.com/blob/master/php/isemail/others/MichaelRushton.php), [jorgecolonconsulting/emailaddressvalidator](https://github.com/jorgecolonconsulting/emailaddressvalidator), single-string regex in [PHPMailer #439](https://github.com/PHPMailer/PHPMailer/issues/439), scoring at [fightingforalostcause](https://fightingforalostcause.net/content/misc/2006/compare-email-regex.php).
- Security: [CVE-2007-1900](https://www.cvedetails.com/cve/CVE-2007-1900/), [2022 filter_var disclosure](https://seclists.org/fulldisclosure/2022/Mar/52).

Local artifacts produced/used: `/tmp/lf_85.c`, `/tmp/lf_74.c`, `/tmp/lf_56.c`, `/tmp/cmp_php-7_1_0.c`, `/tmp/cmp_php-8_0_0.c`, `/tmp/cmp_php-8_4_10.c`, `/tmp/pat1.txt`, `/tmp/pat0.txt`, partial clone at `/tmp/phpsrc_hist`, verification escripts `/tmp/re_check.escript` and `/tmp/re_check2.escript`.
