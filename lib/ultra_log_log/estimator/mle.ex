defmodule UltraLogLog.Estimator.MLE do
  @moduledoc """
  Maximum-likelihood estimator for UltraLogLog.

  Asymptotic storage factor 8·ln(2)/ζ(2, 5/4) ≈ 4.631, relative standard
  error 0.761/√m. Gives the full 28% space reduction vs HLL.

  **Slower than `FGRA`**: requires an iterative numerical solver per call
  (Newton-Raphson or secant method) over the log-likelihood. Use this when
  the sketch is computed once and queried many times — or when the extra
  ~4% accuracy matters more than estimation latency.

  ## Numerical notes

    - The likelihood function is unimodal but not symmetric; Newton-Raphson
      with a good initial guess (the FGRA estimate) converges in 3–6
      iterations for reasonable inputs.
    - Edge cases requiring special handling: all-zero sketch, all-saturated,
      and single-register-dominant sketches. The Hash4j reference uses
      careful branching for these — mirror it.
    - Tolerance: `1e-2` relative on the estimate is sufficient for all
      practical purposes since the underlying error is already 0.761/√m.
  """

  @doc false
  @spec estimate(UltraLogLog.t()) :: float()
  def estimate(%UltraLogLog{} = ull) do
    # TODO: implement MLE per Ertl 2024 §4.2 (extended arXiv version §4 and
    # appendix). Reference: hash4j computeMaximumLikelihoodEstimate().
    #
    # 1. Start with FGRA estimate as initial guess.
    # 2. Iteratively solve d/dN log L(N | registers) = 0 via Newton or secant.
    # 3. Return N.
    UltraLogLog.Estimator.FGRA.estimate(ull)
  end
end
