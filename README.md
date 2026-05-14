# UltraLogLog for Elixir

> Approximate distinct counting, 28% more space-efficient than HyperLogLog,
> BEAM-native concurrent insert path, CRDT-style cluster-wide merge.

[![Hex.pm](https://img.shields.io/hexpm/v/ultra_log_log.svg)](https://hex.pm/packages/ultra_log_log)
[![Hex Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/ultra_log_log)

Implementation of:

> Otmar Ertl. **UltraLogLog: A Practical and More Space-Efficient Alternative
> to HyperLogLog for Approximate Distinct Counting.** PVLDB 17(7), 2024.
> [paper] [arXiv extended]

[paper]: https://www.vldb.org/pvldb/vol17/p1655-ertl.pdf
[arXiv extended]: https://arxiv.org/abs/2308.16862

## Status

**v0.1 in development.** This README describes the target API. See
`CHANGELOG.md` for what actually ships.

## Why

HyperLogLog has been the standard answer for "how many distinct things have
I seen?" since 2007. UltraLogLog is its 2024 successor: same practical
properties (commutative, idempotent, mergeable, constant-time insert), but
24–28% less memory for the same accuracy.

This package is the first UltraLogLog implementation for the BEAM. Beyond
the algorithm itself, it leans into BEAM-native primitives:

- **`:atomics`-backed lock-free inserts** for high-throughput pipelines
- **`PartitionSupervisor`-sharded local fan-out** for many writers
- **Cluster-wide merge over distributed Erlang** — ULL is a CRDT, so this
  is trivial: associative element-wise merge with no consensus required

## Quick start

```elixir
{:ok, _} = Application.ensure_all_started(:ultra_log_log)

# Immutable / single-process
ull = UltraLogLog.new(precision: 12)  # 4 KB, ~1.2% standard error
ull = UltraLogLog.add(ull, "session-abc")
ull = UltraLogLog.add(ull, "session-xyz")
{:ok, count} = UltraLogLog.cardinality(ull)
# => {:ok, 2.0}

# Concurrent / lock-free
{:ok, ref} = UltraLogLog.Concurrent.new(precision: 14)
Task.async_stream(visitors, &UltraLogLog.Concurrent.add(ref, &1),
  max_concurrency: System.schedulers_online())
|> Stream.run()

snapshot = UltraLogLog.Concurrent.snapshot(ref)
{:ok, unique_visitors} = UltraLogLog.cardinality(snapshot)
```

## Tradeoffs

### vs `hypex` (HLL, Elixir)

- 24–28% smaller for the same accuracy
- Byte-aligned 8-bit registers → faster updates, simpler binary serialization
- Concurrent insert path (hypex is single-process or GenServer-bottlenecked)

### vs `hyper` (HLL, Erlang)

- Newer algorithm with tighter theoretical bounds
- Concurrent + cluster modules built in, not bolt-on
- Smaller dependency footprint

### vs not using a sketch at all

- Exact counting needs O(N) memory; ULL needs O(1) memory at the cost of
  ~1% error (precision 12). Use a `MapSet` if N is small or accuracy must
  be exact.

## Estimators

| Estimator      | Storage factor | Rel. std. error | When to use                |
|----------------|----------------|-----------------|----------------------------|
| `:fgra` (def.) | 4.895          | 0.782/√m        | Always, unless you measure |
| `:mle`         | 4.631          | 0.761/√m        | Static sketches, hot reads |
| `:martingale`  | 3.466          | tightest        | Single stream, no merge    |

```elixir
{:ok, count} = UltraLogLog.cardinality(ull, estimator: :mle)
```

## Precision → memory → error

```
p=10 →  1 KB,  ~3.1% error    p=14 → 16 KB,  ~0.6% error
p=12 →  4 KB,  ~1.2% error    p=16 → 64 KB,  ~0.3% error
```

## Roadmap

- [x] v0.1 — immutable sketch, FGRA estimator, merge, serialize
- [ ] v0.2 — MLE estimator, martingale, `:atomics`-backed concurrent path,
      xxhash3 NIF
- [ ] v0.3 — `UltraLogLog.Cluster` with `PartitionSupervisor` + `:erpc`
- [ ] v0.4 — ExaLogLog (43% reduction at exa-scale) as `UltraLogLog.Exa`

## Acknowledgements

- Otmar Ertl @ Dynatrace Research, for the paper and the Hash4j reference
- The Hash4j contributors at Dynatrace, whose Java code is the de facto
  ground truth for register-level correctness

## License

Apache 2.0. See `LICENSE`.
