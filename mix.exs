defmodule UltraLogLog.MixProject do
  use Mix.Project

  @version "0.1.0"
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
      # Available in both :dev and :test so `MIX_ENV=test mix docs`
      # works as the documented build path (test env avoids the
      # OTP 27+ compile failure in the `:hyper` benchmark comparison
      # dependency — same reason `MIX_ENV=test mix dialyzer` is the
      # documented dialyzer command). Tracked for cleanup in v0.2.
      {:ex_doc, "~> 0.34", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},

      # HLL comparison targets for the v0.2 benchmark suite.
      {:hypex, "~> 1.1", only: [:dev]},
      {:hyper, "~> 1.0", only: [:dev]}
    ]
  end

  # Hex.pm truncates descriptions; keep under 300 chars.
  defp description do
    "Space-efficient distinct counting for the BEAM. Implements UltraLogLog " <>
      "(Ertl, VLDB 2024), a 2024 successor to HyperLogLog with 24–28% less " <>
      "memory at the same accuracy. Includes FGRA, MLE, and martingale " <>
      "estimators, CRDT merge, and bit-exact validation against the Hash4j " <>
      "Java reference."
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      maintainers: ["Alessio Battistutta"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md",
        "Paper (VLDB 2024)" => "https://www.vldb.org/pvldb/vol17/p1655-ertl.pdf",
        "Paper (arXiv extended)" => "https://arxiv.org/abs/2308.16862",
        "Hash4j reference (v0.17.0)" => "https://github.com/dynatrace-oss/hash4j/tree/v0.17.0"
      },
      # Ship only the files the package needs at runtime + the docs that
      # users will read on hex.pm. Excludes: test/, bench/, docs/measurements/,
      # paper/, .github/, the publish checklist.
      files: ~w(lib mix.exs README.md LICENSE CHANGELOG.md)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: [
        "README.md",
        "CHANGELOG.md",
        "CONTRIBUTING.md"
      ],
      source_ref: "v#{@version}",
      source_url: @source_url,
      groups_for_modules: [
        Core: [UltraLogLog, UltraLogLog.Encoding, UltraLogLog.Hash],
        Estimators: [
          UltraLogLog.Estimator.FGRA,
          UltraLogLog.Estimator.MLE,
          UltraLogLog.Estimator.Martingale
        ]
      ]
    ]
  end
end
