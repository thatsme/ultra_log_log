# Benchmarks for the v0.2 concurrent insert path.
#
# Run:
#   MIX_ENV=test mix run bench/concurrent_bench.exs
#
# Capture baseline:
#   MIX_ENV=test mix run bench/concurrent_bench.exs > docs/measurements/concurrent-v0.2.txt
#
# (MIX_ENV=test sidesteps the :hyper dep's OTP 27+ compile failure;
# same workaround as `MIX_ENV=test mix dialyzer` / `mix docs`.)
#
# Measurements:
#   1. Single-process throughput — Concurrent.add/2 in a tight loop.
#   2. Concurrent scaling — N processes inserting in parallel,
#      for N in {1, 2, 4, 8, 16, 32}. The story we want to see is
#      total throughput scaling with scheduler count.
#   3. Immutable vs concurrent, single-process — honest comparison
#      against UltraLogLog.add/2. If the immutable path wins
#      single-threaded (no atomics overhead, just binary build), the
#      report says so plainly. The concurrent path's value is the
#      multi-process curve, not single-thread speed.
#   4. snapshot/1 cost at multiple precisions.

import Bitwise

alias UltraLogLog.Concurrent

precision = 12
m = 1 <<< precision
n_per_run = 100_000

# Pre-compute hashes once so the benchmarks measure insert dispatch
# and CAS, not the placeholder hash. Pre-computed hashes are exactly
# what the production v0.2+ caller is encouraged to use anyway.
hashes =
  for i <- 1..n_per_run, do: UltraLogLog.Hash.hash64({:bench, i})

IO.puts("""
================================================================
UltraLogLog v0.2 concurrent insert benchmarks
================================================================
schedulers_online: #{System.schedulers_online()}
precision:         #{precision}  (m = #{m} registers)
inserts per run:   #{n_per_run}

System: #{:erlang.system_info(:system_version) |> to_string() |> String.trim()}
""")

# ----------------------------------------------------------------
# 1. Single-process insert throughput — baseline
# 2. Immutable vs concurrent, single-process
# ----------------------------------------------------------------
IO.puts("""

================================================================
(1) + (3): Single-process insert throughput, immutable vs concurrent
================================================================
""")

# Each scenario receives a freshly-allocated sketch via `before_each`
# so the per-iteration starting state is empty. Critical for the
# concurrent path: a re-used atomics ref would saturate after the
# first iteration and turn subsequent inserts into no-op CAS hits.
Benchee.run(
  %{
    "Concurrent.add (single proc)" => {
      fn {c, hs} -> Enum.each(hs, &Concurrent.add(c, &1)) end,
      before_each: fn hs ->
        {:ok, c} = Concurrent.new(precision: precision)
        {c, hs}
      end
    },
    "UltraLogLog.add immutable (single proc)" => {
      fn {ull, hs} -> Enum.reduce(hs, ull, &UltraLogLog.add(&2, &1)) end,
      before_each: fn hs ->
        {UltraLogLog.new(precision: precision), hs}
      end
    }
  },
  inputs: %{"100k pre-hashed inserts" => hashes},
  warmup: 2,
  time: 5,
  memory_time: 0,
  print: [fast_warning: false]
)

# ----------------------------------------------------------------
# 2. Concurrent insert scaling
# ----------------------------------------------------------------
IO.puts("""

================================================================
(2): Concurrent insert scaling — N processes inserting in parallel
================================================================

Each scenario starts a fresh Concurrent sketch, then partitions
#{n_per_run} pre-hashed inserts across N parallel processes, waits
for them all to finish via Task.await_many. Reported time is total
wall-clock for the whole N-process job (so lower = better and the
scaling curve is visible directly in throughput = #{n_per_run} / time).
""")

proc_counts = [1, 2, 4, 8, 16, 32]

partition = fn list, n ->
  size = max(1, ceil(length(list) / n))
  Enum.chunk_every(list, size)
end

scaling_scenarios =
  Map.new(proc_counts, fn n ->
    chunks = partition.(hashes, n)

    {"#{n} proc#{if n > 1, do: "s", else: ""}",
     fn ->
       {:ok, c} = Concurrent.new(precision: precision)

       chunks
       |> Enum.map(fn chunk ->
         Task.async(fn -> Enum.each(chunk, &Concurrent.add(c, &1)) end)
       end)
       |> Task.await_many(:infinity)
     end}
  end)

Benchee.run(scaling_scenarios,
  warmup: 2,
  time: 5,
  memory_time: 0,
  print: [fast_warning: false]
)

# ----------------------------------------------------------------
# 4. snapshot/1 cost across precisions
# ----------------------------------------------------------------
IO.puts("""

================================================================
(4): snapshot/1 cost at various precisions
================================================================
""")

snapshot_inputs =
  Map.new([10, 12, 14, 16], fn p ->
    {:ok, c} = Concurrent.new(precision: p)
    # Populate every register with at least one insert so cells are
    # non-zero, otherwise snapshot timing trivially reflects all-zero
    # cells (still correct, but less representative).
    for i <- 1..(1 <<< p) do
      Concurrent.add(c, UltraLogLog.Hash.hash64({:fill, p, i}))
    end

    {"p=#{p} (m=#{1 <<< p})", c}
  end)

Benchee.run(
  %{
    "Concurrent.snapshot" => fn c -> Concurrent.snapshot(c) end
  },
  inputs: snapshot_inputs,
  warmup: 1,
  time: 3,
  memory_time: 0,
  print: [fast_warning: false]
)

IO.puts("""

================================================================
Done.
================================================================
""")
