defmodule Mutare.Oban.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/foxbenjaminfox/mutare_oban"

  def project do
    [
      app: :mutare_oban,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      description: "Mutation-testing mutators for Oban — a Mutare plugin.",
      package: package(),
      lockfile: System.get_env("MIX_LOCKFILE", "mix.lock"),
      deps: deps(),
      aliases: aliases(),
      dialyzer: dialyzer(),
      docs: docs()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  # Hex package metadata. The `mutare` core is still a `path:` dependency, so an actual
  # `mix hex.publish` stays blocked until Mutare itself ships to Hex — this section keeps
  # the manifest (license, links, the files that ship) ready for that day. Only runtime
  # and doc artifacts ship: `lib/`, the README extra ExDoc renders, the license, and
  # `mix.exs` — never the test suite.
  defp package do
    [
      licenses: ["MIT"],
      maintainers: ["Benjamin Fox"],
      links: %{
        "GitHub" => @source_url,
        "Mutare" => "https://hexdocs.pm/mutare",
        "Changelog" => "https://hexdocs.pm/mutare_oban/changelog.html"
      },
      files: ~w(lib mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp deps do
    [
      {:mutare, path: "../mutare"},
      # Oban is *not* a runtime dependency of the plugin: the mutators only ever name
      # `Oban.Worker` as a compile-time atom (a behaviour key), never call into Oban. It is
      # needed in `:test` only because the test sources contain `use Oban.Worker`, which
      # Mutare's `use`-expansion expands in-process to surface `@behaviour Oban.Worker`. At
      # a real target site, the user's own project supplies Oban on the code path.
      # The requirement is env-overridable so CI can pin the declared minimum line
      # (see ci.yml); local runs fall back to the locked (latest) Oban.
      {:oban, System.get_env("OBAN_REQUIREMENT", "~> 2.17"), only: :test},
      # Static-analysis tooling: lints (credo) and type/discrepancy checks (dialyxir).
      # Dev/test only, never shipped.
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: :dev, runtime: false},
      # Doc generation. Dev only, never shipped.
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  # `mix check` is the single quality gate: formatting, lint, and type analysis.
  # Any non-zero step aborts the rest, so a green run means all three passed.
  defp aliases do
    [
      check: [
        "format --check-formatted",
        "credo",
        "dialyzer"
      ]
    ]
  end

  # PLTs land in priv/plts so they can be cached instead of being rebuilt every run.
  defp dialyzer do
    [
      plt_local_path: "priv/plts",
      plt_core_path: "priv/plts",
      flags: [:error_handling, :extra_return, :missing_return]
    ]
  end

  # ExDoc configuration. `mix docs` renders to `doc/` (gitignored). README is the
  # landing page; the module set is small enough to need no grouping.
  defp docs do
    [
      main: "readme",
      source_url: @source_url,
      source_ref: "v#{@version}",
      extras: ["README.md", "CHANGELOG.md", "LICENSE"]
    ]
  end
end
