defmodule UltraLogLog.Estimator.Martingale do
  @moduledoc """
  Martingale (Historic Inverse Probability) estimator for UltraLogLog.

  Asymptotic storage factor 5·ln(2) ≈ 3.466. This is the **best** estimator
  but with a critical restriction:

  > It is only valid for sketches that have **never been merged**.
  >
  > Specifically: the estimate is maintained incrementally during inserts;
  > merging two sketches loses the information needed to keep the martingale
  > unbiased.

  Cohen (2015), Ting (2014). Same trick `HyperLogLog++`'s HIP uses.

  ## Usage

  When the sketch is built from a single stream and queried without merging,
  this estimator gives the tightest bound for any given memory budget.
  Common case: per-process / per-shard counters that are eventually exported
  but not combined.

  After any merge, `UltraLogLog.cardinality/2` with `estimator: :martingale`
  will return `{:error, :invalidated_by_merge}`.
  """

  @doc false
  @spec estimate(UltraLogLog.t()) ::
          {:ok, float()} | {:error, :invalidated_by_merge}
  def estimate(%UltraLogLog{martingale: nil}), do: {:error, :invalidated_by_merge}
  def estimate(%UltraLogLog{martingale: m}) when is_float(m), do: {:ok, m}

  @doc """
  Incremental martingale update — called from `UltraLogLog.add/2` whenever
  a register changes.

  Returns the new running estimate.
  """
  @spec delta(float(), 0..255, 0..255, pos_integer()) :: float()
  def delta(current, _old_value, _new_value, _m) do
    # TODO: implement HIP-style martingale update for ULL registers.
    # The increment is roughly 1 / P(this register change happens given
    # the current sketch state), which for HLL is well-known and for ULL
    # follows from §4.3 of the extended paper.
    current
  end
end
