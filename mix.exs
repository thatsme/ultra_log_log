defmodule UltraLogLog.MixProject do
  use Mix.Project

  @version "0.1.0-rc.0"
  @source_url "https://github.com/thatsme/ultra_log_log"

  def project do
    [
      app: :ultra_log_log,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      name: "UltraLogLog",
      source_url: @source_url
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      # Runtime
      {:telemetry, "~> 1.2"},

      # Dev / test
      {:stream_data, "~> 1.1", only: [:dev, :test]},
      {:benchee, "~> 1.3", only: [:dev]},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},

      # Optional comparison targets for benchmarks
      {:hypex, "~> 1.1", only: [:dev], optional: true},
      {:hyper, "~> 1.0", only: [:dev], optional: true}
    ]
  end

  defp description do
    """
    UltraLogLog — a space-efficient successor to HyperLogLog for approximate
    distinct counting, with a BEAM-native concurrent insert path and
    cluster-wide merge. Based on Ertl, VLDB 2024.
    """
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @source_url,
        "Paper (VLDB 2024)" => "https://www.vldb.org/pvldb/vol17/p1655-ertl.pdf",
        "Paper (arXiv extended)" => "https://arxiv.org/abs/2308.16862"
      },
      maintainers: ["Alex"],
      files: ~w(lib mix.exs README.md LICENSE CHANGELOG.md)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "CHANGELOG.md"],
      source_ref: "v#{@version}",
      groups_for_modules: [
        Core: [UltraLogLog, UltraLogLog.Encoding, UltraLogLog.Hash],
        Estimators: [
          UltraLogLog.Estimator.FGRA,
          UltraLogLog.Estimator.MLE,
          UltraLogLog.Estimator.Martingale
        ],
        Concurrent: [UltraLogLog.Concurrent, UltraLogLog.Cluster]
      ]
    ]
  end
end
