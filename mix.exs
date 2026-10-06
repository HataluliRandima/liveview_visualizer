defmodule LiveViewVisualizer.MixProject do
  use Mix.Project

  @version "0.1.0"
  # TODO: replace with the real repository URL before publishing.
  @source_url "https://github.com/hataluli/liveview_visualizer"

  def project do
    [
      app: :liveview_visualizer,
      version: @version,
      elixir: "~> 1.14",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      name: "LiveView Lifecycle Visualizer",
      description: "Development-time observability and visualization for Phoenix LiveView.",
      source_url: @source_url,
      package: package(),
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {LiveViewVisualizer.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:telemetry, "~> 1.0"},
      # Optional: the LiveView instrumentation activates only when the host
      # application depends on Phoenix LiveView itself.
      {:phoenix_live_view, "~> 1.0", optional: true},
      {:lazy_html, ">= 0.1.0", only: :test, runtime: false},
      {:jason, "~> 1.0", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib mix.exs README.md LICENSE .formatter.exs)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: ["README.md"]
    ]
  end
end
