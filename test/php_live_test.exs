defmodule ElixirPhpEmailValidator.PhpLiveTest do
  @moduledoc """
  Live differential tests against a real `php` binary, plus a differential
  fuzzer. Tagged `:php` and excluded from `mix test` by default; run with
  `mix test --include php` (CI runs this across a PHP version matrix).

  Two guarantees:

    * **Live parity** — re-runs the whole corpus through the local PHP and
      asserts the Elixir port agrees, so a new/locally-installed PHP version is
      checked directly (not just via the committed golden).
    * **Fuzz parity** — generates thousands of structured + random byte strings,
      asks PHP for the truth in one batch, and asserts agreement. This hunts for
      divergences no hand-written corpus would think of.
  """
  use ExUnit.Case, async: false

  alias Mix.Tasks.Php.Golden

  @moduletag :php

  # NB: use :php_bin, not :php — `@moduletag :php` already puts `php: true` in
  # the test context, so a `:php` key here would be clobbered by the tag.
  setup_all do
    php = System.find_executable("php")
    version = php && Golden.php_version(php)
    {:ok, php_bin: php, version: version}
  end

  setup %{php_bin: php} do
    if is_nil(php) do
      raise "`php` not found on PATH — install PHP to run the :php-tagged live tests"
    end

    :ok
  end

  test "live parity with the local PHP over the full corpus", %{php_bin: php, version: version} do
    inputs = Golden.corpus_inputs()
    rows = php |> Golden.php_raw_tsv(inputs) |> Golden.parse_golden_tsv()

    assert mismatches(rows) == [],
           "corpus disagreements vs live php #{version}:\n" <> format(mismatches(rows))
  end

  test "differential fuzz: structured + random byte strings", %{php_bin: php, version: version} do
    inputs = gen_structured(4000, 20_260_620) ++ gen_random_bytes(1500, 7_654_321)
    rows = php |> Golden.php_raw_tsv(inputs) |> Golden.parse_golden_tsv()

    bad = mismatches(rows)

    assert bad == [],
           "#{length(bad)} fuzz disagreement(s) vs live php #{version} " <>
             "(out of #{length(inputs)} inputs):\n" <> format(Enum.take(bad, 40))
  end

  # --- comparison ----------------------------------------------------------

  defp mismatches(rows) do
    for {input, php_default, php_unicode} <- rows,
        {mode, php_v, ex_v} <- [
          {:default, php_default, ElixirPhpEmailValidator.valid?(input)},
          {:unicode, php_unicode, ElixirPhpEmailValidator.valid?(input, unicode: true)}
        ],
        php_v != ex_v do
      {mode, input, php_v, ex_v}
    end
  end

  defp format(mismatches) do
    Enum.map_join(mismatches, "\n", fn {mode, input, php_v, ex_v} ->
      "  [#{mode}] #{inspect(input)}: php=#{php_v} elixir=#{ex_v}"
    end)
  end

  # --- generators (deterministic) ------------------------------------------

  # Email-shaped fragments: assembling these produces a high density of
  # near-miss addresses that stress the validator's structure.
  @fragments [
    "a",
    "ab",
    "Z",
    "1",
    "0",
    "-",
    "_",
    ".",
    "..",
    "@",
    "[",
    "]",
    ":",
    "::",
    "\"",
    "\\",
    "\\ ",
    " ",
    "+",
    "=",
    "!",
    "#",
    "%",
    "&",
    "'",
    "*",
    "/",
    "?",
    "^",
    "`",
    "{",
    "|",
    "}",
    "~",
    "xn--",
    "com",
    "org",
    "c1",
    "1c",
    "123",
    "127.0.0.1",
    "255.255.255.255",
    "256.1.1.1",
    "01.2.3.4",
    "IPv6:",
    "fe80",
    "2001:db8",
    "ffff",
    ".com",
    ".c",
    "münchen",
    "日本",
    "é",
    "Ⅳ",
    "𝕏",
    "😀",
    "١٢٣",
    <<0xFF>>,
    <<0xC3, 0x28>>,
    <<0>>,
    "\n",
    "\t"
  ]

  defp gen_structured(n, seed) do
    state = :rand.seed_s(:exsss, {seed, seed * 2 + 1, seed * 3 + 7})

    {inputs, _} =
      Enum.map_reduce(1..n, state, fn _, s ->
        {parts, s} =
          Enum.map_reduce(1..8, s, fn _, s ->
            {r, s} = :rand.uniform_s(length(@fragments), s)
            {Enum.at(@fragments, r - 1), s}
          end)

        {keep, s} = :rand.uniform_s(8, s)
        {IO.iodata_to_binary(Enum.take(parts, keep)), s}
      end)

    inputs
  end

  defp gen_random_bytes(n, seed) do
    state = :rand.seed_s(:exsss, {seed, seed * 5 + 3, seed * 11 + 13})

    {inputs, _} =
      Enum.map_reduce(1..n, state, fn _, s ->
        {len, s} = :rand.uniform_s(30, s)

        {bytes, s} =
          Enum.map_reduce(1..len, s, fn _, s ->
            {b, s} = :rand.uniform_s(256, s)
            {b - 1, s}
          end)

        {:erlang.list_to_binary(bytes), s}
      end)

    inputs
  end
end
