# Master differential-test corpus for PHP filter_var(FILTER_VALIDATE_EMAIL).
#
# Each entry is {input_binary, category, note}. This file is evaluated by
# `mix php.golden`, which feeds every input through a real `php` binary to
# produce the committed golden verdict files in test/fixtures/golden/. The
# test suite then asserts ElixirPhpEmailValidator reproduces those verdicts.
#
# To add a case: add a tuple here, run `mix php.golden`, commit the updated
# golden. Inputs may contain any bytes (spaces, backslashes, control chars,
# NUL, invalid UTF-8) — they are carried through the golden file as base64.
#
# The last expression in this file must be the list of entries.

local64 = String.duplicate("a", 64)
local65 = String.duplicate("a", 65)
label63 = String.duplicate("a", 63)
label64 = String.duplicate("a", 64)

# Build a structurally-valid address of exactly `total` characters: local "a",
# then a domain of <=63-char "a" labels (the last label is the TLD). Used to
# probe the *real* length boundary, which is the regex's `(?!...{255,})`
# lookahead at ~254 chars — NOT the 320-octet byte check (that only bites for
# multibyte input; see unicode_over_320 below).
build_addr = fn total ->
  dom_len = total - 2

  labels =
    Stream.unfold(dom_len, fn
      rem when rem <= 0 ->
        nil

      rem ->
        take = min(63, rem)
        consumed = if rem - take > 0, do: take + 1, else: take
        {String.duplicate("a", take), rem - consumed}
    end)
    |> Enum.to_list()

  "a@" <> Enum.join(labels, ".")
end

addr_254 = build_addr.(254)
addr_255 = build_addr.(255)

# 64 mathematical-letter code points (valid \pL in the local part) = 256 bytes,
# plus an ASCII domain pushing the byte length to 322 while staying at 130
# chars. Structurally valid under the unicode flag, but rejected purely by the
# 320-octet pre-check.
unicode_over_320 = String.duplicate("𝕏", 64) <> "@" <> String.duplicate("a", 63) <> ".a"

[
  # ── Basics ──────────────────────────────────────────────────────────────
  {"a@b.c", "basic", "minimal valid; single-char TLD is accepted"},
  {"a@b", "basic", "INVALID: domain needs at least one dot / a TLD label"},
  {"test@example.com", "basic", "ordinary address"},
  {"first.last@iana.org", "basic", "dotted local part"},
  {"USER@EXAMPLE.COM", "basic", "case-insensitive (/i)"},
  {"user@localhost", "basic", "INVALID: single-label domain rejected"},
  {"", "basic", "INVALID: empty string"},
  {"   ", "basic", "INVALID: whitespace only"},
  {"plainaddress", "basic", "INVALID: no @"},
  {"@example.com", "basic", "INVALID: empty local part"},
  {"a@", "basic", "INVALID: empty domain"},
  {"a@@b.c", "basic", "INVALID: double @"},

  # ── Domain labels ───────────────────────────────────────────────────────
  {"a@b..c", "domain", "INVALID: empty label (consecutive dots)"},
  {"a@b.com.", "domain", "INVALID: trailing dot in domain"},
  {"a@.b.com", "domain", "INVALID: leading dot in domain"},
  {"a@-b.com", "domain", "INVALID: label may not start with hyphen"},
  {"a@b-.com", "domain", "INVALID: label may not end with hyphen"},
  {"a@b-c.com", "domain", "valid: internal hyphen ok"},
  {"a@b_c.com", "domain", "INVALID: underscore not allowed in domain"},
  {"a@b.c-d", "domain", "valid: hyphen in final label"},
  {"a@b.123", "domain", "INVALID: numeric-only TLD rejected"},
  {"a@b.c1", "domain", "valid: TLD must start with a letter, may contain digits"},
  {"a@b.1c", "domain", "INVALID: TLD must start with a letter"},
  {"a@b.c.d.e.f.g", "domain", "valid: many labels"},
  {"a@" <> label63 <> ".com", "domain", "valid: 63-char label (max)"},
  {"a@" <> label64 <> ".com", "domain", "INVALID: 64-char label exceeds limit"},
  {"a@xn--80ak6aa92e.com", "domain", "valid: IDNA/punycode xn-- label"},
  {"a@xn--.com", "domain", "INVALID: xn-- with empty remainder"},

  # ── Bare IP vs bracketed IP literal ─────────────────────────────────────
  {"a@1.2.3.4", "ip", "INVALID: bare IPv4 not accepted (needs brackets)"},
  {"a@123.123.123.123", "ip", "INVALID: bare IPv4 rejected even if well-formed"},
  {"a@[1.2.3.4]", "ip", "valid: bracketed IPv4 literal"},
  {"a@[127.0.0.1]", "ip", "valid: bracketed loopback"},
  {"a@[255.255.255.255]", "ip", "valid: max octets"},
  {"a@[256.1.1.1]", "ip", "INVALID: octet out of range"},
  {"a@[999.1.1.1]", "ip", "INVALID: octet out of range"},
  {"a@[01.2.3.4]", "ip", "INVALID: leading-zero octet not matched by the octet alternation"},
  {"a@[1.2.3]", "ip", "INVALID: too few octets"},
  {"a@[1.2.3.4.5]", "ip", "INVALID: too many octets"},
  {"a@1.2.3.4]", "ip", "INVALID: unbalanced bracket"},

  # ── IPv6 literals ───────────────────────────────────────────────────────
  {"a@[IPv6:::1]", "ipv6", "valid: compressed loopback"},
  {"a@[IPv6:fe80::1]", "ipv6", "valid: link-local"},
  {"a@[IPv6:2001:db8::1]", "ipv6", "valid: documentation prefix"},
  {"a@[IPv6:2001:0db8:0000:0000:0000:0000:0000:0001]", "ipv6", "valid: full form"},
  {"a@[IPv6:1:2:3:4:5:6:7:8]", "ipv6", "valid: eight groups"},
  {"a@[IPv6:1:2:3:4:5:6:7:8:9]", "ipv6", "INVALID: nine groups"},
  {"a@[IPv6:::ffff:1.2.3.4]", "ipv6", "valid: IPv4-mapped"},
  {"a@[IPv6:gggg::1]", "ipv6", "INVALID: non-hex group"},
  {"a@[2001:db8::1]", "ipv6", "INVALID: missing IPv6: prefix"},

  # ── Local part ──────────────────────────────────────────────────────────
  {".a@b.c", "local", "INVALID: leading dot in local part"},
  {"a.@b.c", "local", "INVALID: trailing dot in local part"},
  {"a..b@c.de", "local", "INVALID: consecutive dots in local part"},
  {"a+b@c.de", "local", "valid: plus tag"},
  {"a!#$%&'*+-/=?^_`{|}~@c.de", "local", "valid: all permitted atext specials"},
  {"a b@c.de", "local", "INVALID: bare space in unquoted local part"},
  {"\"quoted\"@example.com", "local", "valid: quoted local part"},
  {"\"a b\"@c.de", "local", "INVALID: bare space illegal even inside quotes"},
  {"much.\"more\\ unusual\"@example.com", "local",
   "valid: backslash-escaped space inside quotes"},
  {"\"\\\"\"@c.de", "local", "valid: escaped quote inside quotes"},
  {"\"\"@c.de", "local", "valid: empty quoted string"},
  {"\"a@b\"@c.de", "local", "valid: @ allowed inside quotes"},
  {local64 <> "@b.cd", "local", "valid: 64-char local part (max)"},
  {local65 <> "@b.cd", "local", "INVALID: 65-char local part exceeds limit"},

  # ── Total length boundary ───────────────────────────────────────────────
  {addr_254, "length", "valid: 254 chars (the regex {255,} lookahead caps length here)"},
  {addr_255, "length", "INVALID: 255 chars exceeds the regex's atom-count lookahead"},
  {unicode_over_320, "length",
   "INVALID: 130 chars but 322 bytes; rejected by the 320-octet pre-check"},

  # ── Control bytes / raw bytes ───────────────────────────────────────────
  {"a@b.c\n", "bytes", "INVALID: trailing newline (D flag: $ is end-only)"},
  {"a\nb@c.de", "bytes", "INVALID: embedded newline"},
  {"a" <> <<0>> <> "@b.c", "bytes", "INVALID: embedded NUL"},
  {<<0xFF>> <> "@b.c", "bytes", "INVALID: high byte 0xFF in local part"},
  {"a@b." <> <<0xFF>>, "bytes", "INVALID: high byte in domain"},

  # ── Unicode (differs between default and FILTER_FLAG_EMAIL_UNICODE) ──────
  {"日本語@example.com", "unicode", "default INVALID; unicode-flag VALID (letters in local part)"},
  {"münchen@example.com", "unicode", "default INVALID; unicode-flag VALID (accented latin)"},
  {"١٢٣@example.com", "unicode", "unicode-flag VALID (Arabic-Indic digits \\pN)"},
  {"Ⅳ@example.com", "unicode", "unicode-flag VALID (Roman numeral, \\pN)"},
  {"𝕏@example.com", "unicode", "unicode-flag VALID (mathematical letter, \\pL)"},
  {"😀@example.com", "unicode", "INVALID both: emoji is a symbol, not letter/number"},
  {"test@日本語.com", "unicode", "INVALID both: domain stays ASCII even under unicode flag"},
  {"a@münchen.com", "unicode", "INVALID both: non-ASCII domain rejected"},
  {<<0xC3, 0x28>> <> "@b.c", "unicode",
   "INVALID both: malformed UTF-8 (unicode mode: re badarg -> false)"}
]
