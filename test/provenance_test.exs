defmodule ElixirPhpEmailValidator.ProvenanceTest do
  @moduledoc """
  Enforces the "auditable provenance" promise in CI.

  `mix php.drift` checks the `priv/php/*.full` literals against live php-src. This
  module guards the *rest* of the chain: that the human/tooling-facing artifacts —
  the `*.pattern` copies, `MANIFEST.json` (checksums, `re_options`, the byte gate),
  and the SHA table in `COMPATIBILITY.md` — still agree with those same `*.full`
  literals the library actually compiles from. So a hand-edit (or a stale
  regeneration) can no longer silently desync the published provenance from the
  compiled bytes. Runs in a plain `mix test`: no PHP, no dependencies.
  """
  use ExUnit.Case, async: true

  alias ElixirPhpEmailValidator.PhpSource

  @priv Path.join([__DIR__, "..", "priv", "php"])
  @manifest File.read!(Path.join(@priv, "MANIFEST.json"))
  @compat File.read!(Path.join([__DIR__, "..", "COMPATIBILITY.md"]))

  describe "the *.pattern copies match the inner pattern of the *.full source of truth" do
    test "regexp1 (default / ASCII)" do
      assert priv_read!("regexp1.pattern") == PhpSource.pattern(priv_read!("regexp1.full"))
    end

    test "regexp0 (unicode)" do
      assert priv_read!("regexp0.pattern") == PhpSource.pattern(priv_read!("regexp0.full"))
    end
  end

  describe "MANIFEST.json checksums match the actual vendored bytes" do
    for name <- ~w(regexp1.pattern regexp0.pattern regexp1.full regexp0.full) do
      test "#{name} sha256" do
        name = unquote(name)

        assert manifest_sha(name) == sha(priv_read!(name)),
               "MANIFEST.json sha256 for #{name} is stale; regenerate with `mix php.extract`"
      end
    end
  end

  describe "MANIFEST.json re_options match the options derived from the vendored flags" do
    test "default" do
      assert manifest_re_options("default") ==
               Enum.map(PhpSource.options(priv_read!("regexp1.full")), &Atom.to_string/1)
    end

    test "unicode" do
      assert manifest_re_options("unicode") ==
               Enum.map(PhpSource.options(priv_read!("regexp0.full")), &Atom.to_string/1)
    end
  end

  test "MANIFEST.json max_length_octets matches the library's compiled byte gate" do
    [_, n] = Regex.run(~r/"max_length_octets":\s*(\d+)/, @manifest)
    assert String.to_integer(n) == 320
    assert ElixirPhpEmailValidator.source_info().max_length == 320
  end

  test "COMPATIBILITY.md's truncated SHAs are genuine prefixes of the vendored patterns" do
    assert String.contains?(@compat, String.slice(sha(priv_read!("regexp1.pattern")), 0, 12))
    assert String.contains?(@compat, String.slice(sha(priv_read!("regexp0.pattern")), 0, 12))
  end

  # --- helpers (regex-based MANIFEST reads: the test env has no JSON dep) ------

  defp priv_read!(name), do: File.read!(Path.join(@priv, name))

  defp sha(bin), do: :crypto.hash(:sha256, bin) |> Base.encode16(case: :lower)

  defp manifest_sha(file) do
    [_, hex] =
      Regex.run(~r/"#{Regex.escape(file)}":\s*\{[^}]*"sha256":\s*"([0-9a-f]{64})"/, @manifest)

    hex
  end

  defp manifest_re_options(key) do
    [_, body] = Regex.run(~r/"re_options":\s*\{[^}]*"#{key}":\s*\[([^\]]*)\]/, @manifest)

    body
    |> String.split(",")
    |> Enum.map(&(&1 |> String.trim() |> String.trim("\"")))
    |> Enum.reject(&(&1 == ""))
  end
end
