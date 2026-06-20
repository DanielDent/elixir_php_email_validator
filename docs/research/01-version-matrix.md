# PHP `FILTER_VALIDATE_EMAIL`: Cross-Version Byte-Identity & Commit History

## TL;DR (the unambiguous answer)

**Yes — the email-validation regex pair, the 320-octet length check, and the unicode-flag selection logic are byte-for-byte IDENTICAL across every currently-supported PHP 8.x version (8.1, 8.2, 8.3, 8.4, 8.5) and across `master`.** This was proven by extracting the two C string literals from `ext/filter/logical_filters.c` at 11 different git refs (5 branches + `master` + 5 release tags), un-escaping C backslashes, and computing SHA-256:

- `regexp1` (default / ASCII): **`441ced67865b…`** — one distinct hash across all 11 refs
- `regexp0` (`FILTER_FLAG_EMAIL_UNICODE`): **`f40b5b868fe5…`** — one distinct hash across all 11 refs

The only difference anywhere in the *function* between the 8.1–8.4 line and 8.5/`master` is an inert return-type refactor (`void` → `zend_result`, with a matching `return SUCCESS;`). It does not change any validation verdict. The regex strings themselves have not changed since **2011** (ASCII part) / **2015** (unicode part).

---

## 1. Refs fetched

All fetched from `https://raw.githubusercontent.com/php/php-src/<REF>/ext/filter/logical_filters.c` (HTTP 200 for all):

| Kind | Refs |
|---|---|
| Branches | `PHP-8.1`, `PHP-8.2`, `PHP-8.3`, `PHP-8.4`, `PHP-8.5`, `master` |
| Release tags (latest stable per series) | `php-8.1.34`, `php-8.2.31`, `php-8.3.31`, `php-8.4.22`, `php-8.5.7` |

Tag selection: latest stable tags were enumerated with `git ls-remote --tags https://github.com/php/php-src.git`. 8.1 and 8.2 are end-of-life; their final stable tags are 8.1.34 and 8.2.31. 8.3/8.4/8.5 are active (latest stable at probe time: 8.3.31, 8.4.22, 8.5.7). I also fetched a wide spread of historical tags (5.2.0 → 7.4.33) to trace the commit history (see §5).

The local artifact `/tmp/lf_85.c` is byte-length-identical (31709 bytes) to the freshly fetched `PHP-8.5` and `php-8.5.7` files.

---

## 2. Per-ref hash table (the core proof)

Extraction method: located `const char regexpN[] = "…";`, captured the literal body, un-escaped C escapes (the task's required `\\` → `\` and `\"` → `"`; other escapes like `\x..` and `\.` are kept verbatim since the compiler stores their backslash literally for PCRE), then `shasum -a 256`. `shasum` and Python `hashlib` agree exactly.

| ref | regexp1 sha256 (short) | regexp0 sha256 (short) | length-limit | notes |
|---|---|---|---|---|
| PHP-8.1 | `441ced67865b` | `f40b5b868fe5` | `> 320` ✓ | 2 regexes, unicode-sel ✓; fn returns `void` |
| PHP-8.2 | `441ced67865b` | `f40b5b868fe5` | `> 320` ✓ | identical; `void` |
| PHP-8.3 | `441ced67865b` | `f40b5b868fe5` | `> 320` ✓ | identical; `void` |
| PHP-8.4 | `441ced67865b` | `f40b5b868fe5` | `> 320` ✓ | identical; `void` |
| PHP-8.5 | `441ced67865b` | `f40b5b868fe5` | `> 320` ✓ | identical; fn returns `zend_result` |
| master | `441ced67865b` | `f40b5b868fe5` | `> 320` ✓ | identical; `zend_result` |
| php-8.1.34 | `441ced67865b` | `f40b5b868fe5` | `> 320` ✓ | identical; `void` |
| php-8.2.31 | `441ced67865b` | `f40b5b868fe5` | `> 320` ✓ | identical; `void` |
| php-8.3.31 | `441ced67865b` | `f40b5b868fe5` | `> 320` ✓ | identical; `void` |
| php-8.4.22 | `441ced67865b` | `f40b5b868fe5` | `> 320` ✓ | identical; `void` |
| php-8.5.7 | `441ced67865b` | `f40b5b868fe5` | `> 320` ✓ | identical; `zend_result` |

Full hashes:
- `regexp1` = `441ced67865bdd1975f9518c4bf41cb0c510cc7edd395769ec4acd34d384c86f`
- `regexp0` = `f40b5b868fe53fc3d820e4500032360528eb3c9af223753c6c197c1513bfe320`

For **every** ref: the `Z_STRLEN_P(value) > 320` guard is present with the exact value **320** (comment: *"The maximum length of an e-mail address is 320 octets, per RFC 2821."*); there are **exactly two** regex literals (`regexp0`, `regexp1`); and the `if (flags & FILTER_FLAG_EMAIL_UNICODE) { regexp = regexp0; } else { regexp = regexp1; }` selection is present. Even the **raw C-literal source bytes** (before any un-escaping) hash to a single value across all 11 refs (1 distinct hash each) — so it is not merely semantic equality, the source text of the literals is character-identical.

---

## 3. The exact post-unescape strings (canonical, from PHP-8.5 ≡ all refs)

These include the PHP-style `/…/` delimiters and inline-flag suffix as they appear in the literal. (`pcre_get_compiled_regex` parses these delimiters; flags: `i`=caseless, `D`=`PCRE2_DOLLAR_ENDONLY`, `u`=`PCRE2_UTF|PCRE2_UCP`.)

**`regexp1` — default / ASCII-only (suffix `/iD`), 1072 bytes:**
```
/^(?!(?:(?:\x22?\x5C[\x00-\x7E]\x22?)|(?:\x22?[^\x5C\x22]\x22?)){255,})(?!(?:(?:\x22?\x5C[\x00-\x7E]\x22?)|(?:\x22?[^\x5C\x22]\x22?)){65,}@)(?:(?:[\x21\x23-\x27\x2A\x2B\x2D\x2F-\x39\x3D\x3F\x5E-\x7E]+)|(?:\x22(?:[\x01-\x08\x0B\x0C\x0E-\x1F\x21\x23-\x5B\x5D-\x7F]|(?:\x5C[\x00-\x7F]))*\x22))(?:\.(?:(?:[\x21\x23-\x27\x2A\x2B\x2D\x2F-\x39\x3D\x3F\x5E-\x7E]+)|(?:\x22(?:[\x01-\x08\x0B\x0C\x0E-\x1F\x21\x23-\x5B\x5D-\x7F]|(?:\x5C[\x00-\x7F]))*\x22)))*@(?:(?:(?!.*[^.]{64,})(?:(?:(?:xn--)?[a-z0-9]+(?:-+[a-z0-9]+)*\.){1,126}){1,}(?:(?:[a-z][a-z0-9]*)|(?:(?:xn--)[a-z0-9]+))(?:-+[a-z0-9]+)*)|(?:\[(?:(?:IPv6:(?:(?:[a-f0-9]{1,4}(?::[a-f0-9]{1,4}){7})|(?:(?!(?:.*[a-f0-9][:\]]){7,})(?:[a-f0-9]{1,4}(?::[a-f0-9]{1,4}){0,5})?::(?:[a-f0-9]{1,4}(?::[a-f0-9]{1,4}){0,5})?)))|(?:(?:IPv6:(?:(?:[a-f0-9]{1,4}(?::[a-f0-9]{1,4}){5}:)|(?:(?!(?:.*[a-f0-9]:){5,})(?:[a-f0-9]{1,4}(?::[a-f0-9]{1,4}){0,3})?::(?:[a-f0-9]{1,4}(?::[a-f0-9]{1,4}){0,3}:)?)))?(?:(?:25[0-5])|(?:2[0-4][0-9])|(?:1[0-9]{2})|(?:[1-9]?[0-9]))(?:\.(?:(?:25[0-5])|(?:2[0-4][0-9])|(?:1[0-9]{2})|(?:[1-9]?[0-9]))){3}))\]))$/iD
```

**`regexp0` — `FILTER_FLAG_EMAIL_UNICODE` (suffix `/iDu`), 1097 bytes:**
```
/^(?!(?:(?:\x22?\x5C[\x00-\x7E]\x22?)|(?:\x22?[^\x5C\x22]\x22?)){255,})(?!(?:(?:\x22?\x5C[\x00-\x7E]\x22?)|(?:\x22?[^\x5C\x22]\x22?)){65,}@)(?:(?:[\x21\x23-\x27\x2A\x2B\x2D\x2F-\x39\x3D\x3F\x5E-\x7E\pL\pN]+)|(?:\x22(?:[\x01-\x08\x0B\x0C\x0E-\x1F\x21\x23-\x5B\x5D-\x7F\pL\pN]|(?:\x5C[\x00-\x7F]))*\x22))(?:\.(?:(?:[\x21\x23-\x27\x2A\x2B\x2D\x2F-\x39\x3D\x3F\x5E-\x7E\pL\pN]+)|(?:\x22(?:[\x01-\x08\x0B\x0C\x0E-\x1F\x21\x23-\x5B\x5D-\x7F\pL\pN]|(?:\x5C[\x00-\x7F]))*\x22)))*@(?:(?:(?!.*[^.]{64,})(?:(?:(?:xn--)?[a-z0-9]+(?:-+[a-z0-9]+)*\.){1,126}){1,}(?:(?:[a-z][a-z0-9]*)|(?:(?:xn--)[a-z0-9]+))(?:-+[a-z0-9]+)*)|(?:\[(?:(?:IPv6:(?:(?:[a-f0-9]{1,4}(?::[a-f0-9]{1,4}){7})|(?:(?!(?:.*[a-f0-9][:\]]){7,})(?:[a-f0-9]{1,4}(?::[a-f0-9]{1,4}){0,5})?::(?:[a-f0-9]{1,4}(?::[a-f0-9]{1,4}){0,5})?)))|(?:(?:IPv6:(?:(?:[a-f0-9]{1,4}(?::[a-f0-9]{1,4}){5}:)|(?:(?!(?:.*[a-f0-9]:){5,})(?:[a-f0-9]{1,4}(?::[a-f0-9]{1,4}){0,3})?::(?:[a-f0-9]{1,4}(?::[a-f0-9]{1,4}){0,3}:)?)))?(?:(?:25[0-5])|(?:2[0-4][0-9])|(?:1[0-9]{2})|(?:[1-9]?[0-9]))(?:\.(?:(?:25[0-5])|(?:2[0-4][0-9])|(?:1[0-9]{2})|(?:[1-9]?[0-9]))){3}))\]))$/iDu
```

The only structural difference between the two: `regexp0` adds the unicode property classes **`\pL\pN`** (letters + numbers) to the four local-part character classes, and uses the `u` flag. The domain part is byte-identical between them — i.e. **Unicode is allowed only in the local part**, not the domain. (This matches the empirically observed behavior: `日本語@example.com` passes with the flag, but `test@日本語.com` does not.)

---

## 4. Differences across versions — explicit call-out

- **Regex strings:** zero differences. Identical bytes across 8.1→8.5 and `master` (and, as it turns out, identical all the way back to PHP 5.3.10 for `regexp1` and PHP 7.1 for `regexp0`).
- **Length check:** identical (`> 320`) everywhere.
- **Flag selection:** identical everywhere.
- **The one function-level difference (behaviorally inert):** the surrounding `logical_filters.c` file grew (27 KB in 8.1 → 31 KB in 8.5) due to unrelated changes (RFC 6890 IP-range tables, const-qualifier cleanups, etc.), and the `php_filter_validate_email` function signature changed:
  - PHP 8.1–8.4: `void php_filter_validate_email(PHP_INPUT_FILTER_PARAM_DECL)`
  - PHP 8.5 / master: `zend_result php_filter_validate_email(PHP_INPUT_FILTER_PARAM_DECL)` + a trailing `return SUCCESS;`

  The unified diff of the *entire function* between 8.4 and 8.5 is exactly:
  ```
  -void php_filter_validate_email(PHP_INPUT_FILTER_PARAM_DECL) /* {{{ */
  +zend_result php_filter_validate_email(PHP_INPUT_FILTER_PARAM_DECL) /* {{{ */
  ...
   		RETURN_VALIDATION_FAILED
   	}
  +	return SUCCESS;
   }
  ```
  This is a subsystem-wide refactor of every filter callback's return type; it has no effect on the accept/reject verdict for any email. (The `RETURN_VALIDATION_FAILED` macro in `filter_private.h` changed in lockstep — `return;` → `return SUCCESS;` — and also shows an unrelated `FILTER_NULL_ON_FAILURE` → `FILTER_THROW_ON_FAILURE` rename in 8.5; neither alters email matching.)
- **`master` / future version:** byte-identical to 8.5 for both regexes — **no pending change** to the regex strings, length check, or flag logic is staged in `master`.

### Empirical re-verification (independent of the C source)
- Live **PHP 8.5.5** `filter_var(..., FILTER_VALIDATE_EMAIL)` reproduced the stored 31-case verdict corpus (`/tmp/php_out.txt`) **identically** (`diff` empty).
- **Erlang/OTP 28** `re`, compiling the *extracted* inner patterns with PHP's exact options — `regexp1` → `[caseless, dollar_endonly]` (byte mode), `regexp0` → `[caseless, dollar_endonly, unicode, ucp]` — plus the `> 320` byte gate, reproduced **both** the 31-case ASCII corpus and a 10-case unicode corpus **byte-for-byte identically** to live PHP. This confirms the strings I extracted are the true operative patterns and that the cross-OS PCRE2 semantics match.

---

## 5. Commit history of the regex

The actual lineage is more precise than "recursive `(?1)(?2)` replaced around 8.0." In fact, **php-src never shipped Rushton's recursive `(?1)(?2)`/`DEFINE` form** — it imported a pre-flattened version. Three eras:

| Era | Form | First seen |
|---|---|---|
| 1 | Original hand-rolled regex (not Rushton; ends `/`) | PHP 5.2.0 (2006) |
| 2 | **Michael Rushton-based flat regex introduced** (single `regexp[]`, `/iD`) | PHP 5.3 dev — commit `fcbb8e96f4` |
| 3 | Two-regex split + `\pL\pN` unicode variant (`regexp0`/`regexp1`) | PHP 7.1 — commit `8f4050709c` |

### (a) Commit that introduced the current flat Rushton regex
- **Hash:** `fcbb8e96f4e31bafc646ca40d8ac77e4bbaadafd`
- **Author/Date:** Rasmus Lerdorf, **2010-04-02**
- **Message:** *"Update the FILTER_VALIDATE_EMAIL filter to fix bug #49576"* (`logical_filters.c` +25/−2)
- **What it did:** removed the old PHP 5.2-era hand-rolled `regexp[]` and added the Michael-Rushton-attributed flat regex (with the `Copyright © Michael Rushton 2009-10 / http://squiloople.com/` notice that still survives today). First shipped in the PHP 5.3.x line.
- URL: https://github.com/php/php-src/commit/fcbb8e96f4e31bafc646ca40d8ac77e4bbaadafd — bug: https://bugs.php.net/bug.php?id=49576

  *(Note on the premise: PHP's regex was never the recursive `(?1)(?2)` version; the recursive form was Rushton's published variant. php-src adopted an expanded/flat variant in 2010 and has kept it flat ever since. A grep for `(?1)(?2)`/`DEFINE` returns zero hits in every released php-src tag from 5.2.0 onward.)*

- **One subsequent tweak to the ASCII regex** (the change that produced today's exact `regexp1` bytes): **`dfa08dc3258b6405f25aec04106d705b3140c778`**, Ilia Alshanetsky, **2011-12-04**, *"Fixed Bug #55478 (FILTER_VALIDATE_EMAIL fails with internationalized domain name addresses containing >1 -)."* This is the `-` → `-+` change in the domain-label subpattern (allowing more than one consecutive hyphen, e.g. `xn--` IDN labels). Shipped in PHP 5.3.9 / 5.4.0. Verified by bisection: `regexp1` hash is `8d6a8824…` at 5.3.6 but `441ced67…` (current) at 5.3.10. URL: https://github.com/php/php-src/commit/dfa08dc3258b6405f25aec04106d705b3140c778 — bug: https://bugs.php.net/bug.php?id=55478

### (b) Most recent commit that modified either regex string
- **Hash:** `8f4050709c833b9d42cd65349b7747f8e61d171f`
- **Author:** Leo Feyer `<github@contao.org>`, authored **2015-10-15**; committed by Anatol Belski **2016-07-18** (for the PHP 7.1 cycle)
- **Message:** *"Support Unicode characters in the local part of an e-mail address. See RFC 6531…"* (`logical_filters.c` +6/−1; also touched `filter.c`, `filter_private.h`, `tests/058.phpt`)
- **What it did:** introduced the second regex (`regexp0`, the `\pL\pN`/`/iDu` variant), the two-regex split, and the new flag (committed as `FILTER_FLAG_EMAIL_RFC6531`, **renamed to `FILTER_FLAG_EMAIL_UNICODE` before the 7.1 release**). This is the **last time either regex literal changed** — both have been frozen ever since (≈10 years).
- **PR / RFC / bug:** GitHub **PR #1577** ("FILTER_VALIDATE_EMAIL unicode support (RFC 6531)" by leofeyer); bug **#72244**; RFC 6531.
- URLs: https://github.com/php/php-src/commit/8f4050709c833b9d42cd65349b7747f8e61d171f · https://github.com/php/php-src/pull/1577 · https://bugs.php.net/bug.php?id=72244 · https://datatracker.ietf.org/doc/html/rfc6531

No commit after `8f4050709c` has altered `regexp0` or `regexp1`. The post-2015 commits touching `logical_filters.c` (verified via `GET /repos/php/php-src/commits?path=ext/filter/logical_filters.c&per_page=100`) only touched IP-range/IPv6 logic, const/`bool`/`zend_string` refactors, the `void`→`zend_result` change, `FILTER_THROW_ON_FAILURE` (PR #18896), and license headers — never the email regex.

---

## 6. "What to watch" — drift detector spec

A drift detector for `FILTER_VALIDATE_EMAIL` must monitor exactly this:

- **File:** `ext/filter/logical_filters.c`
- **Function:** `php_filter_validate_email`
- **The two variable names to monitor:** the C string literals **`regexp1`** (default/ASCII, `…/iD`) and **`regexp0`** (`FILTER_FLAG_EMAIL_UNICODE`, `…/iDu`).
- **Also monitor (secondary):** the `Z_STRLEN_P(value) > 320` length guard, and the `if (flags & FILTER_FLAG_EMAIL_UNICODE)` selection block, both inside the same function.

**Canonical fetch + check for any release** (replace `<REF>` with a branch like `PHP-8.5` or a tag like `php-8.5.7`):
```
curl -s "https://raw.githubusercontent.com/php/php-src/<REF>/ext/filter/logical_filters.c"
```
Extract the `regexp0`/`regexp1` literals, un-escape `\\`→`\` and `\"`→`"`, and compare SHA-256 against the known-good baselines:
- `regexp1` → `441ced67865bdd1975f9518c4bf41cb0c510cc7edd395769ec4acd34d384c86f`
- `regexp0` → `f40b5b868fe53fc3d820e4500032360528eb3c9af223753c6c197c1513bfe320`

Any deviation from those two hashes (or a `320` that becomes some other number, or the disappearance of the two-regex/flag structure) means PHP changed its email-validation semantics. As of `master` today, no such change is pending.

---

### Artifacts produced (all under `/tmp/phpfetch/`, absolute paths)
- `/tmp/phpfetch/lf_<ref>.c` — fetched `logical_filters.c` for each of the 11 refs (plus historical `lf_old_*`, `lf_e_*`, `lf_b_*` tags 5.2.0→7.4.33)
- `/tmp/phpfetch/extract.py` — extraction + C-unescape + SHA-256 harness
- `/tmp/phpfetch/results.json` — per-ref hashes and unescaped strings
- `/tmp/phpfetch/regexp1_unescaped.txt`, `/tmp/phpfetch/regexp0_unescaped.txt` — canonical strings
- `/tmp/phpfetch/eqcheck.escript` — Erlang/OTP 28 re-verification script
- `/tmp/phpfetch/c_*.json`, `commits_*.json`, `search_uni.json` — commit metadata from the GitHub API

### Sources
- php-src file (current): https://github.com/php/php-src/blob/master/ext/filter/logical_filters.c
- Flat Rushton regex introduced: https://github.com/php/php-src/commit/fcbb8e96f4e31bafc646ca40d8ac77e4bbaadafd (bug https://bugs.php.net/bug.php?id=49576)
- `-`→`-+` tweak: https://github.com/php/php-src/commit/dfa08dc3258b6405f25aec04106d705b3140c778 (bug https://bugs.php.net/bug.php?id=55478)
- Unicode flag / last regex change: https://github.com/php/php-src/commit/8f4050709c833b9d42cd65349b7747f8e61d171f · PR https://github.com/php/php-src/pull/1577 · bug https://bugs.php.net/bug.php?id=72244 · RFC https://datatracker.ietf.org/doc/html/rfc6531
- Michael Rushton's original (Wayback): https://web.archive.org/web/20150910045413/http://squiloople.com/2009/
