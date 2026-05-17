# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.0] - YYYY-MM-DD

Adds the first concurrent insert path for UltraLogLog: a lock-free,
`:atomics`-backed sketch safe to insert into from any process or
scheduler. The immutable `UltraLogLog` from v0.1 is unchanged.

### Added

- **`UltraLogLog.Concurrent`** — lock-free, `:atomics`-backed
  concurrent insert path. One 64-bit `:atomics` cell per register;
  inserts run a CAS retry loop applying `Encoding.merge_registers/2`
  to the observed cell value. Safe to call from any process or
  scheduler with no GenServer, no lock, and no message passing.
  `add/2` returns `:ok` (side-effecting on shared state, not value
  transformation).
- **`UltraLogLog.Concurrent.snapshot/1`** — materializes the
  immutable `%UltraLogLog{}` from a concurrent sketch for
  estimation, serialization, or merge. Snapshot reads each cell
  independently rather than taking a global lock; a snapshot taken
  during active writes is a valid intermediate sketch by
  monotonicity of register merge. The returned `%UltraLogLog{}` has
  `martingale: nil` because the concurrent path does not maintain
  Algorithm 2's per-insert update history; FGRA and MLE work
  normally.
- **Benchee benchmark suite** at `bench/concurrent_bench.exs`:
  single-process throughput, multi-process scaling at N ∈ {1, 2, 4,
  8, 16, 32}, immutable vs concurrent single-process comparison,
  and `snapshot/1` cost at p ∈ {10, 12, 14, 16}.

### Validation

- **Equivalence under contention** — a concurrent sketch built by N
  parallel processes is bit-for-bit identical to the serial sketch
  of the same elements, asserted on the register state via exact
  binary equality at `p ∈ {10, 12, 14}` × `N ∈ {1k, 10k, 100k}`.
  The CAS loop is correct because `merge_registers/2` is monotone,
  commutative, associative, and idempotent.
- **Stress** — the highest-contention case (p=10, N=10k) was run
  20× with independent seeds, 20/20 green.
- **Idempotence under contention** — double-inserting an element
  set in parallel produces the same registers as inserting it
  once (CRDT idempotence under concurrency).
- **StreamData property test** for arbitrary `(p, N, seed, procs)`
  combinations, tagged `:statistical`.
- **Baseline** — full Benchee output captured at
  [`docs/measurements/concurrent-v0.2.txt`](https://github.com/thatsme/ultra_log_log/blob/main/docs/measurements/concurrent-v0.2.txt).

### Notes

- **Single-process performance**: the concurrent path is ~1.08×
  faster than the immutable path even with one process (25.4 ips
  vs 23.6 ips on 100k inserts at p=12, Apple M5). The immutable
  `add/2` rebuilds a binary on every register-changing insert (an
  O(m) head/byte/tail copy); the concurrent path does two
  constant-time `:atomics` operations. Use the immutable form for
  value semantics (snapshots, serialization, CRDT merge); use the
  concurrent form for shared mutable sketches at high insert rates.
- **Multi-process scaling**: monotone from 1 → ~4.35× at 32
  processes on a 10-core machine, flattening past core count as
  expected for a CPU-bound workload. See the README for the full
  table.
- **Snapshot semantics**: `snapshot/1` is not globally atomic
  across cells. By design — register merge is monotone in the
  UltraLogLog partial order, so a "torn" snapshot is always a
  valid intermediate sketch, never an invalid one. Quiesce
  writers (e.g. `Task.await_many/2` on insert tasks) for a
  globally consistent snapshot.
- **Memory**: the active concurrent structure costs 8× the
  immutable form (one 64-bit `:atomics` cell per register; 128 KB
  at p=14 vs 16 KB). Deliberate — concurrent sketches are
  long-lived shared objects, not millions-of-instances. Packing
  multiple registers per cell would create logical false sharing
  and amplify contention.
- **Build environment**: `benchee` was moved to `only: [:dev,
  :test]` to route around the same OTP 28 `:hyper` compile
  failure that affects `mix dialyzer`, `mix docs`, and `mix
  hex.publish`. Benchmarks therefore run under `MIX_ENV=test mix
  run bench/concurrent_bench.exs`. Tracked in issue #2.
- **Not in v0.2**: no native hash NIF, no `PartitionSupervisor`
  sharding, no changes to the v0.1 immutable sketch, encoding, or
  estimators.

## [0.1.0] - 2026-05-15

First public release. Implements the immutable UltraLogLog sketch with
all three estimators from the paper, bit-exact validated against the
Hash4j v0.17.0 Java reference.

### Added

- Core encoding from Ertl 2024 §3 (`pack` / `unpack` / `encode` /
  `merge_registers`), ported bit-exact from Hash4j v0.17.0 — the
  version `dynatrace-research/ultraloglog-paper` pins as its
  reproducibility ground truth.
- **FGRA estimator** (`UltraLogLog.Estimator.FGRA`) — Algorithm 6 from
  the paper, paper-faithful inline implementation (no lookup tables).
  Computes `g(r)`, `λₚ`, and the small/large-range corrections
  (`σ`, `ψ`, `φ`) directly from the paper's equations.
- **MLE estimator** (`UltraLogLog.Estimator.MLE`) — secant solver from
  Ertl 2017 Algorithm 8 over the log-likelihood, Jensen lower-bound
  initial guess, inline Taylor + doubling recurrence for `h(x)` (no
  `:math.exp` in the inner loop), first-order bias correction per
  paper eq. (11).
- **Martingale estimator** (`UltraLogLog.Estimator.Martingale`) — HIP
  estimation per Algorithm 2; constant-time `μ ← μ − h(r) + h(r')`
  update per insert. The `martingale` field of `%UltraLogLog{}`
  carries `{estimate, μ}` for active sketches and `nil` after
  invalidation by `merge/2` or `from_binary/1`.
- **CRDT merge** (`UltraLogLog.merge/2`) — element-wise on registers
  under the ULL partial order; commutative, associative, idempotent.
- **Binary serialization** (`UltraLogLog.to_binary/1` /
  `UltraLogLog.from_binary/1`) — versioned compact format
  (`<<"ULL1", precision::8, registers::binary>>`).
- **Downsize** (`UltraLogLog.downsize/2`) — accepts `target_p == p`
  (returns the sketch unchanged); for `target_p < p` raises pending
  v0.2 implementation (paper §5).

### Validation

- 16 byte-for-byte reference vectors against Hash4j v0.17.0
  (p ∈ {8, 10, 12, 14} × n ∈ {100, 1k, 10k, 100k}).
- 222 encoding-vector cases at p ∈ {3, 8, 10, 12, 14, 26}.
- FGRA / MLE / martingale spot-check vs Hash4j within IEEE 754 noise:
  max relative error 8.4e-16, 1.3e-16, and 0.0 respectively.
- Statistical correctness at p ∈ {10, 12, 14}, N ∈ {100, 1k, 10k,
  100k, 1M}, 30 trials per cell; worst-case empirical bias 0.566%
  against a 3σ bound of 1.127% (martingale, p=10, N=10⁶).
- Property tests for the algebraic laws of `merge_registers/2`
  (commutativity, associativity, idempotence) on the reachable
  subset of register bytes.
- Convergence-speed tests for the MLE secant solver: mean 3.05–3.79
  iterations per query across 300 random sketches per precision,
  max 6 iterations.
- Full empirical baselines committed under
  [`docs/measurements/`](https://github.com/thatsme/ultra_log_log/tree/main/docs/measurements)
  in the repository.

### Notes

- **Paper section numbering**: this implementation cites the
  conference PVLDB PDF. The arXiv extended version uses different
  numbers for the same content (FGRA is §3.3 / Alg. 6 in the
  conference PDF; §4.1 in the arXiv extended version).
- **Register encoding**: nonzero registers carry a `+4p − 8` shift
  relative to the paper's bare encoding so byte values saturate at
  255 regardless of precision. Documented in Ertl 2024 §4 as a
  Hash4j choice; reproduced here for bit-exact compatibility.
- **Hashing**: `UltraLogLog.Hash.hash64/1` uses a `:erlang.phash2/2`
  derivation. Adequate for well-distributed inputs; production
  workloads with adversarial or skewed keyspaces should pass
  pre-computed hashes from a quality 64-bit function. A native
  xxhash3 NIF is planned for v0.2.
- **Dialyzer** runs under `MIX_ENV=test` to avoid a pre-existing OTP
  27+ float-match warning in the `:hyper` benchmark comparison
  dependency (planned for v0.2 benchmarks; not yet exercised in
  v0.1). The warning has no effect on this package's code.
- **No CI** is configured in v0.1. v0.2 will add GitHub Actions.
- **Concurrent and cluster paths** are deferred: a lock-free
  `:atomics`-backed insert path is planned for v0.2, and a
  `PartitionSupervisor`-sharded cluster-wide merge is planned for
  v0.3. No skeleton modules ship in v0.1 — these will land as
  complete commits when their respective releases are ready.

[Unreleased]: https://github.com/thatsme/ultra_log_log/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/thatsme/ultra_log_log/releases/tag/v0.2.0
[0.1.0]: https://github.com/thatsme/ultra_log_log/releases/tag/v0.1.0
