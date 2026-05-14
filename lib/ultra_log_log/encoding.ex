defmodule UltraLogLog.Encoding do
  @moduledoc """
  Register encoding and merge operations for UltraLogLog.

  ## Algorithmic core

  This module implements the per-register encoding scheme from Ertl 2024
  (VLDB) §3, plus the merge operation that defines the partial order on
  register values.

  Unlike HyperLogLog — where a register stores just `NLZ + 1` and merge is
  `max` — UltraLogLog packs more information per register by encoding the
  leading-zero run *together with the next few bits* into 8 bits. The merge
  operation is therefore not a plain `max`: it picks the register value with
  the most information content, where ties are broken in a defined way.

  ## Reference implementation

  The encoding and update logic ports the static helpers in
  [`UltraLogLog.java`](https://github.com/dynatrace-oss/hash4j/blob/main/src/main/java/com/dynatrace/hash4j/distinctcount/UltraLogLog.java)
  from the `hash4j` library. Test vectors generated from the Java code are
  used as ground truth — see `test/reference_vectors_test.exs`.

  ## Why a separate module

  Isolating the bit-twiddling and partial order in one place makes:

    - The hot path easy to micro-benchmark and (eventually) NIF-ify.
    - Property tests easy to write: idempotence, commutativity, associativity
      of `merge_registers/2` are checked in isolation from the estimator.
    - The implementation auditable against the paper without scrolling
      through GenServer plumbing.
  """

  import Bitwise

  @doc """
  Encode the tail bits of a hash into an 8-bit register value, given the
  current precision `p`.

  The `tail` argument is the 64-bit hash with the top `p` bits already
  consumed (left-shifted into position so the next leading zero counts the
  geometric variable).
  """
  @spec encode(non_neg_integer(), 3..26) :: 0..255
  def encode(tail, _p) when is_integer(tail) and tail >= 0 do
    # TODO: port from Hash4j UltraLogLog.java
    #
    # The encoded register value packs:
    #   - `nlz`: number of leading zeros of `tail` (a geometric r.v.)
    #   - `extra`: the next few bits after the leading-1, used as a fractional
    #     refinement of the geometric estimate
    #
    # Hash4j stores this as `((nlz + 1) << T) | extra_bits_masked`
    # where T is a small constant (2 in the default config) and the bottom T
    # bits of the byte encode `extra`.
    #
    # See: hash4j src/main/java/com/dynatrace/hash4j/distinctcount/UltraLogLog.java
    # function: `pack` and the `add` insert path.
    #
    # For the v0.1 skeleton, return a placeholder so tests at least compile:
    nlz = leading_zeros_64(tail)
    min(nlz + 1, 255)
  end

  @doc """
  Merge two encoded register values per UltraLogLog semantics.

  This is the operation that makes ULL a CRDT: it is **commutative**,
  **associative**, and **idempotent**. For the default encoding it reduces
  to `max/2`, but the comment is here because the *general* form (variable T)
  is not a plain max, and we want to be explicit.
  """
  @spec merge_registers(0..255, 0..255) :: 0..255
  def merge_registers(a, b) when is_integer(a) and is_integer(b) do
    # TODO: implement the proper ULL partial order. For T=0 (no extra bits)
    # this is just max. For T>0 we need to compare the "leading zeros" portion
    # first, then break ties on the extra bits. See Hash4j `update`.
    max(a, b)
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
end
