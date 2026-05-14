defmodule UltraLogLog.Encoding do
  @moduledoc """
  Register encoding and merge operations for UltraLogLog.

  ## Algorithmic core

  Each 8-bit register byte `r` is interpreted as a 64-bit "hash prefix"
  via `unpack/1`, where:

    * the top 6 bits of `r` encode the position of the leading 1
      (offset and negated, see below),
    * the bottom 2 bits (the `T = d = 2` "extra" bits) encode the two
      bits immediately below that leading 1.

  The implicit leading 1 is reconstructed by ORing the mantissa with `4`
  (binary `100`). `pack/1` inverts the transform, keeping only the
  highest set bit plus the two bits below it.

  The merge of two registers is `pack(unpack(a) ||| unpack(b))`.
  Combining hash prefixes by bitwise OR before re-packing is what makes
  the merge a CRDT operation: commutative, associative, idempotent.

  ## Register normalization (the `+4p - 8` shift)

  Nonzero register values are stored shifted by `+4p - 8` relative to
  the paper's encoding, so the range always saturates at byte `255`
  regardless of precision.

  This is a Hash4j implementation choice, **explicitly acknowledged in
  Ertl 2024 §4 ("Practical Implementation")** in the paragraph following
  Algorithm 4:

  > ULL insertions can be implemented entirely branch-free, as
  > exemplified by the implementation in our Hash4j Java library
  > [...] which however uses the transformation `r → r + 4p − 8` for
  > non-zero registers, so that the largest possible register state is
  > always `(4w + 3) + 4p − 8 = 255`, the maximum value of a byte.

  The paper's own algorithms (Algorithm 3 insert, Algorithm 4 pack,
  Algorithm 5 unpack) do *not* include the shift; without it, register
  values are bounded by `4w + 3 = 263 - 4p`, leaving byte values
  `≥ 264 - 4p` unreachable for any given `p` and wasting byte space.

  The shift is invariant under the full algorithm:

    * `encode/2` applies it implicitly — it falls out of the `pack`
      formula combined with Hash4j's choice of bit position for the
      newly observed update (bit `nlz + p - 1` instead of the paper's
      bit `k + 1`, see `add/2` line citations below).
    * `merge_registers/2` is invariant: `pack(unpack(a) ||| unpack(b))`
      moves to the prefix space where merging is bitwise OR; OR
      distributes over the precision-dependent left-shift that the
      pack/unpack pair effectively performs, so merging shifted bytes
      gives the shifted merge.
    * The estimator absorbs the shift as a constant offset in its
      register-to-table-index mapping (Hash4j's `off = 4p + 4` in
      `OptimalFGRAEstimator`). When we port the estimator, the
      constants will match the shifted encoding by construction.

  ## Reference (Hash4j v0.17.0)

  This module is a bit-exact port of the `pack`/`unpack` helpers and
  the bit-update step in [`UltraLogLog.java`](https://github.com/dynatrace-oss/hash4j/blob/v0.17.0/src/main/java/com/dynatrace/hash4j/distinctcount/UltraLogLog.java)
  at tag **v0.17.0** (commit `95834ea9`), which is the version that
  `dynatrace-research/ultraloglog-paper` pins as a git submodule and
  validates the paper's numerical results against. Specific line
  citations in this module refer to that tag, not main HEAD.

  ## Reachable register values

  Not every value in `0..255` is a possible output of `pack/1`. For
  precision `p`, reachable nonzero bytes have a top-6-bit field that
  encodes a leading-1 position in `{p-1, ..., 63}` (with the shift,
  bytes `< 4p - 4` are unreachable for that `p`). Bytes outside the
  reachable set are never produced by the algorithm; for them,
  `merge_registers/2` remains total — it returns *some* byte, never
  crashes — but the algebraic laws only hold on the reachable subset.
  Property tests should canonicalize via `pack(unpack(_))` (or, more
  directly, generate via uniform 64-bit prefix → `pack/1`) before
  asserting commutativity/associativity/idempotence.
  """

  import Bitwise

  @bit64 0xFFFFFFFFFFFFFFFF

  @doc """
  Encode the result of observing a single hash in an otherwise-empty
  register.

  `tail` is the original 64-bit hash with the top `p` bits (the register
  index) already shifted out — i.e. `tail = (hash <<< p) &&& 0xFFFF_FFFF_FFFF_FFFF`.

  Equivalent to the bit-update step of Hash4j `UltraLogLog.java`
  v0.17.0 lines 245–262 (the body of `add(long, StateChangeObserver)`):

      int nlz = Long.numberOfLeadingZeros(~(~hashValue << -q));
      hashPrefix |= 1L << (nlz + ~q);
      byte newState = pack(hashPrefix);

  with `~q = p - 1` (Java `q = 64 - p`). The leading-zero count
  saturates at `64 - p` for the all-zero tail.
  """
  @spec encode(non_neg_integer(), 3..26) :: 0..255
  def encode(tail, p)
      when is_integer(tail) and tail >= 0 and is_integer(p) and p >= 3 and p <= 26 do
    nlz = min(leading_zeros_64(tail), 64 - p)
    pack(1 <<< (nlz + p - 1))
  end

  @doc """
  Merge two register bytes under the UltraLogLog partial order.

  Defined as `pack(unpack(a) ||| unpack(b))`. Idempotent, commutative,
  and associative on reachable register values; `0` is the identity.
  Total over `0..255` — never raises — but only well-behaved
  algebraically on the reachable subset.

  Ports Hash4j `UltraLogLog.java` v0.17.0 line 301:

      if (otherR != 0) {
        state[i] = pack(unpack(state[i]) | unpack(otherR));
      }
  """
  @spec merge_registers(0..255, 0..255) :: 0..255
  def merge_registers(a, b)
      when is_integer(a) and a >= 0 and a <= 255 and
             is_integer(b) and b >= 0 and b <= 255 do
    case unpack(a) ||| unpack(b) do
      0 -> 0
      combined -> pack(combined)
    end
  end

  @doc """
  Element-wise merge of two register binaries. Both must be the same size.
  """
  @spec merge_binaries(binary(), binary()) :: binary()
  def merge_binaries(<<>>, <<>>), do: <<>>

  def merge_binaries(a, b) when byte_size(a) == byte_size(b) do
    merge_binaries(a, b, <<>>)
  end

  defp merge_binaries(<<a, rest_a::binary>>, <<b, rest_b::binary>>, acc) do
    merge_binaries(rest_a, rest_b, <<acc::binary, merge_registers(a, b)::8>>)
  end

  defp merge_binaries(<<>>, <<>>, acc), do: acc

  @doc """
  Count leading zeros of a 64-bit non-negative integer. Returns 64 if zero.

  Pure-Elixir reference. A NIF using BMI/LZCNT is an obvious v0.2 optimization.
  """
  @spec leading_zeros_64(non_neg_integer()) :: 0..64
  def leading_zeros_64(0), do: 64

  def leading_zeros_64(n) when is_integer(n) and n > 0 do
    leading_zeros_64(n, 0, 0x8000000000000000)
  end

  defp leading_zeros_64(_n, 64, _mask), do: 64
  defp leading_zeros_64(n, acc, mask) when (n &&& mask) != 0, do: acc
  defp leading_zeros_64(n, acc, mask), do: leading_zeros_64(n, acc + 1, mask >>> 1)

  @doc false
  # Hash4j UltraLogLog.java v0.17.0 lines 328–330:
  #
  #     static long unpack(byte register) {
  #       return (4L | (register & 3)) << ((register >>> 2) - 2);
  #     }
  #
  # In Java the `byte` is sign-extended to int before `& 3` and `>>> 2`.
  # `& 3` is unaffected by sign extension. `>>> 2` on a sign-extended
  # negative byte yields a large positive int, but `<<` on a long only
  # uses the low 6 bits of its int shift amount, and for `register` in
  # `0..255` the value of `((register >>> 2) - 2) & 0x3F` collapses to
  # `((register div 4) - 2) & 0x3F` regardless of sign extension —
  # upper bits of the int contribute multiples of 64 and are masked.
  @spec unpack(0..255) :: non_neg_integer()
  def unpack(register) when is_integer(register) and register >= 0 and register <= 255 do
    shift = (register >>> 2) - 2 &&& 0x3F
    mantissa = 4 ||| (register &&& 3)
    mantissa <<< shift &&& @bit64
  end

  @doc false
  # Hash4j UltraLogLog.java v0.17.0 lines 333–336:
  #
  #     static byte pack(long hashPrefix) {
  #       int nlz = Long.numberOfLeadingZeros(hashPrefix) + 1;
  #       return (byte) ((-nlz << 2) | ((hashPrefix << nlz) >>> 62));
  #     }
  #
  # Mask everything to 64 bits to match Java's signed-long wrap-around
  # on overflow. `(-nlz << 2) & 0xFF` matches Java's `(byte) (-nlz << 2)`
  # via the standard two's-complement convention.
  @spec pack(non_neg_integer()) :: 0..255
  def pack(0), do: 0

  def pack(hash_prefix) when is_integer(hash_prefix) and hash_prefix > 0 do
    nlz = leading_zeros_64(hash_prefix &&& @bit64) + 1
    top = -nlz <<< 2 &&& 0xFF
    shift_lo6 = nlz &&& 0x3F
    shifted = hash_prefix <<< shift_lo6 &&& @bit64
    bottom = shifted >>> 62 &&& 0x3
    top ||| bottom
  end
end
