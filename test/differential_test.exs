defmodule ElixirPhpEmailValidator.DifferentialTest do
  @moduledoc """
  The core regression guard. Asserts that ElixirPhpEmailValidator reproduces, for
  every corpus input, the exact verdict recorded from a real `php` binary in the
  committed golden files (test/fixtures/golden/php-*.tsv).

  This runs in a plain `mix test` with NO PHP installed: the golden files are the
  frozen testimony of what PHP actually did. If this module's behaviour ever
  diverges from that testimony, these tests fail. (The live suite in
  php_live_test.exs re-derives the testimony from a fresh PHP to catch upstream
  drift.)
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Php.Golden

  @golden_files Golden.golden_files()

  test "at least one golden file is committed" do
    assert @golden_files != [],
           "No test/fixtures/golden/php-*.tsv found. Generate one with `mix php.golden`."
  end

  for path <- @golden_files do
    version = path |> Path.basename(".tsv") |> String.replace_prefix("php-", "")
    rows = path |> File.read!() |> Golden.parse_golden_tsv()

    @rows rows

    test "default mode matches PHP #{version} (#{length(rows)} cases)" do
      assert_parity(@rows, :default)
    end

    test "unicode mode matches PHP #{version} (#{length(rows)} cases)" do
      assert_parity(@rows, :unicode)
    end
  end

  defp assert_parity(rows, mode) do
    mismatches =
      for {input, default_v, unicode_v} <- rows,
          expected = if(mode == :default, do: default_v, else: unicode_v),
          actual = ElixirPhpEmailValidator.valid?(input, unicode: mode == :unicode),
          actual != expected do
        "  #{inspect(input, binaries: :as_binaries)}: php=#{expected} elixir=#{actual}"
      end

    assert mismatches == [],
           "#{length(mismatches)} #{mode}-mode mismatch(es) vs PHP golden:\n" <>
             Enum.join(mismatches, "\n")
  end
end
