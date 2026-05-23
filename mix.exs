defmodule Dllb.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :dllb,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Elixir client for the dllb multi-model NoSQL database",
      package: package()
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
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      maintainers: ["Aleksei Matiushkin"],
      links: %{}
    ]
  end
end
