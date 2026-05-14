defmodule UltraLogLog.Estimator.FGRA do
  @moduledoc """
  Default UltraLogLog estimator — Further Generalized Remaining Area (FGRA),
  Ertl 2024 §4.

  Asymptotic storage factor 4.895, relative standard error 0.782/√m.

  This estimator is the recommended default: it gives ~24% space reduction
  vs HyperLogLog at essentially the same estimation speed (a few floating
  point ops per register, single pass).

  See also `UltraLogLog.Estimator.MLE` for the 28%-reduction option at the
  cost of an iterative solver per estimate call.
  """

  @doc """
  Estimate cardinality from the current sketch state.
  """
  @spec estimate(UltraLogLog.t()) :: float()
  def estimate(%UltraLogLog{registers: regs, m: m}) do
    # TODO: implement FGRA per paper §4.
    #
    # Sketch of algorithm:
    #   1. For each register r_i, compute a contribution f(r_i) based on
    #      the encoded leading-zero value and any extra bits.
    #   2. Sum the contributions: S = Σ f(r_i).
    #   3. Apply the FGRA estimator: τ * m / S, with τ a constant derived
    #      from the encoding parameters (the 4.895 above).
    #   4. Apply small-range correction analogous to HLL++'s linear
    #      counting fallback when many registers are still zero.
    #
    # Reference: hash4j computeEstimate() in UltraLogLog.java
    register_sum =
      for <<r <- regs>>, reduce: 0.0 do
        acc -> acc + register_contribution(r)
      end

    # Placeholder formula — gives nonzero output for smoke tests, NOT correct
    if register_sum == 0.0 do
      0.0
    else
      m * m / register_sum
    end
  end

  # TODO: replace with actual FGRA contribution function
  defp register_contribution(0), do: 1.0
  defp register_contribution(r), do: :math.pow(2.0, -r)
end
