defmodule Stc.MixProject do
  use Mix.Project

  def project do
    [
      app: :stc,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ecto, "~> 3.13"},
      {:highlander, "~> 0.2"},
      {:horde, "~> 0.8"},
      # {:dep_from_hexpm, "~> 0.3.0"},
      # {:dep_from_git, git: "https://github.com/elixir-lang/my_dep.git", tag: "0.1.0"}

      # dev
      {:credo, "~> 1.7.7", only: [:dev, :test, :sandbox], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test, :sandbox], runtime: false}
    ]
  end
end
