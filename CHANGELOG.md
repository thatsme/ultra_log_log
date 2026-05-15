# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
- **Downsize** (`UltraLogLog.downsize/2`) — public API; the implementation
  for `target_p < p` raises pending v0.2 work (paper §5).

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
  27+ float-match warning in the optional `:hyper` benchmark
  dependency. The warning has no effect on this package's code.
- **No CI** is configured in v0.1. v0.2 will add GitHub Actions.
- **Concurrent and cluster paths** are deferred: a lock-free
  `:atomics`-backed insert path is planned for v0.2, and a
  `PartitionSupervisor`-sharded cluster-wide merge is planned for
  v0.3. No skeleton modules ship in v0.1 — these will land as
  complete commits when their respective releases are ready.

[Unreleased]: https://github.com/thatsme/ultra_log_log/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/thatsme/ultra_log_log/releases/tag/v0.1.0
