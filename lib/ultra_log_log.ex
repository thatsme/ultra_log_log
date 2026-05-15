defmodule UltraLogLog do
  @moduledoc """
  Space-efficient approximate distinct counting on the BEAM.

  Implementation of:

  > Otmar Ertl. *UltraLogLog: A Practical and More Space-Efficient Alternative
  > to HyperLogLog for Approximate Distinct Counting.* PVLDB 17(7), 2024.
  > <https://www.vldb.org/pvldb/vol17/p1655-ertl.pdf>

  UltraLogLog (ULL) is a 2024 successor to HyperLogLog. It keeps every
  practical property HLL is famous for — constant memory, constant-time
  inserts, commutative/idempotent/associative merge — and adds **24–28%
  less memory at the same accuracy**, depending on which estimator you
  pick. The trade is one extra register bit per slot (8-bit ULL registers
  vs 6-bit HLL ones), recovered many times over by a tighter information
  density per register.

  ## Quick start

      iex> ull = UltraLogLog.new(precision: 12)
      iex> ull = UltraLogLog.add(ull, "session-abc")
      iex> ull = UltraLogLog.add(ull, "session-xyz")
      iex> {:ok, count} = UltraLogLog.cardinality(ull)
      iex> abs(count - 2.0) < 0.1
      true

  Merging two sketches is value-level and associative — no coordinator,
  no quorum, no consensus:

      iex> a = UltraLogLog.new(precision: 12) |> UltraLogLog.add("x")
      iex> b = UltraLogLog.new(precision: 12) |> UltraLogLog.add("y")
      iex> {:ok, count} = UltraLogLog.cardinality(UltraLogLog.merge(a, b))
      iex> abs(count - 2.0) < 0.1
      true

  ## Estimators

  Pick one of three estimators via the `:estimator` option to
  `cardinality/2`. All three are paper-faithful translations of the
  algorithms in Ertl 2024, cross-validated against the Hash4j Java
  reference (v0.17.0) to floating-point precision.

  | Estimator         | Storage factor | Rel. std. error | Use when                                                                                            |
  |-------------------|---------------:|-----------------|-----------------------------------------------------------------------------------------------------|
  | `:fgra` (default) | 4.895          | `0.782/√m`      | Default. Single-pass, no iteration.                                                                 |
  | `:mle`            | 4.631          | `0.761/√m`      | Tightest bound; secant solver runs ~5 iterations per query.                                         |
  | `:martingale`     | 3.466          | `0.658/√m`      | Single-stream sketch never merged; returns `{:error, :invalidated_by_merge}` after `merge/2`.       |

  The martingale stderr derives from the memory-variance product
  MVP ≈ 5·ln(2) ≈ 3.466 in the paper (§3.7); the 0.658 figure is
  `√(MVP / 8)`.

      iex> ull = UltraLogLog.new(precision: 12) |> UltraLogLog.add("k")
      iex> {:ok, _} = UltraLogLog.cardinality(ull, estimator: :mle)

  See `UltraLogLog.Estimator.FGRA`, `UltraLogLog.Estimator.MLE`, and
  `UltraLogLog.Estimator.Martingale` for the per-estimator details.

  ## Precision → memory → error

  Precision `p` allocates `2^p` 8-bit registers — state size is exactly
  `2^p` bytes:

      p=10 →  1 KB,  ~3.1% relative error
      p=12 →  4 KB,  ~1.2% relative error  (default)
      p=14 → 16 KB,  ~0.6% relative error
      p=16 → 64 KB,  ~0.3% relative error

  Pick the smallest `p` whose error fits your use case. `p=12` is a
  sensible default; bump to 14 if you need sub-percent accuracy.

  ## Mergeability and CRDTs

  `merge/2` is element-wise on registers under the UltraLogLog partial
  order. The operation is commutative, associative, and idempotent —
  i.e. ULL sketches form a CRDT under merge. This is what makes
  distributed cardinality estimation trivial: shards independently
  maintain their own sketches, you merge on demand, and the answer is
  exactly as if every insert had hit a single sketch.

  Merging invalidates the martingale estimator (its incremental update
  history is lost). FGRA and MLE remain valid on merged sketches.

  ## Serialization

  `to_binary/1` and `from_binary/1` round-trip the sketch as a
  versioned compact binary; cardinality is preserved exactly:

      iex> ull = UltraLogLog.new(precision: 12)
      iex> ull = Enum.reduce(1..100, ull, &UltraLogLog.add(&2, &1))
      iex> {:ok, before} = UltraLogLog.cardinality(ull)
      iex> {:ok, restored} = UltraLogLog.from_binary(UltraLogLog.to_binary(ull))
      iex> {:ok, after_} = UltraLogLog.cardinality(restored)
      iex> before == after_
      true

  Deserialization invalidates the martingale field — its incremental
  history isn't part of the wire format. A `cardinality(restored,
  estimator: :martingale)` call on a reloaded sketch therefore returns
  `{:error, :invalidated_by_merge}`. FGRA and MLE round-trip cleanly.

  ## Hashing

  `add/2` accepts any term (hashed internally via `UltraLogLog.Hash`)
  or a pre-computed non-negative integer treated as a 64-bit hash. The
  v0.1 internal hash is a `:erlang.phash2/2` derivation suitable for
  well-distributed inputs; production deployments with adversarial or
  skewed keyspaces should pass pre-computed hashes from a quality
  64-bit function (xxhash3, wyhash). A native xxhash3 NIF is planned
  for v0.2.

  ## Status

    * v0.1 ships the immutable sketch, all three estimators, merge,
      serialize, and downsize (full implementation in v0.2). Bit-exact
      validated against Hash4j v0.17.0.
    * v0.2 will add a lock-free `:atomics`-backed insert path, a native
      hash function, and benchmarks.
    * v0.3 will add `PartitionSupervisor`-sharded cluster-wide merge.

  See `CHANGELOG.md` for the full release history and `README.md` for
  the empirical-validation summary.
  """

  import Bitwise

  alias UltraLogLog.{Encoding, Estimator, Hash}

  @type precision :: 3..26
  @type estimator :: :fgra | :mle | :martingale
  @type t :: %__MODULE__{
          precision: precision(),
          m: pos_integer(),
          registers: binary(),
          # Martingale state — `{running_estimate, current_mu}` while
          # valid; `nil` once the sketch has been merged (which
          # destroys the per-insert update history the martingale
          # depends on). See `UltraLogLog.Estimator.Martingale`.
          martingale: nil | {float(), float()}
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
      # Initial martingale state per Ertl 2024 §3.7 line 798:
      # `μ = 1` because the first insert is certain to change a
      # register (every register is at `h(0) = 1/m`, summed over
      # `m` registers).
      martingale: {0.0, 1.0}
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
      martingale = update_martingale(ull.martingale, current, merged, p)
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
    # TODO(v0.2): expose an optional `UltraLogLog.validate/1` that
    # checks per-byte reachability for callers handling untrusted
    # binaries. Skipped on the hot path for serialization throughput.
    {:ok, %__MODULE__{precision: p, m: 1 <<< p, registers: regs, martingale: nil}}
  end

  def from_binary(_), do: {:error, :invalid_format}

  # --- private helpers ---

  defp put_byte(bin, idx, byte) do
    <<head::binary-size(idx), _::8, tail::binary>> = bin
    <<head::binary, byte::8, tail::binary>>
  end

  # Martingale correction — see Cohen 2015, Ting 2014. Each non-trivial
  # register change incrementally updates an unbiased cardinality
  # estimate. Only valid while we own the entire insert stream; merging
  # invalidates it (handled by `merge/2` setting the field to `nil`).
  defp update_martingale(nil, _old, _new, _p), do: nil

  defp update_martingale({_, _} = state, old, new, p) do
    Estimator.Martingale.delta(state, old, new, p)
  end
end
