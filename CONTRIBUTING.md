# Contributing

Thanks for your interest in `ultra_log_log`. This guide covers how to
set up the project locally, what the testing pyramid looks like, and
what kind of changes the architecture expects.

## Setup

```sh
git clone https://github.com/thatsme/ultra_log_log.git
cd ultra_log_log
mix deps.get
mix test
```

`mix test` runs the default suite — property tests, encoding tests,
doctests, and spot-check fixtures — in roughly one second.

Two additional test tiers, both opt-in:

```sh
# 16 byte-for-byte register checks against Hash4j v0.17.0 (~1s)
mix test --include reference_vectors

# 45 statistical cells, 30 trials each (~3 minutes total)
mix test --include statistical
```

To see the measurement reports the v0.1 README cites, run with
`REPORT=1`:

```sh
REPORT=1 mix test --include statistical
```

### Regenerating fixtures

The byte-for-byte fixtures and the Hash4j ground-truth estimates are
committed to the repository so most contributors never need to touch
them. If you do need to regenerate (e.g. you're investigating a
Hash4j upgrade), use the Docker generator under `test/fixtures/java`:

```sh
./test/fixtures/java/generate.sh
```

This builds a small Java container, runs the reference UltraLogLog,
and writes deterministic snapshots into `test/fixtures/`. Requires
Docker (or any compatible runtime — OrbStack, Rancher Desktop). The
container is single-shot, leaves nothing behind, and pins
Hash4j v0.17.0 in its `Dockerfile`. Re-pinning Hash4j is a deliberate
maintenance event — see the [project memory note][pinning] on why
v0.17.0 is the version used.

[pinning]: https://github.com/dynatrace-research/ultraloglog-paper

## Architectural discipline

Three rules shape what gets accepted:

**1. Algorithmic correctness is verified against the reference.**
Any change to the encoding or an estimator must continue to pass the
spot-check tests in `test/`. The reference is Hash4j v0.17.0 — the
same version `dynatrace-research/ultraloglog-paper` pins for its
reproducibility runs. If a change makes our output diverge from
Hash4j, justify it in the commit message; if a change improves on
Hash4j (e.g. better numerical conditioning), include both the
divergence justification and a fresh measurement baseline.

**2. Paper constants are named attributes with citations.**
Anything that isn't a primitive integer should be a module attribute,
and any module attribute representing a paper constant should carry
an inline comment with the paper section, equation number, and (where
relevant) the corresponding Hash4j source line. Look at
`UltraLogLog.Estimator.FGRA` for the established pattern.

**3. Algorithmic code reads like the paper.**
The estimator modules are intentionally not table-optimized: they read
top-to-bottom as transliterations of the paper's algorithm
pseudocode. Performance optimizations (lookup tables, IEEE 754 bit
tricks, etc.) are welcome — but they belong in a separate module or
a separate function, with the paper-faithful version preserved
alongside as documentation.

## Testing pyramid

The suite is organized so each tier catches a different bug class:

- **Property tests** (`test/property_test.exs`) cover the algebraic
  laws — commutativity, associativity, idempotence of
  `merge_registers/2` over the reachable subset of register bytes.
  They catch encoding asymmetries.
- **Spot-check fixtures** (`test/{encoding,fgra,mle,martingale}_test.exs`)
  pin our output to Hash4j's on deterministic inputs to within
  IEEE 754 noise. They catch any drift between this implementation
  and the reference.
- **Statistical tests** (the `:statistical` tier) run thousands of
  random sketches and assert empirical bias and variance against the
  paper's theoretical bounds. They catch subtle correctness issues
  the spot-check can't see (e.g. an estimator that's exactly right
  on the reference fixtures but wrong everywhere else — unlikely but
  worth guarding against).
- **Doctests** (`test/doctest_test.exs`) wire the moduledoc examples
  into the test runner so the documentation stays in sync with the
  API.

When you add a feature, add a test in the appropriate tier. When
you fix a bug, add a regression test that would have caught it.

## Asking questions

Open a GitHub issue with the `question` label. There's no formal
discussions forum for v0.1; if discussion volume grows, we'll
re-evaluate. PRs are welcome — the PR template will prompt for the
testing and paper-reference checks above.
