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

  describe "spot-check against Hash4j OPTIMAL_FGRA_ESTIMATOR v0.17.0" do
    test "every fixture is within 0.1% of Hash4j" do
      assert File.exists?(@fgra_fixtures),
             "missing #{@fgra_fixtures} — regenerate with test/fixtures/java/generate.sh"

      %{"vectors" => vectors} = @fgra_fixtures |> File.read!() |> JSON.decode!()
      refute vectors == [], "fgra_estimates.json produced no vectors"

      mismatches =
        for %{"p" => p, "n" => n, "estimate" => expected} <- vectors,
            ull = load_fixture(p, n),
            got = FGRA.estimate(ull),
            rel = abs(got - expected) / expected,
            rel > @spot_check_rel_tolerance do
          %{p: p, n: n, expected: expected, got: got, rel: rel}
        end

      assert mismatches == [],
             "FGRA estimate mismatch on #{length(mismatches)} of " <>
               "#{length(vectors)} fixtures. " <>
               "First 3: " <> inspect(Enum.take(mismatches, 3), pretty: true)
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

        assert abs(bias) <= bias_bound,
               "bias |#{bias}| > 3σ bound (#{bias_bound}) " <>
                 "at p=#{@p}, N=#{@n}, mean=#{mean}, theoretical rse=#{theoretical_rse}"

        assert stddev <= stddev_bound,
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
end
