defmodule Pyre.MixProject do
  use Mix.Project

  @version "0.3.0"
  @source_url "https://github.com/chrislaskey/pyre_core"

  def project do
    [
      app: :pyre,
      version: @version,
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      source_url: @source_url
    ]
  end

  def application do
    [
      mod: {Pyre.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp description do
    "Core module for Pyre, a software development framework (github.com/chrislaskey/pyre)"
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib priv/pyre/personas .formatter.exs mix.exs README.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md"],
      source_ref: "v#{@version}"
    ]
  end

  defp deps do
    [
      {:inflex, "~> 2.1"},
      {:igniter, "~> 0.7"},
      {:jido, "~> 2.2"},
      {:jido_ai, "~> 2.1"},
      {:req, "~> 0.5", optional: true}
    ]
  end
end
