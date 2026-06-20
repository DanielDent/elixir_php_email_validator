defmodule ElixirPhpEmailValidatorTest do
  use ExUnit.Case, async: true

  doctest ElixirPhpEmailValidator

  import ElixirPhpEmailValidator, only: [valid?: 1, valid?: 2]

  describe "basics" do
    test "minimal valid address; single-char TLD is accepted" do
      assert valid?("a@b.c")
    end

    test "a@b is rejected (domain needs a dot / TLD)" do
      refute valid?("a@b")
    end

    test "single-label domains like localhost are rejected" do
      refute valid?("user@localhost")
    end

    test "case-insensitive" do
      assert valid?("USER@EXAMPLE.COM")
    end

    test "non-binary and empty inputs are invalid" do
      refute valid?("")
      refute valid?(nil)
      refute valid?(:not_a_string)
      refute valid?(123)
    end
  end

  describe "the famous quirks (these are the whole point)" do
    test "bare IPv4 is rejected but a bracketed literal is accepted" do
      refute valid?("user@1.2.3.4")
      assert valid?("user@[1.2.3.4]")
    end

    test "bracketed IPv6 literal" do
      assert valid?("a@[IPv6:::1]")
      assert valid?("a@[IPv6:fe80::1]")
    end

    test "a bare space is illegal even inside a quoted local part..." do
      refute valid?(~s("a b"@c.de))
    end

    test "...but a backslash-escaped space is legal" do
      assert valid?(~S(much."more\ unusual"@example.com))
    end

    test "leading/trailing/double dots in the local part are rejected" do
      refute valid?(".a@b.c")
      refute valid?("a.@b.c")
      refute valid?("a..b@c.de")
    end

    test "consecutive dots / trailing dot in the domain are rejected" do
      refute valid?("a@b..c")
      refute valid?("a@b.com.")
    end

    test "leading/trailing hyphen in a domain label is rejected" do
      refute valid?("a@-b.com")
      refute valid?("a@b-.com")
    end

    test "numeric-only TLD is rejected; a TLD must start with a letter" do
      refute valid?("a@b.123")
      refute valid?("a@b.1c")
      assert valid?("a@b.c1")
    end

    test "IDNA xn-- labels are accepted" do
      assert valid?("a@xn--80ak6aa92e.com")
    end

    test "a trailing newline is rejected (the D / dollar-end-only flag)" do
      refute valid?("a@b.c\n")
    end
  end

  describe "length limits" do
    test "local part may be 64 chars but not 65 (the {65,}@ lookahead)" do
      assert valid?(String.duplicate("a", 64) <> "@b.cd")
      refute valid?(String.duplicate("a", 65) <> "@b.cd")
    end

    test "total length is capped at 254 chars by the {255,} lookahead, not by the 320-octet check" do
      assert valid?(
               "a@" <>
                 String.duplicate("a", 63) <>
                 "." <>
                 String.duplicate("a", 63) <>
                 "." <> String.duplicate("a", 63) <> "." <> String.duplicate("a", 60)
             )

      # ^ 254 chars, valid structure
      refute valid?(
               "a@" <>
                 String.duplicate("a", 63) <>
                 "." <>
                 String.duplicate("a", 63) <>
                 "." <> String.duplicate("a", 63) <> "." <> String.duplicate("a", 61)
             )

      # ^ 255 chars
    end

    test "the 320-octet byte check still matters for multibyte unicode" do
      # 64 math letters (256 bytes) + ASCII domain = 322 bytes but only 130 chars:
      # structurally valid under the unicode flag, rejected solely by the byte check.
      addr = String.duplicate("𝕏", 64) <> "@" <> String.duplicate("a", 63) <> ".a"
      assert byte_size(addr) == 322
      refute valid?(addr, unicode: true)
      assert ElixirPhpEmailValidator.source_info().max_length == 320
    end
  end

  describe "FILTER_FLAG_EMAIL_UNICODE (unicode: true)" do
    test "unicode letters/numbers allowed in the local part only with the flag" do
      refute valid?("日本語@example.com")
      assert valid?("日本語@example.com", unicode: true)
    end

    test "the domain stays ASCII even with the unicode flag" do
      refute valid?("test@日本語.com", unicode: true)
      refute valid?("a@münchen.com", unicode: true)
    end

    test "emoji (a symbol, not a letter/number) is rejected in both modes" do
      refute valid?("😀@example.com")
      refute valid?("😀@example.com", unicode: true)
    end

    test "malformed UTF-8 is rejected (re badarg is treated as no-match)" do
      refute valid?(<<0xC3, 0x28>> <> "@b.c", unicode: true)
      refute valid?(<<0xC3, 0x28>> <> "@b.c")
    end
  end

  describe "source_info/0" do
    test "exposes provenance with 64-hex-char checksums derived from the vendored bytes" do
      info = ElixirPhpEmailValidator.source_info()
      assert info.function == "php_filter_validate_email"
      assert info.max_length == 320
      assert byte_size(info.regexp1_sha256) == 64
      assert byte_size(info.regexp0_sha256) == 64
      assert info.regexp1_sha256 =~ ~r/^[0-9a-f]{64}$/
    end
  end
end
