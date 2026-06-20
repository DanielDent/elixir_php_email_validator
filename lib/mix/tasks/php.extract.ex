defmodule Mix.Tasks.Php.Extract do
  @shortdoc "Re-vendor the PHP FILTER_VALIDATE_EMAIL regex from php-src"

  @moduledoc """
  Downloads `ext/filter/logical_filters.c` from php-src for a given ref and
  re-vendors the two regex strings into `priv/php/`, refreshing
  `priv/php/MANIFEST.json` with new checksums.

      mix php.extract            # defaults to the PHP-8.5 branch
      mix php.extract PHP-8.4    # a specific branch
      mix php.extract php-8.4.4  # a specific release tag

  The vendored `regexp{0,1}.full` literals are the single source of truth the
  library compiles (it derives both the pattern and the `:re` options from
  them). This task makes updating them auditable: it re-extracts from the
  canonical upstream and shows you exactly what changed (diff the resulting
  `priv/php` files in git).
  """
  use Mix.Task

  alias ElixirPhpEmailValidator.PhpSource

  @default_ref "PHP-8.5"
  @priv "priv/php"

  @impl Mix.Task
  def run(args) do
    ref = List.first(args) || @default_ref
    url = raw_url(ref)
    Mix.shell().info("Fetching #{url}")
    source = fetch!(url)

    fulls = extract_fulls(source)
    # Validate every inline flag translates to a vetted :re option (raises on an
    # unvetted flag), then derive the inner patterns — both via the same
    # PhpSource the library compiles from, so all three stay in lockstep.
    Enum.each(fulls, fn {_name, full} -> PhpSource.options(full) end)
    inners = Map.new(fulls, fn {name, full} -> {name, PhpSource.pattern(full)} end)

    write!("logical_filters.c", source)
    write!("regexp1.full", fulls["regexp1"])
    write!("regexp0.full", fulls["regexp0"])
    write!("regexp1.pattern", inners["regexp1"])
    write!("regexp0.pattern", inners["regexp0"])
    write!("MANIFEST.json", render_manifest(ref, url, inners, fulls))

    Mix.shell().info("""
    Re-vendored from #{ref}:
      regexp1.pattern sha256 = #{sha(inners["regexp1"])}
      regexp0.pattern sha256 = #{sha(inners["regexp0"])}
    Review `git diff priv/php`, then run `mix php.test` to confirm parity.
    """)
  end

  # --- Parsing (shared with php.drift) -------------------------------------

  @doc """
  Extracts the two `const char regexpN[] = "...";` literals from the C source,
  un-escaping C backslashes, returning a map `%{"regexp0" => full, "regexp1" => full}`
  where each `full` is the regex exactly as PHP uses it, including the
  `/.../iD` delimiter and flags.
  """
  def extract_fulls(source) do
    %{
      "regexp1" => extract_one(source, "regexp1"),
      "regexp0" => extract_one(source, "regexp0")
    }
  end

  defp extract_one(source, name) do
    # Match a single-line C string literal:  const char NAME[] = "....";
    # The C string body is (?:[^"\\]|\\.)* — any char except quote/backslash,
    # or a backslash followed by any char (so escaped quotes don't end it).
    pattern = "const char " <> name <> "\\[\\]\\s*=\\s*\"((?:[^\"\\\\]|\\\\.)*)\"\\s*;"
    re = Regex.compile!(pattern, "s")

    case Regex.run(re, source) do
      [_, raw] ->
        assert_only_backslash_doubling!(raw, name)
        unescape_c(raw)

      _ ->
        Mix.raise("could not find the regexp literal '#{name}' in the PHP source")
    end
  end

  # The PHP literals only use backslash-doubling as C escaping (every regex
  # metacharacter is written \\x.., \\pL, \\\\, etc.), so un-escaping is a
  # single collapse of "\\\\" -> "\\".
  defp unescape_c(raw), do: String.replace(raw, "\\\\", "\\")

  # Guard the single-rule unescape above: in the vendored literals every
  # backslash is C-escaped as a doubled "\\\\", so after removing those pairs no
  # lone backslash must remain. A lone backslash means upstream introduced a
  # different C escape (\", \n, \t, …) that unescape_c/1 would silently mishandle
  # — fail loudly so the re-vendor is reviewed by a human (matching the fail-loud
  # philosophy of PhpSource.flags_to_re_opts/1) instead of emitting wrong bytes.
  defp assert_only_backslash_doubling!(raw, name) do
    if raw |> String.replace("\\\\", "") |> String.contains?("\\") do
      Mix.raise(
        "the C string literal '#{name}' contains a backslash escape other than `\\\\`; " <>
          "review the upstream change and extend unescape_c/1 before re-vendoring"
      )
    end
  end

  @doc "Lowercase hex SHA-256 of a binary."
  def sha(bin), do: :crypto.hash(:sha256, bin) |> Base.encode16(case: :lower)

  @doc "raw.githubusercontent.com URL for logical_filters.c at a given ref."
  def raw_url(ref),
    do: "https://raw.githubusercontent.com/php/php-src/#{ref}/ext/filter/logical_filters.c"

  @doc """
  Downloads a URL via `curl` (or `wget`), returning the body binary. Shelling
  out keeps this dependency-free and dodges OTP `:inets`/`:ssl` version quirks;
  every dev/CI environment that has `php` also has `curl`.
  """
  def fetch!(url) do
    cond do
      curl = System.find_executable("curl") ->
        run_fetch!(curl, ["-fsSL", url], url)

      wget = System.find_executable("wget") ->
        run_fetch!(wget, ["-qO-", url], url)

      true ->
        Mix.raise("need `curl` or `wget` on PATH to fetch #{url}")
    end
  end

  defp run_fetch!(bin, args, url) do
    # Merge stderr so the actionable diagnostic (curl's "(56) … 404", "Could not
    # resolve host", …) lands in the raise message. On success the body is the
    # only output: `curl -fsSL` / `wget -qO-` are silent on exit 0, so nothing
    # pollutes the returned source.
    case System.cmd(bin, args, stderr_to_stdout: true) do
      {body, 0} -> body
      {out, code} -> Mix.raise("fetch of #{url} failed (exit #{code}): #{out}")
    end
  end

  # --- Writing -------------------------------------------------------------

  defp write!(name, content) do
    path = Path.expand(Path.join(@priv, name), File.cwd!())
    File.write!(path, content)
  end

  # Render a derived :re option list as a JSON string array body, e.g.
  # [:caseless, :dollar_endonly] -> ~s("caseless", "dollar_endonly").
  defp render_opts(opts), do: Enum.map_join(opts, ", ", &~s("#{&1}"))

  defp render_manifest(ref, url, inners, fulls) do
    blob = "https://github.com/php/php-src/blob/#{ref}/ext/filter/logical_filters.c"

    # Derive the re_options from the vendored flags (same path the library
    # compiles from), so this provenance can never drift from the actual options.
    default_opts = render_opts(PhpSource.options(fulls["regexp1"]))
    unicode_opts = render_opts(PhpSource.options(fulls["regexp0"]))

    """
    {
      "_comment": "Provenance for the vendored PHP FILTER_VALIDATE_EMAIL regexes. Regenerate with `mix php.extract`. The library does not parse this file at runtime; ElixirPhpEmailValidator.source_info/0 derives its checksums from the actual vendored bytes. This file is the canonical record for humans and CI/jq tooling.",
      "upstream": {
        "repo": "https://github.com/php/php-src",
        "file": "ext/filter/logical_filters.c",
        "function": "php_filter_validate_email",
        "ref": "#{ref}",
        "blob_url": "#{blob}",
        "raw_url": "#{url}"
      },
      "vendored_at": "#{Date.utc_today()}",
      "max_length_octets": 320,
      "match_flags": {
        "default": "/iD  (i = caseless, D = PCRE_DOLLAR_ENDONLY)",
        "unicode": "/iDu (adds u = PCRE_UTF8 + PCRE_UCP, used with FILTER_FLAG_EMAIL_UNICODE)"
      },
      "re_options": {
        "default": [#{default_opts}],
        "unicode": [#{unicode_opts}]
      },
      "files": {
        "regexp1.pattern": { "role": "default (ASCII) inner pattern", "sha256": "#{sha(inners["regexp1"])}" },
        "regexp0.pattern": { "role": "FILTER_FLAG_EMAIL_UNICODE inner pattern", "sha256": "#{sha(inners["regexp0"])}" },
        "regexp1.full": { "role": "default regex with /.../iD", "sha256": "#{sha(fulls["regexp1"])}" },
        "regexp0.full": { "role": "unicode regex with /.../iDu", "sha256": "#{sha(fulls["regexp0"])}" }
      }
    }
    """
  end
end
