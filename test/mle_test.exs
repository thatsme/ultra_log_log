defmodule UltraLogLog.Estimator.MLETest do
  @moduledoc """
  Tests for `UltraLogLog.Estimator.MLE`.

  Three categories:

    * **Spot-check** (default): the 16 register snapshots from Hash4j
      v0.17.0 are passed through our `estimate/1`; output must agree
      with `UltraLogLog.MAXIMUM_LIKELIHOOD_ESTIMATOR` to within 0.5%
      relative. In practice — since both implementations solve the
      same secant equation to ~1e-12 — observed divergence is at
      floating-point noise.

    * **Statistical** (`@moduletag :statistical`, opt-in via
      `mix test --include statistical`): same p × N × T grid as FGRA;
      bounds are tighter because MLE's theoretical relative stderr is
      `0.761/√m`, not `0.782/√m`.

    * **Convergence** (`@moduletag :statistical`): instrument
      `estimate_with_iterations/1` and assert mean iterations < 10 and
      max < 50 across 100 random sketches per precision. Catches a
      "still converges but does so glacially" regression that
      correctness tests wouldn't flag.

  ## Measurement reporting

  `REPORT=1 mix test --include statistical test/mle_test.exs` emits
  human-readable tables and an end-of-run summary, same shape as the
  FGRA report. Default runs are silent.
  """

  use ExUnit.Case, async: true

  import Bitwise

  alias UltraLogLog.Estimator.MLE

  @fixtures_dir Path.join([__DIR__, "fixtures"])
  @mle_fixtures Path.join(@fixtures_dir, "mle_estimates.json")

  # Per brief: looser than FGRA's 0.1% because secant convergence
  # parameterization differs between implementations. In practice we
  # observe < 1e-15 since we match Hash4j's tolerance.
  @spot_check_rel_tolerance 5.0e-3

  # MLE theoretical relative stderr: √(ln(2)/ζ(2, 5/4)) ≈ 0.7608621
  # (paper §3.1 line 624 implies via MVP_ML = 4.631 = 8·v_ML).
  @theoretical_rse_factor 0.7608621002725182

  # ---------------------------------------------------------------------
  # Module-level setup. Under REPORT=1, start agents that statistical
  # and convergence cells append to, and register an on_exit hook that
  # prints cross-cell summaries once all tests finish.

  setup_all do
    if report?() do
      ensure_agent(:mle_stat_report)
      ensure_agent(:mle_conv_report)

      on_exit(fn ->
        print_stat_summary()
        print_conv_summary()
      end)
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
  # (A) Spot-check vs Hash4j MAXIMUM_LIKELIHOOD_ESTIMATOR.

  describe "spot-check against Hash4j MAXIMUM_LIKELIHOOD_ESTIMATOR v0.17.0" do
    test "every fixture is within 0.5% of Hash4j" do
      assert File.exists?(@mle_fixtures),
             "missing #{@mle_fixtures} — regenerate with test/fixtures/java/generate.sh"

      %{"vectors" => vectors} = @mle_fixtures |> File.read!() |> JSON.decode!()
      refute vectors == [], "mle_estimates.json produced no vectors"

      results =
        for %{"p" => p, "n" => n, "estimate" => expected} <- vectors do
          ull = load_fixture(p, n)
          {got, iters} = MLE.estimate_with_iterations(ull)
          rel = abs(got - expected) / max(expected, 1.0)
          %{p: p, n: n, expected: expected, got: got, rel: rel, iters: iters}
        end

      mismatches = Enum.filter(results, &(&1.rel > @spot_check_rel_tolerance))

      assert mismatches == [],
             "MLE estimate mismatch on #{length(mismatches)} of " <>
               "#{length(results)} fixtures. " <>
               "First 3: " <> inspect(Enum.take(mismatches, 3), pretty: true)

      if report?(), do: print_spot_check_report(results)
    end
  end

  defp load_fixture(p, n) do
    bin = File.read!(Path.join(@fixtures_dir, "ull_p#{p}_n#{n}.bin"))
    %UltraLogLog{precision: p, m: 1 <<< p, registers: bin, martingale: nil}
  end

  # ---------------------------------------------------------------------
  # (B) Statistical correctness.

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
          Agent.update(:mle_stat_report, fn rows -> [row | rows] end)
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

      {:ok, est} = UltraLogLog.cardinality(ull, estimator: :mle)
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
  # (C) Convergence-speed tracking.

  describe "secant convergence speed" do
    @describetag :statistical

    @conv_sketches_per_p 100
    @conv_seed_base 0xCAFE_F00D_1234

    @conv_max_iter 50
    @conv_mean_iter 10.0

    for p <- [10, 12, 14] do
      @p p

      test "p=#{p}: 100 random sketches converge fast" do
        iters_list = run_conv_trials(@p, @conv_sketches_per_p)

        mean_iters = Enum.sum(iters_list) / length(iters_list)
        max_iters = Enum.max(iters_list)

        if report?() do
          row = %{p: @p, mean: mean_iters, max: max_iters, sketches: @conv_sketches_per_p}
          Agent.update(:mle_conv_report, fn rows -> [row | rows] end)
        end

        assert mean_iters < @conv_mean_iter,
               "MLE convergence: p=#{@p}, mean iters #{mean_iters} ≥ #{@conv_mean_iter}"

        assert max_iters < @conv_max_iter,
               "MLE convergence: p=#{@p}, max iters #{max_iters} ≥ #{@conv_max_iter}"
      end
    end

    defp run_conv_trials(p, k_sketches) do
      # Random N spread over [1, 10^6] in log space, one per sketch, so
      # the convergence test exercises both small and large cardinality
      # regimes (the solver's hardest cases are at the boundaries).
      seed = :rand.seed_s(:exsss, {@conv_seed_base, @conv_seed_base, @conv_seed_base})

      {iters, _final} =
        Enum.map_reduce(1..k_sketches, seed, fn _, st ->
          {u, st} = :rand.uniform_s(st)
          n = trunc(:math.pow(10.0, u * 6.0)) + 1

          {ull, st} =
            Enum.reduce(1..n, {UltraLogLog.new(precision: p), st}, fn _, {acc, s} ->
              {h, s} = :rand.uniform_s(0x1_0000_0000_0000_0000, s)
              {UltraLogLog.add(acc, h - 1), s}
            end)

          {_estimate, iter_count} = MLE.estimate_with_iterations(ull)
          {iter_count, st}
        end)

      iters
    end
  end

  # ---------------------------------------------------------------------
  # Reporting (gated on REPORT=1). Pass/fail logic above is unchanged;
  # this block is pure IO formatted for human reading.

  defp report?, do: System.get_env("REPORT") != nil

  defp print_spot_check_report(results) do
    IO.puts("""

    UltraLogLog MLE estimator — measurement report
    Hash4j ref: v0.17.0 (MAXIMUM_LIKELIHOOD_ESTIMATOR)
    Tolerance: 0.5% relative
    Theoretical stderr: 0.761/√m
    """)

    sep_top = "┌────┬─────────┬─────────────────┬─────────────────┬──────────────┬───────┐"
    sep_mid = "├────┼─────────┼─────────────────┼─────────────────┼──────────────┼───────┤"
    sep_bot = "└────┴─────────┴─────────────────┴─────────────────┴──────────────┴───────┘"
    head_r = "│  p │       n │ ours            │ hash4j          │ rel. error   │ iters │"

    rows =
      Enum.map_join(results, "\n", fn r ->
        "│ #{pad_l(r.p, 2)} │ #{pad_l(r.n, 7)} │ " <>
          "#{pad_l(fmt_f(r.got, 5), 15)} │ " <>
          "#{pad_l(fmt_f(r.expected, 5), 15)} │ " <>
          "#{pad_l(fmt_sci(r.rel), 12)} │ " <>
          "#{pad_l(r.iters, 5)} │"
      end)

    IO.puts([sep_top, ?\n, head_r, ?\n, sep_mid, ?\n, rows, ?\n, sep_bot])

    rels = Enum.map(results, & &1.rel)
    iters_l = Enum.map(results, & &1.iters)
    max_rel = Enum.max(rels)
    mean_rel = Enum.sum(rels) / length(rels)
    mean_iters = Enum.sum(iters_l) / length(iters_l)
    max_iters = Enum.max(iters_l)

    IO.puts(
      "Summary: #{length(results)} fixtures, " <>
        "max rel. error #{fmt_sci(max_rel)}, mean #{fmt_sci(mean_rel)}, " <>
        "iters mean #{Float.round(mean_iters, 2)} max #{max_iters}\n"
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
    rows = Agent.get(:mle_stat_report, & &1) |> Enum.reverse()

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

  defp print_conv_summary do
    rows = Agent.get(:mle_conv_report, & &1) |> Enum.reverse()

    if rows != [] do
      total_sketches = Enum.sum(Enum.map(rows, & &1.sketches))
      worst_max = Enum.max_by(rows, & &1.max)
      worst_mean = Enum.max_by(rows, & &1.mean)

      per_precision =
        rows
        |> Enum.sort_by(& &1.p)
        |> Enum.map_join("\n", fn r ->
          "  p=#{r.p}: mean #{Float.round(r.mean, 2)} iters, max #{r.max}"
        end)

      IO.puts("""

      Convergence speed: #{total_sketches} random sketches across #{length(rows)} precisions
      #{per_precision}
      Worst mean: #{Float.round(worst_mean.mean, 2)} iters at p=#{worst_mean.p} (bound 10)
      Worst max:  #{worst_max.max} iters at p=#{worst_max.p} (bound 50)
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
