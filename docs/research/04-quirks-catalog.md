# PHP `filter_var($email, FILTER_VALIDATE_EMAIL)` — Quirks Catalog (PHP 8.5.5)

## How this was produced (ground truth, not guessed)

Every verdict below comes from the **local PHP 8.5.5 CLI** (`PHP 8.5.5 (cli) ... Built by Homebrew`), not from reasoning. Method:

1. All 136 inputs were written as **base64, one per line** (so NUL bytes, raw control bytes, newlines, spaces and backslashes survive intact — no shell/argv quoting hazards).
2. A harness (`/tmp/verdict.php`) base64-decodes each line and runs both:
   - `filter_var($raw, FILTER_VALIDATE_EMAIL)` → **default** verdict
   - `filter_var($raw, FILTER_VALIDATE_EMAIL, FILTER_FLAG_EMAIL_UNICODE)` → **unicode** verdict
   - `!== false` is treated as `valid`.
3. **Independent cross-check:** the exact PHP-8.5 inner patterns (`/tmp/pat1.txt`, `/tmp/pat0.txt`, extracted from `ext/filter/logical_filters.c`) were compiled in **Erlang/OTP 28 `:re`** — `regexp1` with `[caseless, dollar_endonly]`, `regexp0` with `[caseless, dollar_endonly, unicode, ucp]` — and run on the same raw bytes. **All 135 non-blank cases matched PHP byte-identically (`mismatches=0`).** This confirms the harness is correct and that `:re` is a faithful oracle (the one place they can diverge is the 320-octet pre-check, which lives in C, not the regex — see below).

Source of the C implementation and regex literals (line numbers from the locally extracted `/tmp/lf_85.c`, which mirrors upstream):
- `ext/filter/logical_filters.c`, `php_filter_validate_email`: regex literals at lines 704 (`regexp0`, suffix `/iDu`) and 705 (`regexp1`, suffix `/iD`); the 320-octet guard at lines 717–720. Upstream raw file: https://raw.githubusercontent.com/php/php-src/PHP-8.5/ext/filter/logical_filters.c
- Flags: `i` = caseless, `D` = `PCRE_DOLLAR_ENDONLY`, `u` = `PCRE2_UTF | PCRE2_UCP`. The `D` flag is why a trailing `\n` is rejected (`$` no longer matches before a final newline).
- The regex derives from Michael Rushton's 2009–2010 validator (copyright preserved in the php-src comment).

## The biggest quirk: the practical length cap is **254**, not 320

There are **two** length gates, and they disagree:

- **C pre-check** (lines 717–720): `if (Z_STRLEN_P(value) > 320) RETURN_VALIDATION_FAILED;` — comment says *"The maximum length of an e-mail address is 320 octets, per RFC 2821."*
- **Regex first lookahead**: `(?!(?:(?:"?\x5C[\x00-\x7E]"?)|(?:"?[^\x5C"]"?)){255,})`. The alternative `(?:"?[^\x5C"]"?)` matches **almost any byte** (anything except backslash/quote) — including `@` and the whole domain — so it counts the entire string, not just the local part. Any well-formed address of **255+ bytes is rejected by the regex** before the 320 gate is ever the binding constraint.

I binary-searched this on real PHP with valid-label addresses (local ≤ 64, every domain label ≤ 63): verdict flips from valid→INVALID at **total length 255** (254 = last valid). So for any structurally valid address, the effective maximum is **254 bytes**; the documented 320 figure only ever short-circuits malformed/pathological inputs. (Rows 104–108 encode this boundary precisely.)

## Categories covered

Basic · Domain labels (hyphens, dots, label length 63 vs 64, numeric/`xn--` TLDs, underscores) · Bare vs bracketed IPv4 (leading zeros, out-of-range) · IPv6 literals (compressed, embedded IPv4, malformed) · Local part (quoted strings, escaped vs bare space, dot-atom rules, atext specials, comments) · Control bytes (which control chars the quoted class admits) · Length boundaries (local 64/65, total 254/255/320/321) · Case-insensitivity · Unicode under `FILTER_FLAG_EMAIL_UNICODE` (letters `\pL` and numbers `\pN` allowed in local part only; domain stays ASCII; symbols/emoji/combining marks rejected) · Trailing/leading/embedded newline, NUL, space, tab.

## Reading the table

- **default** = `filter_var(..., FILTER_VALIDATE_EMAIL)`; **unicode** = same with `FILTER_FLAG_EMAIL_UNICODE`.
- Inputs are shown literally where printable. Non-printable or ambiguous content is described in parentheses: `<TAB>`=0x09, `<LF>`=0x0A, `<CR>`=0x0D, `<NUL>`=0x00, `<BEL>`=0x07, `<VT>`=0x0B, `<space>`=0x20; `(literal space)` / `(literal backslash)` flag bytes that would otherwise be invisible. `<NN x's>` / `<valid addr, total N bytes>` denote machine-generated length cases.
- The only default→unicode differences in the whole corpus are the Unicode-letter/number local-part rows (112, 113, 114, 117, 118, 119, 120, 124, 125, 126, 127): `INVALID` by default, `valid` with the flag. Everything else has identical default/unicode verdicts.

## The catalog (136 cases)

| # | input | default | unicode | category | why |
|---|-------|---------|---------|----------|-----|
| 1 | `a@b.c` | valid | valid | Basic | minimal valid: local + domain with a dot/TLD |
| 2 | `a@b` | INVALID | INVALID | Basic | domain has no dot; regex domain branch requires at least one label + TLD |
| 3 | `test@example.com` | valid | valid | Basic | ordinary valid address |
| 4 | `(empty string)` | INVALID | INVALID | Basic | empty input never matches the anchored regex |
| 5 | `(single space)` | INVALID | INVALID | Basic | whitespace-only; space is not a valid local-part char |
| 6 | `(three spaces)` | INVALID | INVALID | Basic | whitespace-only; never valid |
| 7 | `a@b.com` | valid | valid | Basic | ordinary valid |
| 8 | `plainaddress` | INVALID | INVALID | Basic | no @ at all |
| 9 | `a@@b.com` | INVALID | INVALID | Basic | two @ signs; local/domain split fails |
| 10 | `a@-b.com` | INVALID | INVALID | Domain labels | leading hyphen in label; label must start [a-z0-9] |
| 11 | `a@b-.com` | INVALID | INVALID | Domain labels | trailing hyphen before dot; label must end [a-z0-9] |
| 12 | `a@d-.com` | INVALID | INVALID | Domain labels | trailing hyphen in first label (TLD ok) - invalid |
| 13 | `a@-d.com` | INVALID | INVALID | Domain labels | leading hyphen first label - invalid |
| 14 | `a@b..c` | INVALID | INVALID | Domain labels | consecutive dots = empty label, not allowed |
| 15 | `a@b.com.` | INVALID | INVALID | Domain labels | trailing dot leaves empty final TLD label - invalid |
| 16 | `foo@bar.com.` | INVALID | INVALID | Domain labels | trailing root dot rejected by this regex |
| 17 | `a@b-c.com` | valid | valid | Domain labels | internal hyphen is fine |
| 18 | `a@b--c.com` | valid | valid | Domain labels | consecutive internal hyphens allowed by (-+[a-z0-9]+) |
| 19 | `a@b_c.com` | INVALID | INVALID | Domain labels | underscore not in [a-z0-9]; domain rejects underscore |
| 20 | `a@b.c_d` | INVALID | INVALID | Domain labels | underscore in TLD label - invalid |
| 21 | `a@<63 x's>.com` | valid | valid | Domain labels | 63-char label OK; (?!.*[^.]{64,}) negative lookahead allows 63 |
| 22 | `a@<64 x's>.com` | INVALID | INVALID | Domain labels | 64-char label tripped by (?!.*[^.]{64,}) - invalid |
| 23 | `a@<63>.<63>.com` | valid | valid | Domain labels | two 63-char labels OK individually |
| 24 | `a@b.123` | INVALID | INVALID | Domain labels | TLD branch is [a-z][a-z0-9]* OR xn--...; all-digit TLD has no leading letter - invalid |
| 25 | `a@b.c123` | valid | valid | Domain labels | TLD starts with letter then digits - valid |
| 26 | `a@b.1c` | INVALID | INVALID | Domain labels | TLD starts with digit - invalid |
| 27 | `a@b.c` | valid | valid | Domain labels | single-char alpha TLD allowed ([a-z][a-z0-9]*) |
| 28 | `a@b.x` | valid | valid | Domain labels | single-char alpha TLD valid |
| 29 | `a@xn--80ak6aa92e.com` | valid | valid | Domain labels | xn-- punycode label handled by (?:xn--)?[a-z0-9]+... |
| 30 | `a@example.xn--p1ai` | valid | valid | Domain labels | xn-- punycode TLD allowed by (?:xn--)[a-z0-9]+ TLD branch |
| 31 | `a@xn--.com` | INVALID | INVALID | Domain labels | xn-- with no following alnum - invalid |
| 32 | `a@b.c.d.e.f.g` | valid | valid | Domain labels | many labels allowed (up to 126 per quantifier) |
| 33 | `a@b.co` | valid | valid | Domain labels | two-char TLD valid |
| 34 | `a@localhost` | INVALID | INVALID | Domain labels | single bare label, no dot/TLD - invalid |
| 35 | `user@localhost` | INVALID | INVALID | Domain labels | localhost has no TLD dot - invalid |
| 36 | `a@b.c-d` | valid | valid | Domain labels | TLD label with hyphen via (?:-+[a-z0-9]+)* - valid |
| 37 | `a@3.com` | valid | valid | Domain labels | numeric leading label OK ([a-z0-9]+), letter TLD |
| 38 | `a@1.2.3.4` | INVALID | INVALID | IP literal | bare IPv4 not bracketed; treated as domain, '4' TLD starts digit - invalid |
| 39 | `a@[1.2.3.4]` | valid | valid | IP literal | bracketed IPv4 literal handled by [ ... ] branch |
| 40 | `a@[127.0.0.1]` | valid | valid | IP literal | bracketed loopback valid |
| 41 | `a@127.0.0.1` | INVALID | INVALID | IP literal | bare IP, TLD '1' invalid |
| 42 | `a@[01.2.3.4]` | INVALID | INVALID | IP literal | leading-zero octet; regex octet alts don't allow '01' (0[1-9] not matched) - invalid |
| 43 | `a@[001.2.3.4]` | INVALID | INVALID | IP literal | leading zeros - invalid octet form |
| 44 | `a@[999.1.1.1]` | INVALID | INVALID | IP literal | 999 out of 0-255 range per octet alternation - invalid |
| 45 | `a@[256.1.1.1]` | INVALID | INVALID | IP literal | 256 > 255 - invalid |
| 46 | `a@[255.255.255.255]` | valid | valid | IP literal | max valid IPv4 octets |
| 47 | `a@[0.0.0.0]` | valid | valid | IP literal | all-zero octets valid (0 matches [1-9]?[0-9]) |
| 48 | `a@[1.2.3]` | INVALID | INVALID | IP literal | only 3 octets - invalid |
| 49 | `a@[1.2.3.4.5]` | INVALID | INVALID | IP literal | 5 octets - invalid |
| 50 | `a@[123.45.67.89]` | valid | valid | IP literal | valid bracketed IPv4 |
| 51 | `a@123.45.67.89` | INVALID | INVALID | IP literal | bare; TLD '89' digit-leading invalid |
| 52 | `email@123.123.123.123` | INVALID | INVALID | IP literal | bare IP as domain, numeric TLD invalid |
| 53 | `x@111.222.333.44444` | INVALID | INVALID | IP literal | bare, not IP literal, numeric TLD invalid |
| 54 | `a@[IPv6:::1]` | valid | valid | IPv6 | compressed loopback ::1 valid |
| 55 | `a@[IPv6:fe80::1]` | valid | valid | IPv6 | link-local compressed valid |
| 56 | `a@[IPv6:2001:db8::1]` | valid | valid | IPv6 | doc-prefix compressed valid |
| 57 | `a@[IPv6:<full 8 groups>]` | valid | valid | IPv6 | full 8-group form valid (input: `a@[IPv6:2001:0db8:0000:0000:0000:0000:0000:0001]`) |
| 58 | `a@[IPv6:1:2:3:4:5:6:7:8]` | valid | valid | IPv6 | exactly 8 groups valid |
| 59 | `a@[IPv6:1:2:3:4:5:6:7:8:9]` | INVALID | INVALID | IPv6 | 9 groups - too many, invalid |
| 60 | `a@[IPv6:::]` | valid | valid | IPv6 | all-zero compressed :: valid |
| 61 | `a@[IPv6:gggg::1]` | INVALID | INVALID | IPv6 | g is not a hex digit [a-f0-9] - invalid |
| 62 | `a@[IPv6:12345::1]` | INVALID | INVALID | IPv6 | 5-hex-digit group exceeds {1,4} - invalid |
| 63 | `a@[IPv6:::ffff:1.2.3.4]` | valid | valid | IPv6 | IPv4-mapped/embedded IPv4 tail valid |
| 64 | `a@[IPv6:2001:db8::1.2.3.4]` | valid | valid | IPv6 | compressed + embedded IPv4 valid |
| 65 | `a@[IPv6:1.2.3.4]` | INVALID | INVALID | IPv6 | IPv6 tag but only IPv4, no ::; needs :: prefix path - invalid |
| 66 | `a@[1:2:3:4:5:6:7:8]` | INVALID | INVALID | IPv6 | IPv6 groups without IPv6: tag - invalid |
| 67 | `a@[IPv6fe80::1]` | INVALID | INVALID | IPv6 | missing colon after IPv6 tag - invalid |
| 68 | `"quoted"@example.com` | valid | valid | Local part | quoted-string local part allowed |
| 69 | `"a b"@c.de` (literal space inside quotes) | INVALID | INVALID | Local part | bare space even quoted is NOT in quoted-char class - invalid |
| 70 | `"a b"@x.com` (literal space) | INVALID | INVALID | Local part | space char excluded from quoted class [\x01-..] (no 0x20) - invalid |
| 71 | `much."more\ unusual"@example.com` (literal backslash-space) | valid | valid | Local part | backslash-escaped space via \x5C[\x00-\x7F] - valid |
| 72 | `"much.more unusual"@x.com` (literal space) | INVALID | INVALID | Local part | unescaped space in quotes invalid |
| 73 | `".foo"@bar.com` | valid | valid | Local part | leading dot inside quotes is fine (quoted content) |
| 74 | `.foo@bar.com` | INVALID | INVALID | Local part | leading dot in unquoted local - invalid (dot-atom) |
| 75 | `foo.@bar.com` | INVALID | INVALID | Local part | trailing dot in unquoted local - invalid |
| 76 | `a..b@x.com` | INVALID | INVALID | Local part | consecutive dots in unquoted local - empty atom invalid |
| 77 | `a.b@x.com` | valid | valid | Local part | single internal dot valid (dot-atom) |
| 78 | `@x.com` | INVALID | INVALID | Local part | empty local part - invalid |
| 79 | `@example.com` | INVALID | INVALID | Local part | empty local part - invalid |
| 80 | `a@` | INVALID | INVALID | Local part | empty domain - invalid |
| 81 | `!#$%&'*+-/=?^_`{\|}~@x.com` | valid | valid | Local part | all RFC atext specials allowed in dot-atom local |
| 82 | `a(comment)b@x.com` (parens) | INVALID | INVALID | Local part | ( ) not in atext class; comments unsupported - invalid |
| 83 | `a,b@x.com` | INVALID | INVALID | Local part | comma not in atext - invalid |
| 84 | `a;b@x.com` | INVALID | INVALID | Local part | semicolon not in atext - invalid |
| 85 | `a:b@x.com` | INVALID | INVALID | Local part | colon not in atext (unquoted) - invalid |
| 86 | `a b@c.de` (literal space) | INVALID | INVALID | Local part | unquoted space - invalid |
| 87 | `a\@b@x.com` (literal backslash) | INVALID | INVALID | Local part | backslash-at unquoted; backslash not atext - invalid |
| 88 | `"a@b"@x.com` | valid | valid | Local part | @ inside quotes is fine; outer @ splits |
| 89 | `"a\"b"@x.com` (escaped quote) | valid | valid | Local part | escaped quote inside quoted string valid |
| 90 | `""@x.com` | valid | valid | Local part | empty quoted string local part - valid (quoted* allows zero) |
| 91 | `"\\"@x.com` (quoted backslash) | valid | valid | Local part | quoted escaped backslash valid |
| 92 | `a<TAB>b@x.com` (0x09) | INVALID | INVALID | Control bytes | raw TAB not in unquoted atext - invalid |
| 93 | `a<NUL>b@x.com` (0x00) | INVALID | INVALID | Control bytes | raw NUL not valid in unquoted local - invalid |
| 94 | `"a<TAB>b"@x.com` (0x09 in quotes) | INVALID | INVALID | Control bytes | 0x09 not in quoted class (\x0B,\x0C,... but not 0x09) - invalid |
| 95 | `"a<BEL>b"@x.com` (0x07 in quotes) | valid | valid | Control bytes | 0x07 IS in quoted class \x01-\x08 - valid |
| 96 | `"a<0x01>b"@x.com` | valid | valid | Control bytes | 0x01 in quoted class \x01-\x08 - valid |
| 97 | `"a<LF>b"@x.com` (0x0A in quotes) | INVALID | INVALID | Control bytes | 0x0A (LF) excluded from quoted class - invalid |
| 98 | `"a<CR>b"@x.com` (0x0D in quotes) | INVALID | INVALID | Control bytes | 0x0D (CR) excluded - invalid |
| 99 | `"a<VT>b"@x.com` (0x0B in quotes) | valid | valid | Control bytes | 0x0B in quoted class - valid |
| 100 | `<64 a's>@x.com` | valid | valid | Length | 64-char local OK; lookahead (?!...{65,}@) blocks >=65 |
| 101 | `<65 a's>@x.com` | INVALID | INVALID | Length | 65-char local tripped by (?!(?:...){65,}@) - invalid |
| 102 | `<63 a's>@x.com` | valid | valid | Length | 63-char local OK |
| 103 | `<64 a's>@bb.com` | valid | valid | Length | boundary 64-char local with valid domain - valid |
| 104 | `<valid addr, total 253 bytes>` | valid | valid | Length | 253-byte well-formed address (local<=64, labels<=63) - valid |
| 105 | `<valid addr, total 254 bytes>` | valid | valid | Length | 254 bytes = the REAL practical max; first lookahead (?!(?:...){255,}) counts whole string - still valid |
| 106 | `<valid addr, total 255 bytes>` | INVALID | INVALID | Length | 255 bytes: rejected by the regex's FIRST lookahead {255,} (NOT the 320 C check) - INVALID. Effective cap is 254, not 320 |
| 107 | `<valid addr, total 320 bytes>` | INVALID | INVALID | Length | 320 bytes: even though the C pre-check allows <=320, the {255,} regex lookahead already rejects it - INVALID |
| 108 | `<valid addr, total 321 bytes>` | INVALID | INVALID | Length | 321 bytes: rejected by the explicit C length pre-check (>320) BEFORE the regex runs - INVALID |
| 109 | `USER@EXAMPLE.COM` | valid | valid | Case | caseless /i flag; uppercase domain matches [a-z] |
| 110 | `MixedCase@ExAmPlE.CoM` | valid | valid | Case | mixed case valid under /i |
| 111 | `A@B.C` | valid | valid | Case | all uppercase minimal valid |
| 112 | `日本語@example.com` (CJK local) | INVALID | valid | Unicode | CJK letters: invalid default, valid with UNICODE flag (\pL in class) |
| 113 | `user日本@example.com` | INVALID | valid | Unicode | mixed ASCII+CJK local; valid only with flag |
| 114 | `café@example.com` (é U+00E9) | INVALID | valid | Unicode | accented latin é: \pL letter; valid with flag only |
| 115 | `test@日本語.com` (CJK domain) | INVALID | INVALID | Unicode | domain stays ASCII [a-z0-9]; CJK domain invalid even with flag |
| 116 | `test@café.com` (é in domain) | INVALID | INVALID | Unicode | domain class has no \pL; accented domain invalid even with flag |
| 117 | `Ω@example.com` (Greek capital Omega) | INVALID | valid | Unicode | Greek letter \pL valid with flag only |
| 118 | `Ⅷ@example.com` (Roman numeral U+2167) | INVALID | valid | Unicode | roman numeral has \pN (number) property; valid with flag |
| 119 | `①@example.com` (circled digit one U+2460) | INVALID | valid | Unicode | circled digit is \pN; valid with flag |
| 120 | `𝕏@example.com` (math double-struck X U+1D54F) | INVALID | valid | Unicode | math alphanumeric is \pL letter; valid with flag |
| 121 | `😀@example.com` (emoji U+1F600) | INVALID | INVALID | Unicode | emoji is symbol (So), not \pL/\pN; invalid even with flag |
| 122 | `❤@example.com` (heart U+2764) | INVALID | INVALID | Unicode | symbol not letter/number; invalid even with flag |
| 123 | `é@example.com` (e + combining acute U+0301) | INVALID | INVALID | Unicode | combining mark \pM is not \pL/\pN; invalid even with flag |
| 124 | `Ｆｕｌｌ@example.com` (fullwidth letters) | INVALID | valid | Unicode | fullwidth latin are \pL; valid with flag |
| 125 | `١٢٣@example.com` (Arabic-Indic digits) | INVALID | valid | Unicode | Arabic-Indic digits \pN; valid with flag |
| 126 | `naïve@example.com` (ï) | INVALID | valid | Unicode | accented latin valid with flag, invalid default |
| 127 | `"日本"@example.com` (CJK in quotes) | INVALID | valid | Unicode | quoted unicode: \pL added to quoted class too in regexp0 - valid with flag |
| 128 | `test@example.com<LF>` (trailing 0x0A) | INVALID | INVALID | Trailing/embedded | trailing newline; D flag (DOLLAR_ENDONLY) means $ no longer matches before final \n - invalid |
| 129 | `test@example.com<CRLF>` | INVALID | INVALID | Trailing/embedded | trailing CRLF; not allowed - invalid |
| 130 | `test@example.com<NUL>` (trailing 0x00) | INVALID | INVALID | Trailing/embedded | trailing NUL after domain - invalid |
| 131 | `<NUL>test@example.com` (leading NUL) | INVALID | INVALID | Trailing/embedded | leading NUL byte breaks anchored match - invalid |
| 132 | `test@exam<NUL>ple.com` (embedded NUL) | INVALID | INVALID | Trailing/embedded | embedded NUL in domain - invalid |
| 133 | `<LF>test@example.com` (leading newline) | INVALID | INVALID | Trailing/embedded | leading newline - invalid |
| 134 | `test@example.com<space>` (trailing space) | INVALID | INVALID | Trailing/embedded | trailing space - invalid |
| 135 | `<space>test@example.com` (leading space) | INVALID | INVALID | Trailing/embedded | leading space - invalid |
| 136 | `test@example.com<TAB>` (trailing 0x09) | INVALID | INVALID | Trailing/embedded | trailing tab - invalid |

## Notes for turning this into ExUnit tests

- **Encode tricky inputs as bytes, not source literals.** Rows with `<NUL>`, `<TAB>`, `<LF>`, `(literal space)`, `(literal backslash)` must be built from explicit byte values (e.g. Elixir `<<0>>`, `"\t"`, `"\\"`) — never typed inline where an editor might normalize them. The machine-readable corpus with exact bytes is at `/tmp/inputs.b64` (base64, one case per line, same order as `#`), labels/verdicts at `/tmp/merged.json`, and a flat verdict file at `/tmp/verdicts.tsv`.
- **Two-column expectation per case:** assert both the default verdict and the `FILTER_FLAG_EMAIL_UNICODE` verdict. The only rows where they differ are the Unicode letter/number local-part cases (112, 113, 114, 117, 118, 119, 120, 124, 125, 126, 127).
- **If reimplementing in Elixir `:re`:** compile `regexp1` with `[:caseless, :dollar_endonly]` and `regexp0` with `[:caseless, :dollar_endonly, :unicode, :ucp]`, match on raw bytes — proven here to reproduce PHP exactly (0 mismatches over 135 cases) — **and additionally enforce the `byte_size > 320` reject in code**, since that gate lives in PHP's C, not the regex. Note that for valid-structured input the 254-byte regex lookahead already binds first, so the 320 guard only differs for pathological inputs.
- **Display caveat:** row 81's local part contains a literal `|` which is pipe-escaped in the table; the actual input is `!#$%&'*+-/=?^_` followed by `` ` ``, `{`, `|`, `}`, `~`, then `@x.com`.

Relevant absolute file paths produced/used:
- `/tmp/verdict.php` (harness), `/tmp/inputs.b64` (inputs), `/tmp/verdicts.tsv` (PHP verdicts), `/tmp/merged.json` (full labeled corpus), `/tmp/table.md` (raw generated table), `/tmp/recheck.escript` (Erlang cross-check), `/tmp/pat1.txt` & `/tmp/pat0.txt` (exact PHP inner patterns), `/tmp/lf_85.c` (PHP-8.5 source, regex at lines 704–705, length guard at 717–720).
