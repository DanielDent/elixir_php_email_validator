## As of today, NO existing Elixir/Hex package provides bug-for-bug compatibility with PHP filter_var($email, FILTER_VALIDATE_EMAIL). A new package is genuinely needed.

- **Verdict:** confirmed (confidence: high)

**Evidence:** I attempted to REFUTE the claim by finding a Hex package whose email validation produces identical true/false verdicts to PHP filter_var. I inspected the ACTUAL source of every credible candidate and ran each against the 31-case corpus, diffing vs real PHP 8.5.5 verdicts.

BASELINE RE-VERIFIED: Re-ran `php -r 'filter_var(...,FILTER_VALIDATE_EMAIL)'` over /tmp/corpus.txt -> byte-identical to stored /tmp/php_out.txt ("PHP BASELINE MATCHES"). Independently re-confirmed the established :re parity: OTP 28 :re with PHP's exact pat1.txt + [caseless,dollar_endonly] = 0/31 disagreements; pat0.txt + [caseless,dollar_endonly,unicode,ucp] reproduced FILTER_FLAG_EMAIL_UNICODE on all 10 unicode cases (verdicts 1,0,1,0,1,0,1,1,0,0 matched real PHP exactly, incl. the quirk: unicode local-part accepted but unicode DOMAIN rejected).

CANDIDATES INSPECTED (actual source cloned, not memory):
1) ecto_commons (achedeuzot/ecto_commons) lib/validators/email.ex:
   - :html_input (DEFAULT) regex @email_regex = WHATWG HTML regex `^[a-zA-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\.[...])*$`. Ported to :re -> 13/31 disagreements.
   - :pow logic (RFC3696-ish, unicode-permitting, no IP literals). Faithfully ported -> 11/31 disagreements.
2) email_checker (maennchen/email_checker) priv/email_regex (RFC5322-style, caseless). Ported -> 6/31 disagreements.
3) burnex = disposable-domain blocklist, not a format validator (not applicable). k-and-r/email_validator turned out to be the Ruby gem (has .gemspec), and the Elixir email_validator is self-described as deliberately "loose".

CONCRETE DISAGREEMENTS (PHP vs candidate):
- a@[127.0.0.1]: PHP=valid; ecto html=INVALID, ecto pow=INVALID (neither supports IP literals).
- a@[IPv6:fe80::1]: PHP=valid; ecto BOTH=INVALID, email_checker=INVALID (buggy IPv6 branch).
- a@123.45.67.89: PHP=INVALID (all-numeric TLD); ecto html=valid, email_checker=valid.
- "quoted"@example.com: PHP=valid; ecto html=INVALID (no quoted-string support).
- .foo@bar.com / foo.@bar.com / user@localhost: PHP=INVALID; ecto html & pow=valid.
- 日本語@example.com: PHP default=INVALID; ecto pow=valid.
- Length: ecto html_input accepts 318/319/320/321/400-byte inputs PHP rejects (no length gate); re-port matched real PHP (all 0) at every length.

hex.pm/GitHub sweep (WebSearch + WebFetch of hex.pm/packages?search=email): packages found = email_checker, email_address, ex_email, email_validator, ecto_email, ecto_commons, validation, validate. NONE mentions PHP / filter_var / FILTER_VALIDATE_EMAIL compatibility; no "bug-for-bug" port exists. Every credible validator disagrees with PHP on multiple concrete inputs.

**Corrections:** Minor: the search briefly conflated the Elixir Hex `email_validator` with the unrelated Ruby gem k-and-r/email_validator (a .gemspec repo), so I could not pull the Elixir email_validator regex literal directly — but its own docs describe it as intentionally "loose" (e.g. accepting user@gmail), so it cannot achieve PHP parity. I could not isolate a single structurally-valid email that flips solely at the 320-byte boundary (PHP's other regex constraints fired first), but the length-gate divergence was still demonstrated (ecto html_input has no length cap and accepts >320-byte inputs PHP rejects). burnex and email_checker also do MX/SMTP network checks beyond filter_var's pure-format scope, further confirming non-equivalence. Relevant local artifacts: /tmp/probe.escript, /tmp/probe2.escript, /tmp/probe3.escript, /tmp/probe_uni.escript, /tmp/ec_probe/ecto_commons/lib/validators/email.ex, /tmp/ec_probe/email_checker/priv/email_regex.

---

## PHP's php_filter_validate_email regex (both regexp0 and regexp1) plus the >320 length check is byte-for-byte IDENTICAL across all currently-supported PHP releases (8.1, 8.2, 8.3, 8.4, 8.5), so an Elixir port pinned to this regex is valid for all of them simultaneously.

- **Verdict:** confirmed (confidence: high)

**Evidence:** Fetched ext/filter/logical_filters.c via curl from raw.githubusercontent.com for 17 refs: branches PHP-8.1/8.2/8.3/8.4/8.5/master AND release tags php-7.4.0, php-8.0.0, php-8.1.0, php-8.1.31, php-8.2.0, php-8.2.28, php-8.3.0, php-8.3.21, php-8.4.0, php-8.4.10, php-8.5.0. Extracted the const char regexp1[] and regexp0[] string literals two independent ways: (a) a Python regex parser, (b) raw `grep ... | shasum -a 256` on the whole source line. Both agree. Across ALL 17 refs there is exactly ONE distinct sha256 for each literal: regexp1 (default /iD) = 90c656bb54a2e93efc8f435ce1d019fd075772b22193f2410b6cedc4e7ca60d5 ; regexp0 (unicode /iDu) = 0a6c8fb197f901630506e7483096ab61a4da0a0e31dca3c7ac9e6ec0e57ba30e (the C-escaped literal content; the raw whole-line variants also single-valued: re1 line=18c6e71dc98bd5db..., re0 line=cc0359f27fa70fd4..., constant line lengths 1178/1211 in every ref). The `if (Z_STRLEN_P(value) > 320)` check with the RFC-2821 320-octet comment is byte-identical (grep) in every 8.x ref AND master. Brace-matched extraction of the whole php_filter_validate_email function body is byte-identical (sha 5c429f5aab6ce997..., 4612 bytes) across 8.1.0/8.1/8.2.28/8.3/8.4.10. Behavior re-proven independently: Erlang/OTP 28 escript compiling /tmp/pat1.txt with [caseless, dollar_endonly] reproduced 31/31 PHP verdicts; live `php -r filter_var(... FILTER_VALIDATE_EMAIL)` on PHP 8.5.5 produced output diff-identical to the recorded corpus.

**Corrections:** The regex/length-check are identical, but the function is NOT 100% byte-identical across versions — there is a behavior-irrelevant difference. In 8.5/master the function signature return type changed from `void` (8.1-8.4) to `zend_result`, and a `return SUCCESS;` line was added at the end (unified diff shows ONLY these two lines differ; function body grew 4611->4635 bytes). This is part of a php-src refactor making filter callbacks return a status; it does not touch the regex, character classes, or the >320 check and does not change any validation verdict. Also note "currently-supported": as of 2026-06-19, PHP 8.1 reached end-of-life on 2025-12-31, so strictly only 8.2-8.5 receive support (8.2 is in security-only). The regex is nonetheless identical in 8.1 too (and even back to 7.4 and 8.0), so an Elixir port pinned to it is valid for every release in the 8.x line regardless. master/future PHP still carries the same regex, so no upcoming change is poised to break the port as of the fetched master.

---

