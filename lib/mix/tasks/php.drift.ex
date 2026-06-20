defmodule Mix.Tasks.Php.Drift do
  @shortdoc "Detect whether upstream PHP changed the FILTER_VALIDATE_EMAIL regex"

  @moduledoc """
  Fetches `ext/filter/logical_filters.c` from php-src for one or more refs,
  re-extracts the two regex literals, and compares their SHA-256 against the
  copies vendored in `priv/php/`. The comparison uses the **full** literal
  (`/pattern/flags`), so a change to either the pattern *or* the inline flags
  (`/iD` ↔ `/iDu`, etc.) is caught — both affect `filter_var` behaviour.

  This is the early-warning system for "did `filter_var` change?". Run it on a
  schedule in CI (see `.github/workflows/drift.yml`); if PHP ever edits the
  regex in a supported release branch, this task exits non-zero so maintainers
  know immediately and can re-vet + `mix php.extract`.

      mix php.drift                       # checks the supported release branches
      mix php.drift PHP-8.5 master        # check specific refs
      mix php.drift php-8.4.4             # check a specific release tag

  Like `mix php.extract` and `mix php.golden`, this is a maintainer task: run it
  from a checkout of this repository (it reads the vendored `priv/php/*.full`
  files relative to the working directory, and needs network access to reach
  php-src). The scheduled `drift.yml` CI job runs it for you weekly.
  """
  use Mix.Task

  alias Mix.Tasks.Php.Extract

  @default_refs ~w(PHP-8.1 PHP-8.2 PHP-8.3 PHP-8.4 PHP-8.5)

  @impl Mix.Task
  def run(args) do
    refs = if args == [], do: @default_refs, else: args

    vendored = %{
      "regexp1" => Extract.sha(read_priv!("regexp1.full")),
      "regexp0" => Extract.sha(read_priv!("regexp0.full"))
    }

    Mix.shell().info(
      "Vendored regexp1=#{short(vendored["regexp1"])} regexp0=#{short(vendored["regexp0"])}"
    )

    Mix.shell().info(String.duplicate("-", 64))

    results = Enum.map(refs, &check_ref(&1, vendored))

    Mix.shell().info(String.duplicate("-", 64))

    case Enum.reject(results, & &1.match?) do
      [] ->
        Mix.shell().info("OK: all #{length(refs)} ref(s) match the vendored regex.")

      drifted ->
        names = Enum.map_join(drifted, ", ", & &1.ref)

        Mix.raise("""
        DRIFT DETECTED in: #{names}

        PHP changed php_filter_validate_email upstream. The vendored regex no
        longer matches these ref(s). Next steps:
          1. Review the upstream diff for ext/filter/logical_filters.c.
          2. Decide whether to track the new behaviour.
          3. `mix php.extract <ref>` to re-vendor, then `mix php.test` to confirm.
        """)
    end
  end

  defp check_ref(ref, vendored) do
    fulls = ref |> Extract.raw_url() |> Extract.fetch!() |> Extract.extract_fulls()

    # Hash the whole `/pattern/flags` literal so a flag-only change is caught.
    upstream = Map.new(fulls, fn {name, full} -> {name, Extract.sha(full)} end)

    match? = upstream == vendored
    status = if match?, do: "MATCH", else: "DRIFT"

    Mix.shell().info(
      "#{String.pad_trailing(ref, 12)} #{status}  regexp1=#{short(upstream["regexp1"])} regexp0=#{short(upstream["regexp0"])}"
    )

    %{ref: ref, match?: match?, upstream: upstream}
  end

  defp read_priv!(name) do
    Path.expand(Path.join("priv/php", name), File.cwd!()) |> File.read!()
  end

  defp short(<<h::binary-size(12), _::binary>>), do: h
  defp short(other), do: other
end
