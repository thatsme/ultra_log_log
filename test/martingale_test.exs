defmodule UltraLogLog.Estimator.MartingaleTest do
  @moduledoc """
  Tests for `UltraLogLog.Estimator.Martingale`.

  Three categories:

    * **Spot-check** (default): replay the same deterministic seed
      streams Hash4j used through `UltraLogLog.add/2` and verify the
      final martingale estimate matches Hash4j's `MartingaleEstimator`
      to within 0.5% relative. Since we share Hash4j's
      `getScaledRegisterChangeProbability` integer math and the same
      Algorithm-2 update order, observed divergence is bit-exact
      (rel = 0.0) on every fixture.

    * **Invalidation** (default): build a sketch, take a martingale
      estimate, merge with another sketch, verify the estimate now
      returns `{:error, :invalidated_by_merge}`.

    * **Statistical** (`@moduletag :statistical`, opt-in via
      `mix test --include statistical`): same p × N × T grid as FGRA/MLE.
      Theoretical relative stderr is `√(MVP/(8m))` with `MVP = 5·ln(2)`
      (paper eq. 26 evaluated at `b=2, d=2, q=6`); numerically
      `≈ 0.658/√m`, tighter than MLE's 0.761/√m.

  ## Measurement reporting

  `REPORT=1 mix test --include statistical test/martingale_test.exs`
  emits the same shape of human-readable tables as the FGRA/MLE
  reports. Default runs are silent.
  """

  use ExUnit.Case, async: true

  import Bitwise

  alias UltraLogLog.Estimator.Martingale

  @fixtures_dir Path.join([__DIR__, "fixtures"])
  @hip_fixtures Path.join(@fixtures_dir, "martingale_estimates.json")

  @spot_check_rel_tolerance 5.0e-3

  # Theoretical martingale rse for ULL: √(MVP/(8m)) where
  # MVP = (q+d) · ½ · ln(2) · (1 + 2^(-d)/(2-1)) = 8 · ½ · ln(2) · 5/4
  #     = 5·ln(2) ≈ 3.4657 (paper §3.7 line 845).
  # So rse_factor = √(5·ln(2)/8) ≈ 0.658.
  @theoretical_rse_factor :math.sqrt(5.0 * :math.log(2.0) / 8.0)

  # Insert seed matches GenerateFixtures.java INSERT_SEED so the
  # spot-check seed file lines up with the .bin / *_estimates.json
  # files. The cumulative seed file ull_n100000.seeds is the
  # superset for n ∈ {100, 1k, 10k, 100k}.
  @seeds_path Path.join([__DIR__, "fixtures", "ull_n100000.seeds"])

  setup_all do
    if report?() do
      ensure_agent(:martingale_stat_report)
      on_exit(fn -> print_stat_summary() end)
    end

    :ok
  end

  defp ensure_agent(name) do
    case Agent.start_link(fn -> [] end, name: name) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _}} -> Agent.update(name, fn _ -> [] end)
    end
  end

  # ---------------------------------------------------------------------
  # (A) Spot-check vs Hash4j MartingaleEstimator.

  describe "spot-check against Hash4j MartingaleEstimator v0.17.0" do
    test "every fixture is within 0.5% of Hash4j" do
      assert File.exists?(@hip_fixtures),
             "missing #{@hip_fixtures} — regenerate with test/fixtures/java/generate.sh"

      assert File.exists?(@seeds_path),
             "missing #{@seeds_path} — regenerate via the fixture pipeline"

      %{"vectors" => vectors} = @hip_fixtures |> File.read!() |> JSON.decode!()
      refute vectors == [], "martingale_estimates.json produced no vectors"

      seeds = read_seeds(@seeds_path)
      results = replay_per_precision(vectors, seeds)

      mismatches = Enum.filter(results, &(&1.rel > @spot_check_rel_tolerance))

      assert mismatches == [],
             "Martingale estimate mismatch on #{length(mismatches)} of " <>
               "#{length(results)} fixtures. " <>
               "First 3: " <> inspect(Enum.take(mismatches, 3), pretty: true)

      if report?(), do: print_spot_check_report(results)
    end
  end

  defp read_seeds(path) do
    path
    |> File.stream!()
    |> Enum.map(&(&1 |> String.trim() |> String.to_integer()))
  end

  # Group fixtures by precision so each precision's seed stream is
  # consumed exactly once (the seed file is cumulative across all
  # checkpoint values of n).
  defp replay_per_precision(vectors, seeds) do
    vectors
    |> Enum.group_by(& &1["p"])
    |> Enum.sort_by(fn {p, _} -> p end)
    |> Enum.flat_map(fn {p, p_vectors} ->
      checkpoints_in_order =
        p_vectors
        |> Enum.sort_by(& &1["n"])
        |> Enum.map(&{&1["n"], &1["estimate"]})

      ull0 = UltraLogLog.new(precision: p)

      {rows, _state} =
        Enum.map_reduce(checkpoints_in_order, {ull0, 0}, fn {n, expected}, {ull_acc, inserted} ->
          delta = n - inserted
          slice = Enum.slice(seeds, inserted, delta)
          ull_next = Enum.reduce(slice, ull_acc, &UltraLogLog.add(&2, &1))

          {:ok, got} = UltraLogLog.cardinality(ull_next, estimator: :martingale)
          rel = abs(got - expected) / max(expected, 1.0)
          row = %{p: p, n: n, expected: expected, got: got, rel: rel}
          {row, {ull_next, n}}
        end)

      rows
    end)
  end

  # ---------------------------------------------------------------------
  # (B) Invalidation by merge.

  describe "invalidation by merge" do
    test "martingale returns {:error, :invalidated_by_merge} after merge/2" do
      a =
        UltraLogLog.new(precision: 10)
        |> UltraLogLog.add("a1")
        |> UltraLogLog.add("a2")

      b =
        UltraLogLog.new(precision: 10)
        |> UltraLogLog.add("b1")

      # Pre-merge: martingale should be valid and non-zero.
      assert {:ok, before} = UltraLogLog.cardinality(a, estimator: :martingale)
      assert before > 0.0

      merged = UltraLogLog.merge(a, b)

      assert {:error, :invalidated_by_merge} =
               UltraLogLog.cardinality(merged, estimator: :martingale)

      # And the other estimators must still work on the merged sketch.
      assert {:ok, _} = UltraLogLog.cardinality(merged, estimator: :fgra)
      assert {:ok, _} = UltraLogLog.cardinality(merged, estimator: :mle)
    end

    test "from_binary/1 reload yields an invalidated martingale" do
      a =
        UltraLogLog.new(precision: 8)
        |> UltraLogLog.add("x")
        |> UltraLogLog.add("y")

      {:ok, reloaded} = UltraLogLog.from_binary(UltraLogLog.to_binary(a))

      assert {:error, :invalidated_by_merge} =
               UltraLogLog.cardinality(reloaded, estimator: :martingale)
    end
  end

  # ---------------------------------------------------------------------
  # (C) Statistical correctness.

  describe "statistical correctness across (p, N) grid" do
    @describetag :statistical

    @master_seed_a 0xC0FFEE_FEED_F00D
    @master_seed_b 0xDEAD_BEEF_CAFE
    @master_seed_c 0x1234_5678_9ABC
    @trials 30

    for p <- [10, 12, 14], n <- [100, 1_000, 10_000, 100_000, 1_000_000] do
      @p p
      @n n

      test "p=#{p}, N=#{n}: bias and stddev within theoretical bound" do
        estimates = run_trials(@p, @n, @trials)
        {mean, stddev} = mean_and_stddev(estimates)

        m = 1 <<< @p
        theoretical_rse = @theoretical_rse_factor / :math.sqrt(m)
        bias_bound = 3.0 * theoretical_rse / :math.sqrt(@trials) * @n
        stddev_bound = 1.5 * theoretical_rse * @n

        bias = mean - @n
        bias_pass = abs(bias) <= bias_bound
        stddev_pass = stddev <= stddev_bound

        if report?() do
          row = %{
            p: @p,
            n: @n,
            theoretical_rse: theoretical_rse,
            mean: mean,
            stddev: stddev,
            bias: bias,
            bias_bound: bias_bound,
            stddev_bound: stddev_bound,
            bias_pass: bias_pass,
            stddev_pass: stddev_pass
          }

          print_stat_cell(row)
          Agent.update(:martingale_stat_report, fn rows -> [row | rows] end)
        end

        assert bias_pass,
               "bias |#{bias}| > 3σ bound (#{bias_bound}) " <>
                 "at p=#{@p}, N=#{@n}, mean=#{mean}, theoretical rse=#{theoretical_rse}"

        assert stddev_pass,
               "stddev #{stddev} > 1.5× theoretical (#{stddev_bound}) " <>
                 "at p=#{@p}, N=#{@n}, theoretical rse=#{theoretical_rse}"
      end
    end

    defp run_trials(p, n, trials) do
      for trial_idx <- 1..trials, do: run_one_trial(p, n, trial_idx)
    end

    defp run_one_trial(p, n, trial_idx) do
      seed =
        :rand.seed_s(
          :exsss,
          {@master_seed_a + trial_idx, @master_seed_b + trial_idx, @master_seed_c + trial_idx}
        )

      ull0 = UltraLogLog.new(precision: p)

      {ull, _state} =
        Enum.reduce(1..n, {ull0, seed}, fn _, {ull_acc, st} ->
          {h, st} = :rand.uniform_s(0x1_0000_0000_0000_0000, st)
          {UltraLogLog.add(ull_acc, h - 1), st}
        end)

      {:ok, est} = UltraLogLog.cardinality(ull, estimator: :martingale)
      est
    end

    defp mean_and_stddev(xs) do
      n = length(xs)
      mean = Enum.sum(xs) / n
      variance = Enum.reduce(xs, 0.0, fn x, acc -> acc + (x - mean) * (x - mean) end) / (n - 1)
      {mean, :math.sqrt(variance)}
    end
  end

  # ---------------------------------------------------------------------
  # h(r, p) unit checks — paper eq. (25) special values.

  describe "h/2 (per-register state-change probability)" do
    test "h(0, p) = 1/m for all valid p" do
      for p <- 3..14 do
        assert_in_delta Martingale.h(0, p), 1.0 / (1 <<< p), 1.0e-15, "h(0, p=#{p}) mismatch"
      end
    end

    test "h(4p−4, p) = 1/(2m)  — paper r=4 case" do
      for p <- 3..14 do
        byte = (p <<< 2) - 4
        assert_in_delta Martingale.h(byte, p), 1.0 / (2 * (1 <<< p)), 1.0e-15
      end
    end

    test "h(4p, p) = 3/(4m)  — paper r=8 case" do
      for p <- 3..14 do
        byte = p <<< 2
        assert_in_delta Martingale.h(byte, p), 3.0 / (4 * (1 <<< p)), 1.0e-15
      end
    end

    test "h(4p+2, p) = 1/(4m)  — paper r=10 case" do
      for p <- 3..14 do
        byte = (p <<< 2) + 2
        assert_in_delta Martingale.h(byte, p), 1.0 / (4 * (1 <<< p)), 1.0e-15
      end
    end

    test "h(255, p) = 0 — saturated, (l₁=1, l₂=1), no further changes possible" do
      for p <- 3..14 do
        assert Martingale.h(255, p) == 0.0
      end
    end
  end

  # ---------------------------------------------------------------------
  # Reporting (gated on REPORT=1). Same shape as FGRA/MLE reports.

  defp report?, do: System.get_env("REPORT") != nil

  defp print_spot_check_report(results) do
    IO.puts("""

    UltraLogLog Martingale estimator — measurement report
    Hash4j ref: v0.17.0 (MartingaleEstimator)
    Tolerance: 0.5% relative
    Theoretical stderr: √(5·ln(2)/8m) ≈ 0.658/√m
    """)

    sep_top = "┌────┬─────────┬─────────────────┬─────────────────┬──────────────┐"
    sep_mid = "├────┼─────────┼─────────────────┼─────────────────┼──────────────┤"
    sep_bot = "└────┴─────────┴─────────────────┴─────────────────┴──────────────┘"
    head_r = "│  p │       n │ ours            │ hash4j          │ rel. error   │"

    rows =
      Enum.map_join(results, "\n", fn r ->
        "│ #{pad_l(r.p, 2)} │ #{pad_l(r.n, 7)} │ " <>
          "#{pad_l(fmt_f(r.got, 5), 15)} │ " <>
          "#{pad_l(fmt_f(r.expected, 5), 15)} │ " <>
          "#{pad_l(fmt_sci(r.rel), 12)} │"
      end)

    IO.puts([sep_top, ?\n, head_r, ?\n, sep_mid, ?\n, rows, ?\n, sep_bot])

    rels = Enum.map(results, & &1.rel)
    max_rel = Enum.max(rels)
    mean_rel = Enum.sum(rels) / length(rels)

    IO.puts(
      "Summary: #{length(results)} fixtures, " <>
        "max rel. error #{fmt_sci(max_rel)}, mean #{fmt_sci(mean_rel)}\n"
    )
  end

  defp print_stat_cell(%{
         p: p,
         n: n,
         theoretical_rse: rse,
         mean: mean,
         stddev: stddev,
         bias: bias,
         bias_bound: bias_bound,
         stddev_bound: stddev_bound,
         bias_pass: bias_pass,
         stddev_pass: stddev_pass
       }) do
    bias_pct = bias / n * 100.0
    bias_bound_pct = bias_bound / n * 100.0
    stddev_pct = stddev / n * 100.0
    stddev_bound_pct = stddev_bound / n * 100.0

    IO.puts("""

    p=#{p}, N=#{n_label(n)}
      theoretical stderr:    #{fmt_sci(rse)} (relative)
      empirical mean:        #{fmt_f(mean, 1)}   (bias  #{fmt_pct_signed(bias_pct)})
      empirical stddev:      #{fmt_f(stddev, 1)}   (rel.  #{fmt_pct(stddev_pct)})
      bias within 3σ bound:  #{pf(bias_pass)} (#{fmt_pct(abs(bias_pct))} < #{fmt_pct(bias_bound_pct)})
      stddev within 1.5x:    #{pf(stddev_pass)} (#{fmt_pct(stddev_pct)} < #{fmt_pct(stddev_bound_pct)})
    """)
  end

  defp print_stat_summary do
    rows = Agent.get(:martingale_stat_report, & &1) |> Enum.reverse()

    if rows == [] do
      :ok
    else
      n_cells = length(rows)
      n_estimates = n_cells * 30

      worst_bias = Enum.max_by(rows, fn %{bias: b, n: n} -> abs(b / n) end)
      worst_bias_pct = worst_bias.bias / worst_bias.n * 100.0
      worst_bias_bound_pct = worst_bias.bias_bound / worst_bias.n * 100.0

      worst_stddev =
        Enum.max_by(rows, fn %{stddev: s, theoretical_rse: rse, n: n} -> s / (rse * n) end)

      worst_stddev_ratio =
        worst_stddev.stddev / (worst_stddev.theoretical_rse * worst_stddev.n)

      all_pass = Enum.all?(rows, &(&1.bias_pass and &1.stddev_pass))

      IO.puts("""

      Statistical tests: #{n_cells} cells × 30 trials = #{n_estimates} estimates
      Worst bias: #{fmt_pct_signed(worst_bias_pct)} at p=#{worst_bias.p}, N=#{n_label(worst_bias.n)} (bound ±#{fmt_pct(worst_bias_bound_pct)})
      Worst stddev ratio: #{Float.round(worst_stddev_ratio, 3)} at p=#{worst_stddev.p}, N=#{n_label(worst_stddev.n)} (bound 1.5)
      #{if all_pass, do: "All PASS", else: "FAILURES PRESENT"}
      """)
    end
  end

  # --- low-level format helpers ---

  defp pad_l(v, w), do: v |> to_string() |> String.pad_leading(w)

  defp fmt_f(x, decimals) do
    :erlang.float_to_binary(x * 1.0, decimals: decimals)
  end

  defp fmt_sci(+0.0), do: "0.0"
  defp fmt_sci(-0.0), do: "0.0"
  defp fmt_sci(x), do: :erlang.float_to_binary(x * 1.0, scientific: 1)

  defp fmt_pct(v), do: "#{Float.round(v, 3)}%"
  defp fmt_pct_signed(v) when v >= 0.0, do: "+#{Float.round(v, 3)}%"
  defp fmt_pct_signed(v), do: "#{Float.round(v, 3)}%"

  defp pf(true), do: "PASS"
  defp pf(false), do: "FAIL"

  defp n_label(100), do: "100"
  defp n_label(1_000), do: "10^3"
  defp n_label(10_000), do: "10^4"
  defp n_label(100_000), do: "10^5"
  defp n_label(1_000_000), do: "10^6"
  defp n_label(other), do: to_string(other)
end
