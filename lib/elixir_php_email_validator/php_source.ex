defmodule ElixirPhpEmailValidator.PhpSource do
  @moduledoc false
  # Pure helpers for the vendored PHP source artifacts in priv/php. Shared by the
  # library (which uses them at compile time) and the `php.extract` / `php.drift`
  # Mix tasks, so there is exactly ONE flag-translation table and no Mix
  # dependency leaks into the runtime module. No process state, no I/O.

  @doc """
  Splits a PHP regex literal `"/PATTERN/FLAGS"` (exactly as it appears in
  `ext/filter/logical_filters.c`) into `{pattern, flags}`, using the first and
  last `/` as the delimiters.
  """
  @spec split(binary()) :: {binary(), binary()}
  def split("/" <> rest) do
    {last_pos, _len} = rest |> :binary.matches("/") |> List.last()

    {binary_part(rest, 0, last_pos),
     binary_part(rest, last_pos + 1, byte_size(rest) - last_pos - 1)}
  end

  @doc "The inner pattern of a PHP regex literal (delimiters + flags stripped)."
  @spec pattern(binary()) :: binary()
  def pattern(full), do: full |> split() |> elem(0)

  @doc "The Erlang `:re` options equivalent to a PHP regex literal's inline flags."
  @spec options(binary()) :: [atom()]
  def options(full), do: full |> split() |> elem(1) |> flags_to_re_opts()

  @doc """
  Translates PHP/PCRE inline regex flags into Erlang `:re` compile options.

  Raises on any flag we have not explicitly vetted, so a future PHP change that
  adds a flag fails loudly (at this library's compile time) instead of silently
  diverging. Known flags that merely change matching are translated faithfully,
  so the library auto-adapts to a vetted flag change on the next re-vendor.
  """
  @spec flags_to_re_opts(binary()) :: [atom()]
  def flags_to_re_opts(flags) do
    flags
    |> String.to_charlist()
    |> Enum.flat_map(fn
      ?i ->
        [:caseless]

      ?D ->
        [:dollar_endonly]

      ?u ->
        [:unicode, :ucp]

      ?s ->
        [:dotall]

      ?m ->
        [:multiline]

      ?x ->
        [:extended]

      other ->
        raise ArgumentError,
              "unhandled PHP regex flag #{<<other>>} — review the port before trusting it"
    end)
  end

  @doc """
  Extracts a string field from `MANIFEST.json` text (a tiny, dependency-free
  reader used at compile time so the manifest stays the single source of truth
  for provenance). Raises if the key is missing.
  """
  @spec manifest_field(binary(), binary()) :: binary()
  def manifest_field(json, key) do
    case Regex.run(~r/"#{Regex.escape(key)}"\s*:\s*"([^"]*)"/, json) do
      [_, value] when is_binary(value) -> value
      _ -> raise ArgumentError, "MANIFEST.json: missing string field #{inspect(key)}"
    end
  end
end
