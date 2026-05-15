defmodule UltraLogLog.Estimator.FGRA do
  @moduledoc """
  Default UltraLogLog cardinality estimator — Further Generalized Remaining
  Area (FGRA), a faithful translation of **Algorithm 6** from Ertl 2024
  (PVLDB 2024, p. 1664).

  The estimator combines:

    * a single-pass register sweep that sums the intermediate-range
      contribution `g(rᵢ)` (eq. 15 / §3.3) and counts the eight
      special-case bytes that trigger range corrections,
    * a small-range correction (§3.5, eq. 23 + the corrected
      contributions in eq. 18) when any byte falls into the four
      smallest reachable states,
    * a large-range correction (§3.6, eq. 24 + the trailing branch
      of eq. 18) when any byte saturates,
    * the closing `λₚ · s^(-1/τ)` factor (eq. 12 / Algorithm 6 caption).

  Asymptotic relative standard error is `√v/m` ≈ `0.782/√m`; the
  memory-variance product (MVP) is `8v ≈ 4.895145` (paper line 624) —
  this is the constant the README and `UltraLogLog` moduledoc cite as
  "storage factor 4.895". It is *not* the same as `τ`; the FGRA
  estimator's exponent constant is `τ ≈ 0.819491`, defined per
  Algorithm 6 caption.

  ## Why paper-faithful and not table-based

  Hash4j's reference implementation (`OptimalFGRAEstimator` in
  `UltraLogLog.java` v0.17.0, lines 481–923) precomputes two arrays:
  a 252-entry `REGISTER_CONTRIBUTIONS` table caching `g(byte)` for the
  intermediate range, and a 24-entry `ESTIMATION_FACTORS` table caching
  `λₚ`. The numerical math is identical to Algorithm 6 — the tables
  only trade memory for a few `:math.pow` calls. We compute both inline
  so that this module reads as a one-to-one translation of the paper
  alongside `paper/p1655-ertl.pdf`. A table-backed variant is v0.2 work;
  cross-checked against `OPTIMAL_FGRA_ESTIMATOR` in `test/fgra_test.exs`
  to within 0.1% relative.

  ## Shifted register convention

  This module operates on the shifted byte encoding `byte = paper_r +
  4p − 8` for nonzero registers (see `UltraLogLog.Encoding`). That
  shift collapses the eight special-case paper-r values
  `{0, 4, 8, 10, 4w, 4w+1, 4w+2, 4w+3}` (with `w := 65 − p`) into byte
  values `{0, 4p − 4, 4p, 4p + 2, 252, 253, 254, 255}` — the
  large-range constants are precision-independent because the +4p−8
  shift is what saturates the byte at 255.
  """

  import Bitwise

  # --- paper constants, all per Algorithm 6 caption (line 928–931) ---

  # FGRA contribution exponent. Defined as the τ that minimizes the
  # asymptotic variance (14) for ULL with b = 2 and d = 2 (paper §3.3,
  # line 619). Not to be confused with the storage factor 4.895; see
  # the moduledoc.
  @tau 0.8194911375910897

  # Asymptotic single-register variance v ≈ 0.611893 at the optimal τ
  # (paper line 620). Used only in λₚ.
  @v 0.6118931496978437

  # Optimal FGRA contribution coefficients η₀..η₃ for ULL with b = 2
  # and d = 2 (paper line 623, derived from eq. 16). Used in g(r) /
  # eq. 15, in the small-range correction / eq. 18, and in the
  # large-range correction / Algorithm 6.
  @eta_0 4.663135422063788
  @eta_1 2.1378502137958524
  @eta_2 2.781144650979996
  @eta_3 0.9824082545153715

  # η_X := η₀ − η₁ − η₂ + η₃ — the leading coefficient of ψ (eq. 19),
  # also the u=0 prefactor inside σ (eq. 20). Pulled out so it can be
  # absorbed once into the running 2^(τu) accumulator and never
  # re-multiplied inside the σ loop.
  @eta_x @eta_0 - @eta_1 - @eta_2 + @eta_3

  # Frequently-needed derived constants. Computed from @tau at module
  # compile time so the hot path is multiplication-only.
  @two_pow_tau :math.pow(2.0, @tau)
  @two_pow_minus_tau :math.pow(2.0, -@tau)
  @four_pow_minus_tau :math.pow(4.0, -@tau)
  @minus_inv_tau -1.0 / @tau

  # Reused inside ψ via Horner form.
  @eta_2_minus_3 @eta_2 - @eta_3
  @eta_1_minus_3 @eta_1 - @eta_3

  # Reused inside φ via Hash4j's `psi'(z, z²) = ψ(z) / η_X`
  # factorization (Hash4j UltraLogLog.java v0.17.0 line 797). The
  # algebraic identity is verified by expanding ψ and matching
  # coefficients; the rearranged form keeps the inner-loop arithmetic
  # in the same scale Hash4j uses, so our φ output matches theirs
  # bit-for-bit modulo float reordering.
  @psi_prime_eta23x @eta_2_minus_3 / @eta_x
  @psi_prime_eta13x @eta_1_minus_3 / @eta_x
  @psi_prime_eta3012xx (@eta_3 * @eta_0 - @eta_1 * @eta_2) / (@eta_x * @eta_x)

  # P_INITIAL := η_X · 4^(-τ) / (2 − 2^(-τ)); the prefactor that
  # absorbs the leading 4^(-τ)/(2 − 2^(-τ)) outside φ's series
  # (Hash4j line 504).
  @phi_p_initial @eta_x * @four_pow_minus_tau / (2.0 - @two_pow_minus_tau)

  # PHI_1 := η₀ / (2^τ · (2·2^τ − 1)) — the limit value of φ at z = 1
  # (Hash4j line 503). Reachable only when the entire ULL state has
  # saturated; required for total-ness of `phi/1` on edge inputs.
  @phi_one @eta_0 / (@two_pow_tau * (2.0 * @two_pow_tau - 1.0))

  @doc """
  Estimate cardinality from the current sketch state, per Ertl 2024
  Algorithm 6.
  """
  @spec estimate(UltraLogLog.t()) :: float()
  def estimate(%UltraLogLog{registers: regs, m: m, precision: p}) do
    w = 65 - p

    # Boundaries in the shifted byte space. See moduledoc.
    intermediate_lo = (p <<< 2) + 4
    byte_4 = (p <<< 2) - 4
    byte_8 = p <<< 2
    byte_10 = (p <<< 2) + 2

    # Algorithm 6 lines 934–952: single pass over registers.
    # Accumulator tuple is {s, c0, c4, c8, c10, c4w0, c4w1, c4w2, c4w3}.
    {s, c0, c4, c8, c10, c4w0, c4w1, c4w2, c4w3} =
      for <<r <- regs>>, reduce: {0.0, 0, 0, 0, 0, 0, 0, 0, 0} do
        {s, c0, c4, c8, c10, c4w0, c4w1, c4w2, c4w3} ->
          cond do
            r == 0 -> {s, c0 + 1, c4, c8, c10, c4w0, c4w1, c4w2, c4w3}
            r == byte_4 -> {s, c0, c4 + 1, c8, c10, c4w0, c4w1, c4w2, c4w3}
            r == byte_8 -> {s, c0, c4, c8 + 1, c10, c4w0, c4w1, c4w2, c4w3}
            r == byte_10 -> {s, c0, c4, c8, c10 + 1, c4w0, c4w1, c4w2, c4w3}
            r < intermediate_lo -> {s, c0, c4, c8, c10, c4w0, c4w1, c4w2, c4w3}
            r < 252 -> {s + intermediate_g(r, p), c0, c4, c8, c10, c4w0, c4w1, c4w2, c4w3}
            r == 252 -> {s, c0, c4, c8, c10, c4w0 + 1, c4w1, c4w2, c4w3}
            r == 253 -> {s, c0, c4, c8, c10, c4w0, c4w1 + 1, c4w2, c4w3}
            r == 254 -> {s, c0, c4, c8, c10, c4w0, c4w1, c4w2 + 1, c4w3}
            true -> {s, c0, c4, c8, c10, c4w0, c4w1, c4w2, c4w3 + 1}
          end
      end

    if c0 == m do
      # Empty sketch. Algorithm 6 would route through small-range with
      # z = 1 and σ(1) = +∞, then collapse to 0 via λₚ · ∞^(-1/τ). The
      # BEAM has no IEEE infinity literal, so short-circuit here.
      0.0
    else
      s =
        if c0 + c4 + c8 + c10 > 0 do
          s + small_range_contribution(c0, c4, c8, c10, m)
        else
          s
        end

      s =
        if c4w0 + c4w1 + c4w2 + c4w3 > 0 do
          s + large_range_contribution(c4w0, c4w1, c4w2, c4w3, m, w)
        else
          s
        end

      # Algorithm 6 line 979: return λₚ · s^(-1/τ), see (12).
      lambda_p(m) * :math.pow(s, @minus_inv_tau)
    end
  end

  # ---------------------------------------------------------------------
  # Intermediate-range register contribution g(byte), per (15) lifted
  # into shifted-byte coordinates:
  #
  #     g(byte) = 2^(-τ · ⌊paper_r / 4⌋) · η_{paper_r mod 4}
  #             = 2^(-τ · (byte/4 − p + 2)) · η_{byte mod 4}
  #
  # since paper_r = byte − 4p + 8 and (byte − 4p + 8) mod 4 = byte mod 4.

  defp intermediate_g(byte, p) do
    u = (byte >>> 2) - p + 2
    :math.pow(2.0, -@tau * u) * eta_mod4(byte &&& 0x3)
  end

  defp eta_mod4(0), do: @eta_0
  defp eta_mod4(1), do: @eta_1
  defp eta_mod4(2), do: @eta_2
  defp eta_mod4(3), do: @eta_3

  # Algorithm 6 caption: λₚ := m^(1+1/τ) / (1 + (1+τ)v / (2m)).
  defp lambda_p(m) do
    :math.pow(m, 1.0 + 1.0 / @tau) / (1.0 + (1.0 + @tau) * @v / (2.0 * m))
  end

  # ---------------------------------------------------------------------
  # Small-range correction. Algorithm 6 lines 953–964; eq. (23) for z;
  # eq. (18) cases r ∈ {0, 4, 8, 10}.

  defp small_range_contribution(c0, c4, c8, c10, m) do
    alpha = m + 3 * (c0 + c4 + c8 + c10)
    beta = m - c0 - c4
    gamma = 4 * c0 + 2 * c4 + 3 * c8 + c10

    # z := ((√(β² + 4αγ) − β) / (2α))⁴ — eq. (23)
    quad_root_z = (:math.sqrt(beta * beta + 4 * alpha * gamma) - beta) / (2 * alpha)
    root_z = quad_root_z * quad_root_z
    z = root_z * root_z

    s = if c0 > 0, do: c0 * sigma(z), else: 0.0
    s = if c4 > 0, do: s + c4 * @two_pow_minus_tau * psi(z), else: s
    s = if c8 > 0, do: s + c8 * @four_pow_minus_tau * (z * (@eta_0 - @eta_1) + @eta_1), else: s
    if c10 > 0, do: s + c10 * @four_pow_minus_tau * (z * @eta_2_minus_3 + @eta_3), else: s
  end

  # Eq. (19): ψ(z) := z(z(z(η₀−η₁−η₂+η₃) + (η₂−η₃)) + (η₁−η₃)) + η₃.
  # Horner form to avoid recomputing powers of z.
  defp psi(z) do
    z * (z * (z * @eta_x + @eta_2_minus_3) + @eta_1_minus_3) + @eta_3
  end

  # Eq. (20): σ(z) := (1/z) Σ_{u≥0} 2^(τu) · (z^(2^u) − z^(2^(u+1))) · ψ(z^(2^(u+1))).
  # Paper §3.4 (line 774) guarantees double-precision convergence in
  # ≤ p+7 terms for any p ∈ [3, 26]; the loop terminates as soon as
  # the partial sum stops growing. Argument range from eq. (23): z ∈ [0, 1].
  defp sigma(z) when z > 0.0 and z < 1.0 do
    pow_z = z
    next_pow_z = pow_z * pow_z
    sigma_loop(z, pow_z, next_pow_z, 0.0, 1.0)
  end

  # Iteration u contributes 2^(τu) · (z^(2^u) − z^(2^(u+1))) · ψ(z^(2^(u+1))).
  # `pow_2_tau_u` carries the running 2^(τu) factor (× 2^τ per iter).
  defp sigma_loop(z, pow_z, next_pow_z, s, pow_2_tau_u) do
    new_s = s + pow_2_tau_u * (pow_z - next_pow_z) * psi(next_pow_z)

    if new_s > s do
      sigma_loop(z, next_pow_z, next_pow_z * next_pow_z, new_s, pow_2_tau_u * @two_pow_tau)
    else
      new_s / z
    end
  end

  # ---------------------------------------------------------------------
  # Large-range correction. Algorithm 6 lines 965–978; eq. (24) for z;
  # eq. (18) trailing branch for r ∈ {4w, 4w+1, 4w+2, 4w+3}.

  defp large_range_contribution(c4w0, c4w1, c4w2, c4w3, m, w) do
    c_total = c4w0 + c4w1 + c4w2 + c4w3

    # z := √((√(β² + 4αγ) − β) / (2α)) — eq. (24)
    alpha = m + 3 * c_total
    beta = c4w0 + c4w1 + 2 * (c4w2 + c4w3)
    gamma = m + 2 * c4w0 + c4w2 - c4w3
    z = :math.sqrt((:math.sqrt(beta * beta + 4 * alpha * gamma) - beta) / (2 * alpha))

    z_prime = :math.sqrt(z)

    s_prime =
      z * (1.0 + z_prime) * (@eta_0 * c4w0 + @eta_1 * c4w1 + @eta_2 * c4w2 + @eta_3 * c4w3) +
        @two_pow_minus_tau * z_prime * (z * (@eta_0 - @eta_2) + @eta_2) * (c4w0 + c4w1) +
        @two_pow_minus_tau * z_prime * (z * @eta_1_minus_3 + @eta_3) * (c4w2 + c4w3) +
        phi(z_prime) * c_total

    s_prime / (:math.pow(2.0, @tau * w) * (1.0 + z_prime) * (1.0 + z))
  end

  # Eq. (21) — second (numerically stable) form. We mirror Hash4j's
  # `phi` (UltraLogLog.java v0.17.0 lines 836–856), which uses the
  # `psi'(z, z²) = ψ(z) / η_X` factorization to avoid re-evaluating
  # constants inside the loop. Algebraically identical to the paper.
  # Convergence ≤ 22 terms for any p ∈ [3, 26] (paper line 786).
  defp phi(z) when z <= 0.0, do: 0.0
  defp phi(z) when z >= 1.0, do: @phi_one

  defp phi(z) do
    z_square = z * z
    pow_z = z
    next_pow_z = :math.sqrt(pow_z)
    p_factor = @phi_p_initial / (1.0 + next_pow_z)
    ps = psi_prime(pow_z, z_square)
    s = next_pow_z * (ps + ps) * p_factor
    phi_loop(pow_z, next_pow_z, s, p_factor, ps)
  end

  # State at loop entry: `pow_z = z^(1/2^(iter−1))`,
  #                      `next_pow_z = z^(1/2^iter)`,
  #                      `ps = psi_prime(pow_z, pow_z²) = ψ(pow_z) / η_X`.
  # We advance `previous := pow_z`, `pow_z := next_pow_z`, recompute
  # `next_pow_z := √pow_z`, then add the iter contribution.
  defp phi_loop(pow_z, next_pow_z, s, p_factor, ps) do
    new_previous = pow_z
    new_pow_z = next_pow_z
    new_next_pow_z = :math.sqrt(new_pow_z)
    new_ps = psi_prime(new_pow_z, new_previous)
    new_p_factor = p_factor * @two_pow_minus_tau / (1.0 + new_next_pow_z)

    new_s =
      s +
        new_next_pow_z *
          (new_ps + new_ps - (new_pow_z + new_next_pow_z) * ps) *
          new_p_factor

    if new_s > s do
      phi_loop(new_pow_z, new_next_pow_z, new_s, new_p_factor, new_ps)
    else
      new_s
    end
  end

  defp psi_prime(z, z_square) do
    (z + @psi_prime_eta23x) * (z_square + @psi_prime_eta13x) + @psi_prime_eta3012xx
  end
end
