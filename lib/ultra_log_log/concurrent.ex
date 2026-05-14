defmodule UltraLogLog.Concurrent do
  @moduledoc """
  Lock-free UltraLogLog backed by `:atomics`.

  Unlike the immutable `UltraLogLog` struct (where every `add/2` returns a
  new binary), this module exposes a mutable reference safe for use from
  any process or scheduler. Inserts use a CAS loop over the register
  atomics array — no GenServer, no message passing, no copy-on-write.

  ## When to use this

    - High insert rate (10⁵+ per second per BEAM node) with many writer
      processes.
    - Streaming/Broadway pipelines where each processor wants to update a
      shared sketch.
    - Telemetry/observability scenarios where a long-lived sketch is updated
      continuously and queried occasionally.

  ## When to use plain `UltraLogLog` instead

    - The sketch belongs to a single process anyway.
    - You need value semantics (snapshots, history, undo).
    - You're inside a transaction or a GenServer that already serializes
      writes.

  ## Pattern

      {:ok, ref} = UltraLogLog.Concurrent.new(precision: 14)

      Task.async_stream(stream, fn item ->
        UltraLogLog.Concurrent.add(ref, item)
      end, max_concurrency: System.schedulers_online())
      |> Stream.run()

      snapshot = UltraLogLog.Concurrent.snapshot(ref)
      {:ok, count} = UltraLogLog.cardinality(snapshot)

  ## Memory and contention

  Registers are stored in a single `:atomics` array of `m = 2^p` 64-bit
  cells (we waste 56 bits per cell to get lock-free CAS — worth it). At
  p=14 that's 128 KB resident, vs 16 KB for the binary form. Pay this only
  when you actually need concurrent updates.

  Contention is naturally low: the probability of two writers targeting
  the same register is 1/m, which is ≤ 0.006% at p=14. The CAS retry path
  is essentially never taken in practice.
  """

  import Bitwise

  @opaque t :: %__MODULE__{
            precision: UltraLogLog.precision(),
            m: pos_integer(),
            atomics: :atomics.atomics_ref()
          }

  defstruct [:precision, :m, :atomics]

  @doc """
  Create a new concurrent sketch.
  """
  @spec new(keyword()) :: {:ok, t()}
  def new(opts \\ []) do
    p = Keyword.get(opts, :precision, 12)
    m = 1 <<< p
    ref = :atomics.new(m, signed: false)
    {:ok, %__MODULE__{precision: p, m: m, atomics: ref}}
  end

  @doc """
  Add a value. Safe to call concurrently from any process.
  """
  @spec add(t(), term() | non_neg_integer()) :: :ok
  def add(%__MODULE__{} = sketch, hash) when is_integer(hash) and hash >= 0 do
    do_add(sketch, hash)
  end

  def add(%__MODULE__{} = sketch, term) do
    do_add(sketch, UltraLogLog.Hash.hash64(term))
  end

  defp do_add(%__MODULE__{precision: p, atomics: ref}, hash) do
    idx = (hash >>> (64 - p)) + 1
    tail = hash <<< p &&& 0xFFFFFFFFFFFFFFFF
    new_val = UltraLogLog.Encoding.encode(tail, p)
    update_max(ref, idx, new_val)
  end

  # CAS retry loop — only retries when a concurrent writer beat us with a
  # strictly larger value. Per the contention analysis above, retries are
  # effectively absent in production.
  defp update_max(ref, i, new_val) do
    current = :atomics.get(ref, i)
    merged = UltraLogLog.Encoding.merge_registers(current, new_val)

    cond do
      merged == current ->
        :ok

      true ->
        case :atomics.compare_exchange(ref, i, current, merged) do
          :ok -> :ok
          # CAS failure — someone else won; recurse with their value
          _stale -> update_max(ref, i, new_val)
        end
    end
  end

  @doc """
  Take a snapshot of the current concurrent sketch as an immutable
  `UltraLogLog`. Cheap — O(m) bytes copied — but not atomic across
  registers (i.e. you may observe a sketch state that no single writer
  produced). This is fine for cardinality estimation since the result is
  always a valid sketch with monotonically-correct register values.
  """
  @spec snapshot(t()) :: UltraLogLog.t()
  def snapshot(%__MODULE__{precision: p, m: m, atomics: ref}) do
    regs =
      for i <- 1..m, into: <<>> do
        <<:atomics.get(ref, i)::8>>
      end

    %UltraLogLog{precision: p, m: m, registers: regs, martingale: nil}
  end
end
