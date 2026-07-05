defmodule Dllb.MixProject do
  use Mix.Project

  @version "0.8.0"
  @source_url "https://github.com/Oeditus/dllb_ex"

  def project do
    [
      app: :dllb,
      version: @version,
      elixir: "~> 1.18",
      name: "Dllb",
      description: "Elixir client for the dllb multi-model NoSQL database",
      source_url: @source_url,
      homepage_url: @source_url,
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: docs(),
      package: package(),
      licenses: ["MIT"],
      test_coverage: [tool: ExCoveralls],
      dialyzer: [
        plt_file: {:no_warn, ".dialyzer/dialyzer.plt"},
        plt_add_apps: [:mix],
        plt_add_deps: :app_tree,
        plt_core_path: ".dialyzer",
        list_unused_filters: true
      ]
    ]
  end

  def cli do
    [
      preferred_envs: [
        docs: :docs,
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test,
        "coveralls.json": :test
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Dllb.Application, []}
    ]
  end

  defp deps do
    [
      {:nimble_pool, "~> 1.1"},
      {:metastatic, "~> 0.22", optional: true},

      # Dev / Test
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:excoveralls, "~> 0.18", only: :test, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp docs do
    [
      main: "readme",
      logo: "logo-48x48.png",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: ["README.md", "CHANGELOG.md"],
      groups_for_modules: [
        "Query & Results": [Dllb.Query, Dllb.Result],
        Connection: [Dllb.Connection, Dllb.Pool, Dllb.Protocol],
        Schema: [Dllb.Schema, Dllb.MetaAST]
      ]
    ]
  end

  defp package do
    [
      name: "dllb",
      licenses: ["MIT"],
      maintainers: ["Aleksei Matiushkin"],
      files: ~w(lib mix.exs README.md CHANGELOG.md LICENSE logo-48x48.png logo-128x128.png),
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"
      }
    ]
  end
end
