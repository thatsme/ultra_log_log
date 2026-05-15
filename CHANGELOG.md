# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Initial skeleton: module structure, typespecs, API contract documentation
- Property tests for `merge_registers/2` algebraic laws
- `Encoding.encode/2`, `merge_registers/2`, and `pack`/`unpack` ported
  bit-exact from Hash4j v0.17.0 (the version pinned by
  `dynatrace-research/ultraloglog-paper`)
- Reference-vector test (16 cases at p ∈ {8,10,12,14}) and encoding-vector
  test (222 cases at p ∈ {3,8,10,12,14,26}) backed by a Docker-based
  fixture generator under `test/fixtures/java/`
- FGRA estimator implemented per Ertl 2024 Algorithm 6 (paper-faithful,
  inline `g(r)` and `λₚ`; small- and large-range corrections via σ/ψ/φ)
- Spot-check tests against Hash4j `OPTIMAL_FGRA_ESTIMATOR` v0.17.0 pass
  within 0.1% (observed ~1e-15 relative on all 16 fixtures)
- Statistical tests pass at p ∈ {10,12,14}, N up to 10⁶, within 3σ of
  theoretical RMSE (run via `mix test --include statistical`)
- Local research artifacts (paper dump, hash4j source checkouts) are
  gitignored — paper canonical link in README, hash4j pin in
  `test/fixtures/java/Dockerfile`
- MLE estimator implemented per Ertl 2024 §3.1 — secant solver
  (Ertl 2017 Algorithm 8) over the log-likelihood, Jensen lower-bound
  initial guess, inline Taylor + doubling recurrence for `h(x)` (no
  `:math.exp` in the inner loop), bias correction per paper eq. (11)
- Spot-check tests against Hash4j `MAXIMUM_LIKELIHOOD_ESTIMATOR` v0.17.0
  pass within 0.5% (observed ~1e-16 relative on all 16 fixtures); mean
  3–4 secant iterations per call, max 6
- Statistical and convergence-speed tests pass at p ∈ {10,12,14},
  N up to 10⁶, within 3σ of theoretical RMSE (0.761/√m)

### Notes

- Encoding follows Ertl 2024 §4: nonzero registers carry the `+4p - 8`
  byte-alignment normalization the paper attributes to Hash4j
- `merge_registers/2` property tests use a constructive
  `reachable_register` generator (uniform 64-bit prefix → `pack/1`),
  since ULL registers occupy a proper subset of `0..255`
- `UltraLogLog.Hash.hash64/1` uses `:erlang.phash2/2` concatenation —
  acceptable for tests, not for production use
- No CI configured; v0.2 will add GitHub Actions before any public release
