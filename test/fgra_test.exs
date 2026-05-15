defmodule UltraLogLog.Estimator.FGRATest do
  @moduledoc """
  Tests for `UltraLogLog.Estimator.FGRA`.

  Two categories:

    * **Spot-check** (default): exercise `estimate/1` on the 16 register
      snapshots produced by Hash4j v0.17.0 and assert agreement with
      `OPTIMAL_FGRA_ESTIMATOR`'s reported value within 0.1% relative.
      Since our encoding is bit-exact and the math is paper-faithful,
      we observe ~1e-16 relative in practice — the 0.1% tolerance
      catches any genuine bug while leaving room for float reordering.

    * **Statistical** (`@moduletag :statistical`, opt-in via
      `mix test --include statistical`): for p ∈ {10, 12, 14} and
      N ∈ {100, 1k, 10k, 100k, 1M}, run 30 trials of inserts and assert
      empirical bias and standard deviation are within multiples of the
      theoretical relative standard error `0.782/√m`. Runs in minutes.

  ## Measurement reporting

  Setting `REPORT=1` makes both test categories emit human-readable
  tables of the divergence vs Hash4j and the empirical bias/variance
  vs the paper's theoretical bound. Pass/fail logic is unchanged —
  only IO is added. Example:

      REPORT=1 mix test --include statistical test/fgra_test.exs
  """

  use ExUnit.Case, async: true

  import Bitwise

  alias UltraLogLog.Estimator.FGRA

  @fixtures_dir Path.join([__DIR__, "fixtures"])
  @fgra_fixtures Path.join(@fixtures_dir, "fgra_estimates.json")

  # Tight tolerance — see moduledoc. With bit-exact registers we
  # routinely measure < 1e-15; 0.1% catches real bugs.
  @spot_check_rel_tolerance 1.0e-3

  # Theoretical FGRA relative standard error (Ertl 2024 §3.3, line 624:
  # MVP = 8v ≈ 4.895, so rel-stderr = √(MVP/(8m)) = √(v/m) ≈ 0.782/√m).
  @theoretical_rse_factor :math.sqrt(0.6118931496978437)

  # Module-level setup. Under REPORT=1, start an Agent that the
  # statistical cells append to, and register an on_exit hook that
  # prints the cross-cell summary once all tests in this module have
  # finished. setup_all must live at the module scope — ExUnit forbids
  # it inside `describe`.
  setup_all do
    if report?() do
      case Agent.start_link(fn -> [] end, name: :fgra_stat_report) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _}} -> Agent.update(:fgra_stat_report, fn _ -> [] end)
      end

      on_exit(fn -> print_stat_summary() end)
    end

    :ok
  end

  describe "spot-check against Hash4j OPTIMAL_FGRA_ESTIMATOR v0.17.0" do
    test "every fixture is within 0.1% of Hash4j" do
      assert File.exists?(@fgra_fixtures),
             "missing #{@fgra_fixtures} — regenerate with test/fixtures/java/generate.sh"

      %{"vectors" => vectors} = @fgra_fixtures |> File.read!() |> JSON.decode!()
      refute vectors == [], "fgra_estimates.json produced no vectors"

      results =
        for %{"p" => p, "n" => n, "estimate" => expected} <- vectors do
          ull = load_fixture(p, n)
          got = FGRA.estimate(ull)
          rel = abs(got - expected) / max(expected, 1.0)
          %{p: p, n: n, expected: expected, got: got, rel: rel}
        end

      mismatches = Enum.filter(results, &(&1.rel > @spot_check_rel_tolerance))

      assert mismatches == [],
             "FGRA estimate mismatch on #{length(mismatches)} of " <>
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
  # Statistical correctness. Bias and variance must agree with the
  # theoretical FGRA error bound (0.782/√m, paper line 624 / MVP 4.895)
  # to within sane multiples — 3σ for the mean (≈ 0.3% false-positive
  # rate per assertion if the estimator is correct), 1.5× for the
  # empirical stddev.
  # ---------------------------------------------------------------------

  describe "statistical correctness across (p, N) grid" do
    @describetag :statistical

    # Fixed seeds so failures are reproducible. Each trial gets an
    # independent (algo, {a,b,c}) seed derived from a master constant
    # plus the trial index.
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
        # 3σ band on empirical mean: stderr-of-mean = rse · √(1/T).
        bias_bound = 3.0 * theoretical_rse / :math.sqrt(@trials) * @n
        # Empirical stddev within 50% of theoretical.
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
          Agent.update(:fgra_stat_report, fn rows -> [row | rows] end)
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

      {:ok, est} = UltraLogLog.cardinality(ull)
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
  # Reporting (gated on REPORT=1). Pass/fail logic above is unchanged;
  # this block is pure IO formatted for human reading. Output lines are
  # built as full multi-line binaries and emitted via single `IO.puts`
  # calls, so each cell stays internally coherent even if any future
  # reorganization makes tests interleave.

  defp report?, do: System.get_env("REPORT") != nil

  defp print_spot_check_report(results) do
    IO.puts("""

    UltraLogLog FGRA estimator — measurement report
    Hash4j ref: v0.17.0 (OPTIMAL_FGRA_ESTIMATOR)
    Tolerance: 0.1% relative
    Theoretical stderr: 0.782/√m
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
    rows = Agent.get(:fgra_stat_report, & &1) |> Enum.reverse()

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

  # `1.0e-15`, `4.4e-15`, `0.0e+00` etc. via Erlang's scientific
  # formatter; for x == 0.0 we emit a flat "0.0" since the scientific
  # form is noisier than useful in that case.
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
