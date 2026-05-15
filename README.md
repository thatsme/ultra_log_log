# UltraLogLog

> Space-efficient distinct counting for the BEAM, ported from Ertl 2024 (VLDB).

[![Hex.pm](https://img.shields.io/hexpm/v/ultra_log_log.svg)](https://hex.pm/packages/ultra_log_log)
[![Hex Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/ultra_log_log)
[![License](https://img.shields.io/badge/license-Apache_2.0-green.svg)](https://github.com/thatsme/ultra_log_log/blob/main/LICENSE)

UltraLogLog is a probabilistic data structure for approximate distinct
counting — same constant memory, constant-time inserts, and associative
merge as HyperLogLog, but **24–28% less memory at the same accuracy**.
This package is a paper-faithful Elixir port, cross-validated bit-for-bit
against the [Hash4j Java reference][hash4j] (v0.17.0) on every estimator.

The algorithm comes from:

> Otmar Ertl. *UltraLogLog: A Practical and More Space-Efficient
> Alternative to HyperLogLog for Approximate Distinct Counting.*
> PVLDB 17(7), 2024.
> [[VLDB PDF]][paper] · [[arXiv extended]][arxiv]

[paper]: https://www.vldb.org/pvldb/vol17/p1655-ertl.pdf
[arxiv]: https://arxiv.org/abs/2308.16862
[hash4j]: https://github.com/dynatrace-oss/hash4j/tree/v0.17.0

## Quick start

Add to `mix.exs`:

```elixir
def deps do
  [{:ultra_log_log, "~> 0.1.0"}]
end
```

Count distinct values in a stream:

```elixir
ull = UltraLogLog.new(precision: 12)        # 4 KB, ~1.2% standard error
ull = UltraLogLog.add(ull, "session-abc")
ull = UltraLogLog.add(ull, "session-xyz")
{:ok, count} = UltraLogLog.cardinality(ull)
# count ≈ 2.0
```

Merge two sketches — `merge/2` is commutative, associative, and idempotent:

```elixir
a = UltraLogLog.new(precision: 12) |> UltraLogLog.add("x")
b = UltraLogLog.new(precision: 12) |> UltraLogLog.add("y")
merged = UltraLogLog.merge(a, b)
{:ok, count} = UltraLogLog.cardinality(merged)
# count ≈ 2.0
```

Trade memory for accuracy by raising the precision:

```elixir
small = UltraLogLog.new(precision: 10)   #  1 KB, ~3.1% error
big   = UltraLogLog.new(precision: 14)   # 16 KB, ~0.6% error
```

## Why UltraLogLog

HyperLogLog has been the standard answer for "how many distinct things
have I seen?" since 2007: constant memory, constant-time inserts, and
mergeable across shards or nodes. UltraLogLog keeps all of that.

What UltraLogLog adds is information density. Where HLL packs 6-bit
registers, ULL uses byte-aligned 8-bit ones — two extra bits per slot,
recovered many times over by a 2024 estimator family that extracts more
signal from each register. The net is 24–28% less memory at the same
standard error, depending on which estimator you choose. The byte
alignment is also a BEAM win: registers map directly to plain binaries,
no bit-packing on the hot path.

When *not* to use it: small N (just use a `MapSet`), or any case that
requires exact counts. ULL is an *approximate* counter; the smallest
useful precision (`p=10`, 1 KB) carries ~3.1% relative standard error.

## Estimators

| Estimator         | Storage factor | Rel. std. error | Use when                                                                                            |
|-------------------|---------------:|-----------------|-----------------------------------------------------------------------------------------------------|
| `:fgra` (default) | 4.895          | `0.782/√m`      | Default. Single-pass, no iteration.                                                                 |
| `:mle`            | 4.631          | `0.761/√m`      | Tightest bound; secant solver runs ~5 iterations per query.                                         |
| `:martingale`     | 3.466          | `0.658/√m`      | Single-stream sketch never merged; returns `{:error, :invalidated_by_merge}` after `merge/2`.       |

```elixir
{:ok, count} = UltraLogLog.cardinality(ull, estimator: :mle)
```

**Merge is a CRDT operation.** Element-wise register merge under the ULL
partial order is commutative, associative, and idempotent — so distributed
cardinality is trivial: shards independently maintain sketches, merge on
demand, and the answer is exactly as if every insert had hit a single
sketch. No coordinator, no quorum, no consensus.

## Empirical validation

Every estimator is cross-checked against Hash4j v0.17.0's reference
implementation on the same 16 register snapshots (4 precisions ×
4 checkpoints), then exercised statistically over 450 random trials.
Full reports live under
[`docs/measurements/`](https://github.com/thatsme/ultra_log_log/tree/main/docs/measurements)
in the repository.

### FGRA vs Hash4j (16 fixtures)

- max relative error: **8.4e-16**
- mean: **2.6e-16**

This is IEEE 754 noise — the implementations agree to the last bit of
double precision.

### MLE vs Hash4j (16 fixtures)

- max relative error: **1.3e-16**
- mean: **8.4e-18**
- secant iterations: mean **4.06**, max **6**

Most fixtures bit-identical; the worst case is one trailing-bit flip
in floating-point accumulation. The secant solver converges in 3–6
iterations on every fixture and across 100 additional random sketches
per precision (300 total).

### Martingale vs Hash4j (16 fixtures)

- max relative error: **0.0**
- mean: **0.0**

Bit-exact across all 16 fixtures, including the 100k-insert accumulation
cases. The estimator shares Hash4j's branch-free integer formulation
for the per-register state-change probability, so floating-point
divergence has nowhere to come from.

### Statistical correctness (15 cells × 30 trials, 450 estimates each)

All three estimators meet the paper's theoretical bounds with significant
headroom on every (p, N) cell:

| Estimator     | Worst bias                    | Bound        | Worst stddev ratio | Bound |
|---------------|-------------------------------|--------------|--------------------|-------|
| `:fgra`       | +0.411% (p=10, N=10⁴)         | ±1.339%      | 1.134 (p=14, N=10⁵) | 1.5   |
| `:mle`        | +0.404% (p=10, N=10⁶)         | ±1.302%      | 1.034 (p=14, N=10⁵) | 1.5   |
| `:martingale` | +0.566% (p=10, N=10⁶)         | ±1.127%      | 1.070 (p=14, N=100) | 1.5   |

Bias bounds are 3σ around the theoretical relative standard error;
stddev bounds allow up to 50% above the theoretical figure. Run the
suite locally with:

```sh
REPORT=1 mix test --include statistical
```

See [`fgra-v0.1.txt`][meas-fgra], [`mle-v0.1.txt`][meas-mle], and
[`martingale-v0.1.txt`][meas-mart] in the repository for the full
per-cell tables.

[meas-fgra]: https://github.com/thatsme/ultra_log_log/blob/main/docs/measurements/fgra-v0.1.txt
[meas-mle]: https://github.com/thatsme/ultra_log_log/blob/main/docs/measurements/mle-v0.1.txt
[meas-mart]: https://github.com/thatsme/ultra_log_log/blob/main/docs/measurements/martingale-v0.1.txt

## Precision and memory

Precision `p` allocates `2^p` 8-bit registers — state size is exactly
`2^p` bytes:

```
p=10 →  1 KB,  ~3.1% error
p=12 →  4 KB,  ~1.2% error   (default)
p=14 → 16 KB,  ~0.6% error
p=16 → 64 KB,  ~0.3% error
```

Pick the smallest precision whose error fits your use case. `p=12` is a
reasonable default.

## Status and roadmap

- **v0.1 (current)** — immutable sketch, FGRA / MLE / martingale
  estimators, merge, binary serialization, downsize (full
  implementation in v0.2), full validation against Hash4j v0.17.0.
- **v0.2 (planned)** — lock-free `:atomics`-backed concurrent insert
  path; native 64-bit hash (xxhash3 NIF); benchmarks; GitHub Actions
  CI.
- **v0.3 (planned)** — sharded inserts via `PartitionSupervisor` and
  cluster-wide merge over distributed Erlang.
- **v0.4 (potential)** — ExaLogLog, the 2024 follow-up to ULL for
  exa-scale cardinalities.

Planned items are not promised timelines. Watch the repository or
[`CHANGELOG.md`](CHANGELOG.md) for releases.

## Citation

If you use UltraLogLog in academic work, please cite the underlying
paper:

```bibtex
@article{ertl2024ultraloglog,
  author  = {Otmar Ertl},
  title   = {UltraLogLog: A Practical and More Space-Efficient
             Alternative to HyperLogLog for Approximate Distinct Counting},
  journal = {Proceedings of the VLDB Endowment},
  volume  = {17},
  number  = {7},
  year    = {2024},
  pages   = {1655--1668},
  url     = {https://www.vldb.org/pvldb/vol17/p1655-ertl.pdf}
}
```

If this package is useful in your production work, a star on the
[GitHub repository][github] is appreciated.

[github]: https://github.com/thatsme/ultra_log_log

## Acknowledgements

- **Otmar Ertl** ([@oertl](https://github.com/oertl)) and **Dynatrace
  Research** for both the paper and the Hash4j Java reference, which
  served as ground truth for every byte of register encoding and every
  digit of estimator output.
- The **Hash4j contributors** at Dynatrace — their public source is
  what made paper-faithful porting realistic on a reasonable timeline.

## License

[Apache 2.0](https://github.com/thatsme/ultra_log_log/blob/main/LICENSE).
