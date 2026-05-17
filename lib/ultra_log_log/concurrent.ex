defmodule UltraLogLog.Concurrent do
  @moduledoc """
  Lock-free, `:atomics`-backed concurrent insert path for UltraLogLog.

  This module is the first piece of `ultra_log_log` that does something
  no other UltraLogLog implementation does: a genuinely concurrent
  insert path native to the BEAM, with no GenServer, no lock, and no
  message passing.

  ## When to use this

  Use `UltraLogLog.Concurrent` when many processes need to insert into
  the same sketch concurrently — for example, every request handler in
  a web server feeding a single per-metric sketch. Use the immutable
  `UltraLogLog` when inserts are single-threaded or when you need value
  semantics (snapshots, merges, serialization round-trips).

  The active concurrent structure costs **8× the immutable form** (one
  64-bit `:atomics` cell per register; 128 KB at `p=14` vs the
  immutable form's 16 KB). This is deliberate. Concurrent sketches are
  long-lived shared objects — typically one per metric, not millions —
  and 128 KB of shared state is irrelevant. The alternative of packing
  8 registers per cell was rejected because it creates *logical false
  sharing*: two inserts targeting independent registers would contend
  just because they share a 64-bit word, amplifying contention 8× and
  turning the CAS loop into a bit-twiddling exercise. One cell per
  register keeps the CAS loop clean and provably correct.

  The compact 16 KB serialization form remains available via
  `snapshot/1`, which converts to the immutable `%UltraLogLog{}`.

  ## API

      {:ok, c} = UltraLogLog.Concurrent.new(precision: 12)

      # Lock-free insert — safe to call from ANY process / scheduler
      :ok = UltraLogLog.Concurrent.add(c, "session-abc")
      :ok = UltraLogLog.Concurrent.add(c, pre_computed_hash_integer)

      # Snapshot to the immutable %UltraLogLog{} — for estimation,
      # serialization, merge
      sketch = UltraLogLog.Concurrent.snapshot(c)
      {:ok, count} = UltraLogLog.cardinality(sketch)

  `add/2` returns `:ok` rather than an updated struct — it is a
  side-effecting operation on shared mutable state, not a value
  transformation. This is the deliberate API difference from
  `UltraLogLog.add/2`.

  ## Correctness under concurrency

  Register merge (`UltraLogLog.Encoding.merge_registers/2`) is
  commutative, associative, and idempotent — i.e. a CRDT join. The
  CAS loop in `add/2` only ever applies `merge_registers` to the
  observed cell value, so the concurrent result is **order-independent
  by construction**: a concurrent sketch built by N processes
  inserting in parallel is identical, byte-for-byte, to an immutable
  sketch built by inserting the same elements serially, for any
  interleaving. See `test/concurrent_test.exs` for the
  equivalence-under-contention proof.

  ## Memory model

  `:atomics` operations are sequentially consistent. Synchronization
  between writers and a subsequent `snapshot/1` is provided by the
  usual BEAM mechanisms — typically `Task.await/2` or `Task.await_many/2`
  after writer tasks complete establishes happens-before between the
  last CAS and the snapshot.
  """

  import Bitwise

  alias UltraLogLog.{Encoding, Hash}

  @opaque t :: %__MODULE__{
            ref: :atomics.atomics_ref(),
            precision: UltraLogLog.precision(),
            m: pos_integer()
          }

  defstruct [:ref, :precision, :m]

  @default_precision 12

  @doc """
  Create a new empty concurrent sketch.

  ## Options

    * `:precision` — `3..26`, default `#{@default_precision}`. State size
      is `8 · 2^precision` bytes for the active structure (one 64-bit
      `:atomics` cell per register). The compact `snapshot/1` form
      remains `2^precision` bytes.

  Returns `{:ok, struct}`.
  """
  @spec new(keyword()) :: {:ok, t()}
  def new(opts \\ []) do
    p = Keyword.get(opts, :precision, @default_precision)

    unless is_integer(p) and p >= 3 and p <= 26 do
      raise ArgumentError, "precision must be an integer in 3..26, got: #{inspect(p)}"
    end

    m = 1 <<< p

    # `signed: false` is deliberate. Register values are unsigned bytes
    # (0..255); OTP's `:atomics` default is `signed: true`. Unsigned
    # matches the domain and avoids any sign-extension confusion.
    ref = :atomics.new(m, signed: false)

    {:ok, %__MODULE__{ref: ref, precision: p, m: m}}
  end

  @doc """
  Insert a value into the sketch.

  Accepts any term (hashed internally via `UltraLogLog.Hash`) or a
  pre-computed 64-bit unsigned hash — same contract as
  `UltraLogLog.add/2`. Returns `:ok`.

  Safe to call from any process / scheduler concurrently. The insert
  path is a lock-free CAS loop on a single `:atomics` cell.
  """
  @spec add(t(), term() | non_neg_integer()) :: :ok
  def add(%__MODULE__{} = c, hash) when is_integer(hash) and hash >= 0 do
    do_add(c, hash)
  end

  def add(%__MODULE__{} = c, term) do
    do_add(c, Hash.hash64(term))
  end

  defp do_add(%__MODULE__{ref: ref, precision: p}, hash) do
    # Same bit slicing as `UltraLogLog.add/2`:
    #   top p bits → register index (0..m-1)
    #   remaining bits → encoded register value per Ertl 2024 §3
    idx0 = hash >>> (64 - p)
    tail = hash <<< p &&& 0xFFFFFFFFFFFFFFFF
    encval = Encoding.encode(tail, p)

    # `:atomics` indices are 1-based; encoding/binary indices are
    # 0-based. The +1 lives here and in `snapshot/1` — nowhere else.
    idx1 = idx0 + 1
    cas_loop(ref, idx1, encval, :atomics.get(ref, idx1))
  end

  # Lock-free insert loop.
  #
  # `:atomics.compare_exchange/4` returns `:ok` on success, or the
  # actual cell value on failure. We feed that value straight back as
  # the new `current` and re-merge — no extra `:atomics.get` after a
  # failed CAS.
  #
  # Termination: `merge_registers/2` is monotone in the UltraLogLog
  # partial order, so a failed CAS implies another writer raised the
  # cell strictly higher. The reachable byte set per precision is
  # finite (≤ ~252 values), so the loop is bounded. In practice
  # retries are vanishingly rare (~1/m contention probability per
  # insert; ~0.006% at p=14).
  defp cas_loop(ref, idx1, encval, current) do
    case Encoding.merge_registers(current, encval) do
      ^current ->
        # The observed cell already dominates `encval` (or equals it
        # under the merge). No write needed.
        :ok

      merged ->
        case :atomics.compare_exchange(ref, idx1, current, merged) do
          :ok -> :ok
          actual -> cas_loop(ref, idx1, encval, actual)
        end
    end
  end

  @doc """
  Convert the concurrent sketch to an immutable `%UltraLogLog{}` for
  estimation, serialization, or merge.

  ## Snapshot semantics

  `snapshot/1` reads each `:atomics` cell independently. It is
  therefore **not a globally atomic snapshot**: if writers are active
  during the snapshot, different cells may reflect different moments
  in time.

  This is safe by construction. Register merge is monotone in the
  UltraLogLog partial order, so a "torn" snapshot is always a valid
  intermediate sketch — never an invalid one — and its cardinality
  estimate is a legitimate estimate of a state the sketch genuinely
  passed through.

  For a globally consistent snapshot, quiesce writers first (e.g.
  `Task.await_many/2` on all insert tasks, as the test suite does).

  ## Martingale

  The returned `%UltraLogLog{}` has `martingale: nil`. The martingale
  estimator requires the per-insert update history (Ertl 2024 §3.7,
  Algorithm 2), which a concurrent sketch does not maintain.
  `UltraLogLog.cardinality(snap, estimator: :martingale)` therefore
  returns `{:error, :invalidated_by_merge}` on a snapshot. The FGRA
  and MLE estimators work normally.
  """
  @spec snapshot(t()) :: UltraLogLog.t()
  def snapshot(%__MODULE__{ref: ref, precision: p, m: m}) do
    # 0-based iteration; +1 conversion at the `:atomics.get` boundary
    # (mirrors `add/2`). Build via list then `:binary.list_to_bin/1`
    # for unambiguous O(m) — independent of the compiler's binary
    # append-mode optimization.
    bytes = for idx0 <- 0..(m - 1), do: :atomics.get(ref, idx0 + 1)
    registers = :binary.list_to_bin(bytes)

    %UltraLogLog{precision: p, m: m, registers: registers, martingale: nil}
  end
end
