defmodule UltraLogLog.Estimator.Martingale do
  @moduledoc """
  Martingale (Historic Inverse Probability) estimator for UltraLogLog.

  Asymptotic storage factor `5·ln(2) ≈ 3.466` (Ertl 2024 §3.7 line 845,
  via paper eq. 26 with `b=2, d=2, q=6` → MVP ≈ 3.4657), relative
  standard error ≈ `0.658/√m` (= `√(MVP/8m)`). This is the **lowest
  variance** estimator ULL admits — but at a critical cost:

  > It is only valid for sketches that have **never been merged**.

  The estimate is maintained incrementally on every successful insert
  (Algorithm 2 in the paper). Merging two sketches loses the per-element
  update history needed to keep the martingale unbiased, so any
  `UltraLogLog.merge/2` call invalidates the running martingale state.
  After invalidation, `UltraLogLog.cardinality/2` with
  `estimator: :martingale` returns `{:error, :invalidated_by_merge}`.

  ## Algorithm 2 (paper p. 1664)

      n̂_martingale ← n̂_martingale + 1/μ        ⊳ update estimate
      μ ← μ − h(r) + h(r')                       ⊳ state-change prob

  with `μ := Σᵢ h(rᵢ)` initially equal to `1` (every register is at the
  smallest possible state, `h(0) = 1/m`, summed over `m` registers).
  The increment of `1/μ` runs **before** the μ update — the next insert
  sees the post-update μ.

  ## h(r) — per-register state-change probability (paper eq. 25)

  Special cases on the four smallest paper-r values:

      h(0)  = 1/m
      h(4)  = 1/(2m)
      h(8)  = 3/(4m)
      h(10) = 1/(4m)

  Intermediate range for `r = 4u + ⟨l₁l₂⟩₂`, `3 ≤ u < w`:

      h(r) = (7 − 2·l₁ − 4·l₂) / (2^u · m)

  Saturated range for `r = 4w + ⟨l₁l₂⟩₂`:

      h(r) = (3 − l₁ − 2·l₂) / (2^(w−1) · m)

  These four cases collapse into **one** branch-free integer expression
  (`h_scaled/2` below) that mirrors Hash4j v0.17.0's
  `UltraLogLog.getScaledRegisterChangeProbability` and exploits
  integer-truncation `>>> p` as a free divide-by-2 for the saturated
  range. Algebraically verified against the paper for every special
  case in the moduledoc tests.

  ## State shape

  The `martingale` field of `%UltraLogLog{}` carries a tuple
  `{estimate :: float(), mu :: float()}` for active sketches and `nil`
  for merge-invalidated ones. Initial value at `UltraLogLog.new/1` is
  `{0.0, 1.0}` — the empty sketch has cardinality 0 and every register
  is fully changeable.
  """

  import Bitwise

  @typedoc "Active martingale state: `{running_estimate, current_μ}`."
  @type state :: {float(), float()}

  # If μ drifts to (or below) zero due to numerical accumulation, the
  # sketch is effectively saturated: every insert that lands in a
  # full register is no longer informative. We freeze μ at 0 and
  # return a large finite estimate on the next call (no IEEE infinity
  # literal on BEAM). Mirrors Hash4j MartingaleEstimator.stateChanged
  # lines 126–129 ("set to zero in this case → next state change will
  # set estimate = infinite").
  @saturated_sentinel 1.0e308

  @doc """
  Return the current martingale estimate.

  Returns `{:ok, value}` for active (un-merged) sketches and
  `{:error, :invalidated_by_merge}` for sketches whose martingale
  state was nullified by `UltraLogLog.merge/2`.
  """
  @spec estimate(UltraLogLog.t()) ::
          {:ok, float()} | {:error, :invalidated_by_merge}
  def estimate(%UltraLogLog{martingale: nil}), do: {:error, :invalidated_by_merge}
  def estimate(%UltraLogLog{martingale: {estimate, _mu}}), do: {:ok, estimate}

  @doc """
  Update the running estimate after a single register transition.

  Called from `UltraLogLog.add/2` only when an insert actually changes
  a register byte (no-op inserts do not call this — see paper
  Algorithm 2's `r < r'` precondition).

  Returns the new `{estimate, μ}` pair.
  """
  @spec delta(state(), 0..255, 0..255, UltraLogLog.precision()) :: state()
  def delta({estimate, mu}, _old_reg, _new_reg, _p) when mu <= 0.0 do
    # Saturated; further inserts can't refine the estimate. Pin to
    # the large-finite sentinel and freeze μ at zero.
    {max(estimate, @saturated_sentinel), 0.0}
  end

  def delta({estimate, mu}, old_reg, new_reg, p) do
    # Paper Algorithm 2: update estimate FIRST (using pre-update μ),
    # then advance μ by the probability differential.
    new_estimate = estimate + 1.0 / mu
    new_mu = mu - h(old_reg, p) + h(new_reg, p)

    # Numerical guard. Theoretically μ stays in [0, 1] and h(new) <
    # h(old) whenever a register strictly grows (so new_mu < mu).
    # Floating-point rounding can drive new_mu just past zero on the
    # last reachable transition; clamp to keep the next delta call
    # well-defined.
    new_mu = if new_mu < 0.0, do: 0.0, else: new_mu
    {new_estimate, new_mu}
  end

  @doc false
  # Per-register state-change probability, as a float in [0, 1].
  # Exposed (private to the test suite via direct module-call) so the
  # paper's eq. (25) special values can be unit-checked.
  @spec h(0..255, UltraLogLog.precision()) :: float()
  def h(reg, p), do: h_scaled(reg, p) / 0x1_0000_0000_0000_0000

  # Port of Hash4j v0.17.0 `UltraLogLog.getScaledRegisterChangeProbability`
  # (lines 362–366). Returns h(reg, p) scaled by 2^64 as a 64-bit
  # unsigned integer. The "trick" — exploited at the saturated range —
  # is that Java's `(num << shift) >>> p` truncates fractional bits for
  # bytes 252..255, yielding the paper's eq. (25) saturated numerators
  # `{3, 2, 1, 0}` from the same unified expression that produces the
  # intermediate-range probabilities.
  defp h_scaled(0, p), do: 1 <<< (64 - p)

  defp h_scaled(reg, p) do
    # k = paper_u − 1 in shifted-byte coordinates. paper_u = (byte/4) − p + 2.
    k = 1 - p + (reg >>> 2)

    # Numerator in {7, 5, 3, 1} for (l₁, l₂) = (0,0), (1,0), (0,1), (1,1).
    # Matches paper intermediate formula `7 − 2·l₁ − 4·l₂` directly;
    # for the saturated range, integer truncation of `<< (p-1) >>> p`
    # halves the value to paper's saturated numerators `{3, 2, 1, 0}`.
    num_2l1_4l2 = (reg &&& 2) ||| (reg &&& 1) <<< 2
    num = bxor(num_2l1_4l2, 7)

    # Java `<< ~k` is `<< (-k-1)`, with the shift count masked to 6
    # bits. We emulate the masked shift by an explicit `&&& 0x3F`.
    shift_left = -k - 1 &&& 0x3F
    shifted = num <<< shift_left &&& 0xFFFF_FFFF_FFFF_FFFF
    shifted >>> p
  end
end
