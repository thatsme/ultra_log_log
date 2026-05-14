defmodule UltraLogLog do
  @moduledoc """
  UltraLogLog: a space-efficient probabilistic data structure for approximate
  distinct counting.

  This is a BEAM-native implementation of the algorithm described in:

  > Otmar Ertl. *UltraLogLog: A Practical and More Space-Efficient Alternative
  > to HyperLogLog for Approximate Distinct Counting.* PVLDB 17(7), 2024.
  > https://www.vldb.org/pvldb/vol17/p1655-ertl.pdf

  ## Why UltraLogLog over HyperLogLog?

  UltraLogLog (ULL) shares all the practical properties of HyperLogLog — it is
  commutative, idempotent, mergeable, and has constant-time inserts — but
  requires roughly **24–28% less space** for the same accuracy depending on
  estimator choice.

  ULL uses **8-bit registers** (vs HLL's 6-bit packed), which trades a small
  amount of raw space for byte-aligned access. On the BEAM this is a big win:
  registers map directly to plain binaries, no bit-packing math on the hot path.
  Wire-format compression (zstd/gzip) recovers the apparent overhead because
  the entropy of ULL's register distribution is favourable.

  ## Three estimators, three tradeoffs

  | Estimator      | Storage factor | Rel. std. error | Notes                       |
  |----------------|----------------|-----------------|-----------------------------|
  | `:fgra` (def.) | 4.895          | 0.782/√m        | Fast, comparable to HLL     |
  | `:mle`         | 4.631          | 0.761/√m        | 28% less than HLL, slower   |
  | `:martingale`  | 3.466          | best            | Pre-merge only, invalidated |

  ## Basic usage

      iex> ull = UltraLogLog.new(precision: 12)
      iex> ull = UltraLogLog.add(ull, "session-abc")
      iex> ull = UltraLogLog.add(ull, "session-xyz")
      iex> {:ok, count} = UltraLogLog.cardinality(ull)
      iex> count
      2.0

  ## Memory footprint

  Precision `p` produces `2^p` 8-bit registers, so state size is exactly
  `2^p` bytes:

      p=10 →  1 KB,  ~3.1% error
      p=12 →  4 KB,  ~1.2% error
      p=14 → 16 KB,  ~0.6% error
      p=16 → 64 KB,  ~0.3% error

  ## Concurrent inserts

  For high-throughput pipelines, `UltraLogLog.Concurrent` provides a lock-free
  insert path backed by `:atomics`:

      {:ok, ref} = UltraLogLog.Concurrent.new(precision: 14)
      # safe to call from any process / scheduler
      UltraLogLog.Concurrent.add(ref, key)
      snapshot = UltraLogLog.Concurrent.snapshot(ref)
      {:ok, count} = UltraLogLog.cardinality(snapshot)

  ## Cluster-wide aggregation

  `UltraLogLog.Cluster` shards inserts across a `PartitionSupervisor` and
  merges shards (and remote nodes) on demand for a global cardinality estimate.
  """

  alias UltraLogLog.{Encoding, Estimator, Hash}

  @type precision :: 3..26
  @type estimator :: :fgra | :mle | :martingale
  @type t :: %__MODULE__{
          precision: precision(),
          m: pos_integer(),
          registers: binary(),
          # Martingale state — only valid before any merge
          martingale: nil | float()
        }

  defstruct [:precision, :m, :registers, :martingale]

  @default_precision 12

  @doc """
  Create a new empty UltraLogLog sketch.

  ## Options

    * `:precision` — `3..26`, default `#{@default_precision}`. State size is
      `2^precision` bytes.

  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    p = Keyword.get(opts, :precision, @default_precision)

    unless is_integer(p) and p >= 3 and p <= 26 do
      raise ArgumentError, "precision must be an integer in 3..26, got: #{inspect(p)}"
    end

    m = 1 <<< p

    %__MODULE__{
      precision: p,
      m: m,
      registers: :binary.copy(<<0>>, m),
      martingale: 0.0
    }
  end

  @doc """
  Insert a value into the sketch.

  Accepts any term (will be hashed) or a pre-computed 64-bit unsigned hash.
  """
  @spec add(t(), term() | non_neg_integer()) :: t()
  def add(%__MODULE__{} = ull, hash) when is_integer(hash) and hash >= 0 do
    do_add(ull, hash)
  end

  def add(%__MODULE__{} = ull, term) do
    do_add(ull, Hash.hash64(term))
  end

  defp do_add(%__MODULE__{precision: p, registers: regs} = ull, hash) do
    # Top p bits → register index
    # Remaining bits → encoded register value per Ertl §3
    idx = hash >>> (64 - p)
    tail = hash <<< p &&& 0xFFFFFFFFFFFFFFFF
    new_val = Encoding.encode(tail, p)

    current = :binary.at(regs, idx)
    merged = Encoding.merge_registers(current, new_val)

    if merged == current do
      ull
    else
      new_regs = put_byte(regs, idx, merged)
      martingale = update_martingale(ull.martingale, current, merged, ull.m)
      %{ull | registers: new_regs, martingale: martingale}
    end
  end

  @doc """
  Estimate the number of distinct elements added.
  """
  @spec cardinality(t(), keyword()) :: {:ok, float()} | {:error, term()}
  def cardinality(%__MODULE__{} = ull, opts \\ []) do
    case Keyword.get(opts, :estimator, :fgra) do
      :fgra -> {:ok, Estimator.FGRA.estimate(ull)}
      :mle -> {:ok, Estimator.MLE.estimate(ull)}
      :martingale -> Estimator.Martingale.estimate(ull)
      other -> {:error, {:unknown_estimator, other}}
    end
  end

  @doc """
  Merge two sketches. Both must have the same precision.

  Merge is element-wise on registers under the UltraLogLog partial order
  (see `UltraLogLog.Encoding.merge_registers/2`). Result is commutative,
  associative, and idempotent — i.e. a CRDT.

  Note: merging invalidates the martingale estimator on the result.
  """
  @spec merge(t(), t()) :: t()
  def merge(%__MODULE__{precision: p} = a, %__MODULE__{precision: p} = b) do
    merged = Encoding.merge_binaries(a.registers, b.registers)
    %{a | registers: merged, martingale: nil}
  end

  def merge(%__MODULE__{precision: p1}, %__MODULE__{precision: p2}) do
    raise ArgumentError, "cannot merge sketches with different precisions: #{p1} vs #{p2}"
  end

  @doc """
  Merge a list of sketches.
  """
  @spec merge([t(), ...]) :: t()
  def merge([head | tail]), do: Enum.reduce(tail, head, &merge(&2, &1))

  @doc """
  Reduce the precision of a sketch losslessly (in the ULL sense — error grows
  but no information is fabricated).
  """
  @spec downsize(t(), precision()) :: t()
  def downsize(%__MODULE__{precision: p} = ull, target_p)
      when target_p >= 3 and target_p <= p do
    if target_p == p do
      ull
    else
      # TODO: combine groups of 2^(p - target_p) registers per Ertl §5
      raise "downsize not yet implemented"
    end
  end

  @doc """
  Serialize the sketch to a compact binary form.

  Format (v1):

      <<"ULL1", precision::8, registers::binary>>

  """
  @spec to_binary(t()) :: binary()
  def to_binary(%__MODULE__{precision: p, registers: regs}) do
    <<"ULL1", p::8, regs::binary>>
  end

  @doc """
  Deserialize a sketch from its binary form.
  """
  @spec from_binary(binary()) :: {:ok, t()} | {:error, term()}
  def from_binary(<<"ULL1", p::8, regs::binary>>) when byte_size(regs) == 1 <<< p do
    {:ok, %__MODULE__{precision: p, m: 1 <<< p, registers: regs, martingale: nil}}
  end

  def from_binary(_), do: {:error, :invalid_format}

  # --- private helpers ---

  defp put_byte(bin, idx, byte) do
    <<head::binary-size(idx), _::8, tail::binary>> = bin
    <<head::binary, byte::8, tail::binary>>
  end

  # Martingale correction — see Cohen 2015, Ting 2014. Each non-trivial register
  # change incrementally updates an unbiased cardinality estimate. Only valid
  # while we own the entire insert stream; merging invalidates it.
  defp update_martingale(nil, _, _, _), do: nil

  defp update_martingale(_state, _old, _new, _m) do
    # TODO: implement martingale update (Estimator.Martingale.delta/4)
    0.0
  end

  import Bitwise
end
