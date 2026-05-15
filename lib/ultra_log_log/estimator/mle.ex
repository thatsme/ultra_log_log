defmodule UltraLogLog.Estimator.MLE do
  @moduledoc """
  Maximum-likelihood cardinality estimator for UltraLogLog.

  Asymptotic storage factor `8 · ln(2)/ζ(2, 5/4) ≈ 4.631`, relative
  standard error `√(ln(2)/ζ(2, 5/4)) ≈ 0.761/√m`. Gives the full ~28%
  space reduction vs HLL (compared to FGRA's ~24%) at the cost of one
  iterative root-find per call.

  ## What is being maximized

  The log-likelihood under the Poisson model (Ertl 2024 §3.1, line 474):

      ln L = -(n/m)·α + Σ_{u=1}^{w-1} β_u · ln(1 − e^(−n/(m·2^u)))

  where `α` and `β_u` are closed-form weighted sums of register-value
  counts `c_j` (paper lines 480–492). Setting `d/dn ln L = 0` gives the
  ML equation, which has the same shape as the corresponding HLL one —
  so the paper (line 503) reuses the secant solver from Ertl 2017
  (arXiv:1702.01284, Algorithm 8).

  After reparameterization that solver maximizes

      e^(−x·a) · ∏_{k=0}^{n} (1 − e^(−x/2^k))^{b[k]}

  i.e. finds the root of

      g(x) := −Σb[k] + a·x + Σ_{k} b[k] · h(x/2^k)

  with `h(x) := 1 − x/(e^x − 1)`. `h` is concave and monotonically
  increasing on (0, ∞), so `g` is monotonically increasing and has a
  unique root for any non-degenerate sketch.

  ## Algorithm shape (paper-faithful, mirroring Hash4j v0.17.0)

  1. **Map registers → (a, b[])**: each register contributes to `a` and
     to up to three `b[k]` slots. The mapping (`contribute/3` below)
     ports `UltraLogLog.MaximumLikelihoodEstimator.contribute` and
     follows the paper's `α`, `β_u` definitions.

  2. **Initial guess**: closed-form Jensen lower bound on the root
     (derivation in `DistinctCountUtil.java` lines 83–104). Provably
     `≤ root`, so the secant method converges monotonically from below.
     We deliberately avoid using `FGRA.estimate/1` as the initial guess
     even though the brief originally proposed it — Jensen's bound is
     coherent with the solver's state (no inter-estimator coupling) and
     monotonicity is a stronger guarantee.

  3. **Secant iteration**: at each step, evaluate `g(x)` and use the
     secant ratio `(g − Σb) / (g_prev − g)` to update the step size.
     Convergence threshold scales with precision: stop when
     `|Δx|/x ≤ 0.001 · √v_ML / √m`. Hash4j-tight tolerance — output
     matches `MAXIMUM_LIKELIHOOD_ESTIMATOR` to ~1e-12 relative.

  4. **Inner-loop `h(x)` evaluation**: avoid `:math.exp` and `:math.log`
     by computing `h(2·x')` for small `x' ∈ [0, 0.25]` via a degree-6
     Taylor polynomial (`x' − x'²/3 + x'⁴/45 − x'⁶/472.5`, the
     Bernoulli expansion of `1 − 2x'/(e^(2x') − 1)`) and walking up by
     the doubling recurrence
     `h(2z) = (z/2 + h(z)(1−h(z))) / (z/2 + (1−h(z)))` to the target
     `x/2^k`. No transcendental evaluations inside the loop.

  5. **Bias correction**: divide the secant output by
     `1 + 0.481.../m` (paper eq. 11; the second-order delta-method
     correction).

  ## Verification

  Spot-checked against `UltraLogLog.MAXIMUM_LIKELIHOOD_ESTIMATOR`
  v0.17.0 on the same 16 register snapshots used for FGRA — see
  `test/mle_test.exs` for the tolerance and statistical-correctness
  battery, and `test/mle_test.exs` again for the convergence-speed
  test (mean iterations < 10, max < 50 across 100 random sketches).
  """

  require Logger
  import Bitwise

  # --- paper constants, all per §3.1 / Hash4j v0.17.0 lines 411 + 422 ---

  # Asymptotic relative standard error: √(ln(2)/ζ(2, 5/4)) ≈ 0.7608621.
  # Equivalently √v_ML where v_ML ≈ 0.5789 (the single-register variance
  # implied by MVP_ML ≈ 4.631 = 8·v_ML, paper §3.1 line 624).
  @inv_sqrt_fisher_information 0.7608621002725182

  # First-order bias correction: n̂ = n̂_ML / (1 + 0.481.../m) — paper eq.
  # (11), line 526. Numerical value of 3/2·ln(2)·ζ(3,5/4)/ζ(2,5/4)².
  @bias_correction_constant 0.48147376527720065

  # Convergence threshold factor. The secant loop exits when
  # `|Δx|/x ≤ @solver_eps_factor · @inv_sqrt_fisher_information / √m`.
  # Hash4j uses this same scaling (UltraLogLog.java line 414); keeps
  # solver noise comfortably below the inherent estimator stderr.
  @solver_eps_factor 0.001

  # Maximum iterations before bailing out. Secant typically converges in
  # 3–6; we cap at 100 to detect pathological inputs.
  @max_iterations 100

  # Bernoulli-derived Taylor coefficients for `h(2·x')` near x'=0.
  # Verified by expanding 1 − 2x' / (e^(2x') − 1):
  # x' − x'²/3 + 0·x'³ + x'⁴/45 + 0·x'⁵ − x'⁶/472.5 + O(x'⁸).
  # See Hash4j DistinctCountUtil.java lines 38–40.
  @h_taylor_c0 -1.0 / 3.0
  @h_taylor_c1 1.0 / 45.0
  @h_taylor_c2 1.0 / 472.5

  # Safe-fallback estimate for saturated sketches. Hash4j returns
  # `Double.POSITIVE_INFINITY`; we have no IEEE infinity literal on
  # BEAM, so a large finite double is the equivalent floor.
  @saturated_sentinel 1.0e308

  @doc """
  Estimate cardinality from the current sketch state, per Ertl 2024
  §3.1 (conference numbering; equivalent to arXiv §4.2).
  """
  @spec estimate(UltraLogLog.t()) :: float()
  def estimate(%UltraLogLog{} = ull) do
    {estimate, _iterations} = estimate_with_iterations(ull)
    estimate
  end

  @doc """
  Same as `estimate/1`, but also returns the secant iteration count.
  Used by `test/mle_test.exs` to assert convergence speed; not intended
  for production use.
  """
  @spec estimate_with_iterations(UltraLogLog.t()) :: {float(), non_neg_integer()}
  def estimate_with_iterations(%UltraLogLog{registers: regs, m: m, precision: p}) do
    b0 = List.duplicate(0, 64)
    {sum, b_list} = sweep_registers(regs, p, 0, b0)

    cond do
      sum == 0 ->
        # Either all registers are zero (n = 0) or all are saturated
        # (n ≫ 2^64). The first byte distinguishes the cases — same
        # disambiguation Hash4j uses on UltraLogLog.java line 468.
        if :binary.at(regs, 0) == 0 do
          {0.0, 0}
        else
          Logger.warning(
            "MLE: sketch fully saturated (sum=0, register 0 ≠ 0); " <>
              "returning #{@saturated_sentinel} as a lower bound on cardinality"
          )

          {@saturated_sentinel, 0}
        end

      true ->
        do_estimate(sum, b_list, m, p)
    end
  end

  defp do_estimate(sum, b_list, m, p) do
    # Hash4j collapses the last two b[] slots (line 470) — the last
    # achievable nlz index folds into the prior one because the
    # `contribute` branch for saturated registers always bumps `b[k+2]`
    # regardless of the low bits.
    last_idx = 63 - p
    b_list = fold_last_two(b_list, last_idx)

    factor = m * 2.0
    a = sum / 0x1_0000_0000_0000_0000 * factor

    rel_eps = @solver_eps_factor * @inv_sqrt_fisher_information / :math.sqrt(m * 1.0)
    {x_solved, iterations} = solve_mle_equation(a, b_list, last_idx, rel_eps)

    raw = factor * x_solved
    corrected = raw / (1.0 + @bias_correction_constant / m)

    {corrected, iterations}
  end

  # ---------------------------------------------------------------------
  # Register → (sum, b[]) mapping. Port of Hash4j v0.17.0
  # `UltraLogLog.MaximumLikelihoodEstimator.contribute` (lines 425–449).
  #
  # `sum` is the cumulative bignum sum; in the Java original it's an
  # unsigned-64 wraparound, but the true sum is bounded by 2^64
  # (per-register contributions ≤ 2^(64-p), m = 2^p registers ⇒ total
  # ≤ 2^64), so a bignum captures the same value with no truncation.

  defp sweep_registers(<<>>, _p, sum, b), do: {sum, b}

  defp sweep_registers(<<r, rest::binary>>, p, sum, b) do
    {contribution, b} = contribute(r, p, b)
    sweep_registers(rest, p, sum + contribution, b)
  end

  defp contribute(r, p, b) do
    r2 = r - (p <<< 2) - 4

    if r2 < 0 do
      small_range_contribute(r2, p, b)
    else
      intermediate_contribute(r, r2, p, b)
    end
  end

  # Small range: r ∈ {0, 4p−4, 4p, 4p+2} (paper r ∈ {0, 4, 8, 10}).
  # b[0] is bumped when r maps to paper r = 4 or 10 (r2 ∈ {-8, -2}).
  # b[1] is bumped when r maps to paper r = 8 or 10 (r2 ∈ {-4, -2}).
  # ret_adj is 4 minus the b-related subtractions; multiplied by
  # 2^(62-p) gives the unscaled contribution.
  defp small_range_contribute(r2, p, b) do
    {ret_adj, b} =
      case r2 do
        -2 -> {1, b |> list_inc(0) |> list_inc(1)}
        -8 -> {2, list_inc(b, 0)}
        -4 -> {3, list_inc(b, 1)}
        _ -> {4, b}
      end

    contribution = ret_adj <<< (62 - p)
    {contribution, b}
  end

  # Intermediate / large range: paper u = ⌊paper_r/4⌋ ≥ 3. The byte's
  # low 2 bits (y0 = bit 0, y1 = bit 1) indicate whether the prior
  # two updates were observed; this maps to bumps in b[k], b[k+1],
  # b[k+2] where k = u − 2 = r2/4.
  defp intermediate_contribute(r, r2, p, b) do
    k = r2 >>> 2
    y0 = r &&& 1
    y1 = r >>> 1 &&& 1

    b =
      b
      |> list_add(k, y0)
      |> list_add(k + 1, y1)
      |> list_inc(k + 2)

    # Hash4j builds the contribution bit-by-bit as
    #   ret = 0xE000000000000000 − (y0 << 63) − (y1 << 62)
    #   contribution = ret >>> (k + p)
    # Equivalently a factor in {1,3,5,7} at bit position (61−k−p):
    ret_top3 = 7 - 4 * y0 - 2 * y1
    contribution = ret_top3 * pow2(61 - k - p)
    {contribution, b}
  end

  defp list_inc(list, idx), do: list_add(list, idx, 1)

  defp list_add(list, idx, delta) do
    List.update_at(list, idx, &(&1 + delta))
  end

  defp pow2(n) when n >= 0, do: 1 <<< n
  defp pow2(n), do: 1.0 / (1 <<< -n)

  defp fold_last_two(list, idx) do
    a = Enum.at(list, idx)
    c = Enum.at(list, idx + 1)
    List.replace_at(list, idx, a + c)
  end

  # ---------------------------------------------------------------------
  # Secant root-finder. Port of `DistinctCountUtil.solveMaximumLikelihoodEquation`
  # (lines 63–190), itself an Elixirization of Ertl 2017 Algorithm 8.
  # Returns `{x_solved, iterations}`.

  # Guard form satisfies OTP 27's pattern-match warning on 0.0 (which
  # now requires +0.0 / -0.0 disambiguation). For our purposes either
  # sign of zero indicates a saturated sketch.
  defp solve_mle_equation(a, _b_list, _n, _rel_eps) when a == 0.0 do
    {@saturated_sentinel, 0}
  end

  defp solve_mle_equation(a, b_list, n, rel_eps) do
    b_tuple = List.to_tuple(b_list)

    case find_k_bounds(b_tuple, n) do
      :empty ->
        {0.0, 0}

      {k_max, k_min, s1, s2} ->
        x0 = initial_guess(a, s1, s2)
        # Initialize delta_x := x to mirror Hash4j's invariant
        # `deltaX` = "magnitude of most recent (or first planned) step".
        secant_loop(a, b_tuple, k_max, k_min, s1, x0, x0, 0.0, 0, rel_eps)
    end
  end

  # Scan b[] for first and last non-zero indices and accumulate
  # `s1 = Σ b[k]`, `s2 = Σ b[k] · 2^k`. b_tuple is a 64-element tuple.
  defp find_k_bounds(b_tuple, n) do
    case find_k_max(b_tuple, n) do
      nil ->
        :empty

      k_max ->
        bk = elem(b_tuple, k_max)
        accumulate_b(b_tuple, k_max - 1, k_max, bk, bk * pow2_f(k_max))
    end
  end

  defp find_k_max(_b, k) when k < 0, do: nil

  defp find_k_max(b, k) do
    if elem(b, k) != 0, do: k, else: find_k_max(b, k - 1)
  end

  defp accumulate_b(_b, k, k_max, s1, s2) when k < 0 do
    # k_min defaults to k_max if no other non-zero index found.
    {k_max, k_max, s1, s2}
  end

  defp accumulate_b(b, k, k_max, s1, s2) do
    case elem(b, k) do
      0 -> accumulate_b(b, k - 1, k_max, s1, s2)
      t -> accumulate_b_with_k_min(b, k - 1, k_max, k, s1 + t, s2 + t * pow2_f(k))
    end
  end

  defp accumulate_b_with_k_min(_b, k, k_max, k_min, s1, s2) when k < 0,
    do: {k_max, k_min, s1, s2}

  defp accumulate_b_with_k_min(b, k, k_max, k_min, s1, s2) do
    case elem(b, k) do
      0 -> accumulate_b_with_k_min(b, k - 1, k_max, k_min, s1, s2)
      t -> accumulate_b_with_k_min(b, k - 1, k_max, k, s1 + t, s2 + t * pow2_f(k))
    end
  end

  # Jensen lower bound on the root. Hash4j lines 148–154:
  #   x = s1 / (0.5·s2 + a)              if s2 ≤ 1.5·a
  #     = ln(1 + s2/a) · (s1/s2)         otherwise
  defp initial_guess(a, s1, s2) do
    if s2 <= 1.5 * a do
      s1 / (0.5 * s2 + a)
    else
      # log(1 + s2/a) — Erlang's :math has no log1p, but s2/a is bounded
      # below by ~0.667 in this branch (since s2 > 1.5·a), so the
      # log1p-vs-log(1+x) precision difference is irrelevant here.
      :math.log(1.0 + s2 / a) * (s1 / s2)
    end
  end

  # Secant iteration. State carried (mirrors Hash4j's loop variables):
  #   x         current iterate
  #   delta_x   magnitude of last applied step (or, on iter 0, the
  #             initial guess — Hash4j seeds it as `deltaX = x` so the
  #             first secant update has a nonzero baseline)
  #   g_prev    g(x_prev), 0.0 at start
  #   iter      iteration count
  defp secant_loop(_a, _b, _km, _kn, _s1, x, _dx, _gp, iter, _eps)
       when iter >= @max_iterations do
    Logger.warning(
      "MLE solver did not converge after #{@max_iterations} secant iterations " <>
        "(x ≈ #{x}); returning last iterate"
    )

    {x, iter}
  end

  defp secant_loop(a, b, k_max, k_min, s1, x, delta_x, g_prev, iter, rel_eps) do
    g = evaluate_g(x, a, b, k_max, k_min)

    cond do
      iter > 0 and not (g_prev < g and g <= s1) ->
        # Hash4j's monotonic-improvement guard fails — overshoot,
        # numerical fixed point, or root reached. Stop with current x.
        {x, iter}

      true ->
        new_delta_x = delta_x * (g - s1) / (g_prev - g)
        advance_or_terminate(a, b, k_max, k_min, s1, x, new_delta_x, g, iter, rel_eps)
    end
  end

  defp advance_or_terminate(a, b, k_max, k_min, s1, x, new_delta_x, g, iter, rel_eps) do
    cond do
      not finite?(new_delta_x) ->
        Logger.warning(
          "MLE solver produced non-finite secant step at iter #{iter}; returning x ≈ #{x}"
        )

        {x, iter}

      true ->
        x_new = x + new_delta_x

        if new_delta_x <= x_new * rel_eps do
          {x_new, iter + 1}
        else
          secant_loop(a, b, k_max, k_min, s1, x_new, new_delta_x, g, iter + 1, rel_eps)
        end
    end
  end

  # NaN and ±Inf are all floats; `x == x` is false for NaN and abs(Inf)
  # is Inf > 1.0e300. So the float clause handles every IEEE 754 case.
  defp finite?(x) when is_float(x), do: x == x and abs(x) < 1.0e300

  defp pow2_f(k) when k >= 0 and k < 1024, do: :math.pow(2.0, k)

  # ---------------------------------------------------------------------
  # g(x) := a·x + Σ_{k=k_min..k_max} b[k] · h(x/2^k)
  # evaluated without `:math.exp`. h(z) := 1 − z/(e^z − 1).
  #
  # Mirrors Hash4j v0.17.0 lines 158–180:
  #   1. Decompose x = 2^(κ−2) · 1.mantissa via IEEE-754 bit pun. Then
  #      x_prime := x / 2^(max(k_max, κ) + 1) lies in [0, 0.25] — the
  #      well-conditioned range for the Taylor expansion of h(2·x_prime).
  #   2. Apply the Taylor polynomial to get h(2·x_prime). Walk up via
  #      the doubling recurrence h(2z) = (z/2 + h(z)(1−h(z)))/(z/2 + (1−h(z)))
  #      to reach h(x/2^k_max).
  #   3. Walk down through k_max-1 .. k_min, accumulating b[k]·h(x/2^k).
  #   4. Add a·x.

  defp evaluate_g(x, a, b_tuple, k_max, k_min) do
    kappa = ieee_kappa(x)
    start_shift = max(k_max, kappa) + 1
    x_prime0 = x / pow2_f(start_shift)
    h0 = taylor_h(x_prime0)

    {h, x_prime} =
      if kappa - 1 >= k_max do
        walk_up(h0, x_prime0, kappa - 1 - k_max + 1)
      else
        {h0, x_prime0}
      end

    g0 = elem(b_tuple, k_max) * h
    accumulate_g(b_tuple, k_max - 1, k_min, g0, h, x_prime) + x * a
  end

  defp accumulate_g(_b, k, k_min, g, _h, _xp) when k < k_min, do: g

  defp accumulate_g(b, k, k_min, g, h, x_prime) do
    h_prime = 1.0 - h
    h_next = (x_prime + h * h_prime) / (x_prime + h_prime)
    x_prime_next = x_prime + x_prime
    accumulate_g(b, k - 1, k_min, g + elem(b, k) * h_next, h_next, x_prime_next)
  end

  defp walk_up(h, x_prime, 0), do: {h, x_prime}

  defp walk_up(h, x_prime, n) do
    h_prime = 1.0 - h
    h_next = (x_prime + h * h_prime) / (x_prime + h_prime)
    walk_up(h_next, x_prime + x_prime, n - 1)
  end

  # IEEE 754 κ extraction. For x = 2^E · 1.mantissa (normalized double,
  # E ∈ [-1022, 1023]), Hash4j defines κ := E + 2 so that
  # x / 2^(κ+1) ∈ [0.125, 0.25] (the Taylor sweet spot for h(2·x')).
  defp ieee_kappa(x) when x > 0 do
    <<_sign::1, raw_exp::11, _mantissa::52>> = <<x::float>>
    raw_exp - 1021
  end

  # Taylor polynomial for h(2·x'): x' + x'²·(C0 + x'²·(C1 - x'²·C2)).
  # Argument range: x' ∈ [0, 0.25].
  defp taylor_h(x_prime) do
    xp2 = x_prime * x_prime
    x_prime + xp2 * (@h_taylor_c0 + xp2 * (@h_taylor_c1 - xp2 * @h_taylor_c2))
  end
end
