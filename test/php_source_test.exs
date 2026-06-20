defmodule ElixirPhpEmailValidator.PhpSourceTest do
  use ExUnit.Case, async: true

  alias ElixirPhpEmailValidator.PhpSource

  describe "split/1 and pattern/1" do
    test "splits a PHP literal into pattern and flags" do
      assert PhpSource.split("/abc/iD") == {"abc", "iD"}
      assert PhpSource.pattern("/abc/iD") == "abc"
    end

    test "uses the LAST slash as the flag delimiter (pattern may contain slashes)" do
      assert PhpSource.split("/a\\/b/iDu") == {"a\\/b", "iDu"}
    end
  end

  describe "flags_to_re_opts/1" do
    test "translates the flags PHP actually uses" do
      assert PhpSource.flags_to_re_opts("iD") == [:caseless, :dollar_endonly]
      assert PhpSource.flags_to_re_opts("iDu") == [:caseless, :dollar_endonly, :unicode, :ucp]
      assert PhpSource.flags_to_re_opts("") == []
    end

    test "raises loudly on an unvetted flag (the drift guarantee)" do
      assert_raise ArgumentError, ~r/unhandled PHP regex flag/, fn ->
        PhpSource.flags_to_re_opts("iZ")
      end
    end
  end

  describe "options/1 on the VENDORED literals" do
    @priv Path.join([__DIR__, "..", "priv", "php"])

    test "regexp1.full (default) derives the ASCII options" do
      full = File.read!(Path.join(@priv, "regexp1.full"))
      assert PhpSource.options(full) == [:caseless, :dollar_endonly]
    end

    test "regexp0.full (unicode) derives the unicode options" do
      full = File.read!(Path.join(@priv, "regexp0.full"))
      assert PhpSource.options(full) == [:caseless, :dollar_endonly, :unicode, :ucp]
    end
  end

  describe "manifest_field/2" do
    test "reads a string field" do
      json = ~s({"a": "x", "ref": "PHP-8.5", "n": 320})
      assert PhpSource.manifest_field(json, "ref") == "PHP-8.5"
    end

    test "raises when a key is missing" do
      assert_raise ArgumentError, ~r/missing string field/, fn ->
        PhpSource.manifest_field(~s({"a": "x"}), "ref")
      end
    end
  end
end
