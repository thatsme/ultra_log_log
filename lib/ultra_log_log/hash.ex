defmodule UltraLogLog.Hash do
  @moduledoc """
  64-bit hash function for UltraLogLog.

  v0.1 ships with `:erlang.phash2/2` upgraded to 64 bits via concatenation.
  This is **fine for correctness testing but not statistically ideal** for
  production sketches at high precision — `phash2` is not a high-quality
  hash for cardinality estimation.

  ### v0.2 plan

    - Pure-Elixir xxhash3 (slow but no NIF) as fallback.
    - Optional Rustler NIF for xxhash3 / komihash5 (matches Hash4j reference).
    - Pluggable behaviour so callers can pass pre-computed hashes from
      whatever they already use.

  ## Why 64 bits

  UltraLogLog needs 64 bits because:
    - top `p` bits select the register (up to p=26)
    - remaining bits contribute to the geometric leading-zero variable
    - at exa-scale (~10^18 distinct items) 64 bits are exactly what's needed
      to keep collision probability negligible (Heule++ argument)
  """

  @doc """
  Hash a term to a 64-bit unsigned integer.

  Placeholder using two phash2 calls with different seeds. Replace with a
  real 64-bit hash before publishing v0.1 final.
  """
  @spec hash64(term()) :: non_neg_integer()
  def hash64(term) do
    high = :erlang.phash2(term, 1 <<< 32)
    low = :erlang.phash2({:salt, term}, 1 <<< 32)
    Bitwise.bor(Bitwise.bsl(high, 32), low)
  end
end
