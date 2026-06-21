defmodule ElixirPhpEmailValidator.MixProject do
  use Mix.Project

  # Managed automatically by release-please (see release-please-config.json).
  # Starts at 0.0.0; the first release PR cuts 0.1.0 from the commit history.
  # x-release-please-start-version
  @version "1.0.6"
  # x-release-please-end
  @source_url "https://github.com/DanielDent/elixir_php_email_validator"
  @author_url "https://danieldent.com"

  def project do
    [
      app: :elixir_php_email_validator,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      # corpus.exs under test/fixtures is data, not a test module. (This key is
      # honoured on Elixir >= 1.19 and harmlessly ignored on older versions,
      # where the default `*_test.exs` pattern already excludes fixtures.)
      test_ignore_filters: [~r{test/fixtures/}],
      deps: deps(),
      aliases: aliases(),
      name: "ElixirPhpEmailValidator",
      description: description(),
      package: package(),
      docs: docs(),
      source_url: @source_url,
      dialyzer: [
        plt_local_path: "priv/plts",
        plt_core_path: "priv/plts",
        # The Mix tasks call Mix.* (Mix isn't in the default PLT).
        plt_add_apps: [:mix],
        # Verify specs are accurate (catches over/under-specified contracts).
        flags: [:error_handling, :extra_return, :missing_return]
      ]
    ]
  end

  # The live/fuzz suite shells out to `php`; excluded unless you opt in (CI and
  # `mix php.test` include it). Plain `mix test` runs everywhere, asserting
  # parity against the committed golden verdict files.
  def cli do
    [preferred_envs: ["php.test": :test]]
  end

  def application do
    # The runtime library has no dependencies: checksums are computed at
    # compile time and the only work at runtime is :re + :persistent_term.
    # The dev Mix tasks start :inets/:ssl on demand themselves.
    [extra_applications: []]
  end

  defp description do
    "A bug-for-bug compatible port of PHP's filter_var($email, FILTER_VALIDATE_EMAIL). " <>
      "Returns the exact same true/false verdict as PHP, verified by differential tests " <>
      "against real PHP across a version matrix."
  end

  defp package do
    [
      # MIT covers the original Elixir code/tests/tooling/docs; PHP-3.01 covers the
      # vendored php-src material that ships in priv/php (logical_filters.c and the
      # regex bytes derived from it). Both SPDX ids render on hex.pm. The Michael
      # Rushton attribution the regex also carries is preserved in NOTICE.
      licenses: ["MIT", "PHP-3.01"],
      # priv/php ships the vendored PHP source: regexp{0,1}.full + MANIFEST.json
      # are read at compile time (required), and the .pattern/.c copies ride along
      # for provenance/audit (see the NOTICE and COMPATIBILITY guide).
      files:
        ~w(lib priv/php .formatter.exs mix.exs README.md COMPATIBILITY.md LICENSE NOTICE CHANGELOG.md),
      links: %{
        "GitHub" => @source_url,
        "Author" => @author_url,
        "Changelog" => @source_url <> "/blob/main/CHANGELOG.md",
        "PHP source (php_filter_validate_email)" =>
          "https://github.com/php/php-src/blob/PHP-8.5/ext/filter/logical_filters.c"
      }
    ]
  end

  defp docs do
    [
      main: "readme",
      authors: ["Daniel Dent (https://danieldent.com)"],
      extras: [
        "README.md",
        "COMPATIBILITY.md": [title: "Compatibility & Correctness"],
        "CHANGELOG.md": [title: "Changelog"],
        NOTICE: [title: "Attribution (NOTICE)"],
        LICENSE: [title: "License"]
      ],
      # @version is 0.0.0 until release-please cuts the first tag; point docs at
      # `main` until then so source links resolve.
      source_ref: if(@version == "0.0.0", do: "main", else: "v#{@version}"),
      source_url: @source_url
    ]
  end

  defp deps do
    # Zero runtime dependencies. Everything here is dev/test tooling.
    [
      # All :dev-only, so the `test` env stays dependency-free (the canary CI job
      # then exercises only the library on the newest Elixir/OTP).
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: :dev, runtime: false}
    ]
  end

  defp aliases do
    [
      # Regenerate the golden verdict file from your local `php`, then run the
      # full suite including the live/fuzz tests that shell out to PHP.
      "php.test": ["php.golden", "test --include php"],
      # The full local quality gate (mirrors the `quality` CI job).
      check: ["format --check-formatted", "credo --strict", "dialyzer", "test"]
    ]
  end
end
