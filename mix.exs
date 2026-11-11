defmodule PhoenixDiscovery.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/sublimecoder/phoenix_discovery"

  def project do
    [
      app: :phoenix_discovery,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "IndexNow, sitemap.xml, llms.txt and JSON-LD helpers for Plug and Phoenix apps.",
      source_url: @source_url,
      package: [
        licenses: ["MIT"],
        links: %{"GitHub" => @source_url}
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:plug, "~> 1.16"},
      {:jason, "~> 1.4"},
      {:req, "~> 0.5"}
    ]
  end
end
