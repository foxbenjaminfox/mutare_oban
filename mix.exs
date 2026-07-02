defmodule Mutare.Oban.MixProject do
  use Mix.Project

  def project do
    [
      app: :mutare_oban,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      description: "Mutation-testing mutators for Oban — a Mutare plugin.",
      deps: deps(),
      aliases: aliases()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:mutare, path: "../mutare"},
      # Oban is *not* a runtime dependency of the plugin: the mutators only ever name
      # `Oban.Worker` as a compile-time atom (a behaviour key), never call into Oban. It is
      # needed in `:test` only so the fixtures can `use Oban.Worker` and Mutare's `use`-expansion
      # can surface `@behaviour Oban.Worker`. At a real target site, the user's own project
      # supplies Oban on the code path.
      {:oban, "~> 2.17", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [check: ["format --check-formatted", "credo"]]
  end
end
