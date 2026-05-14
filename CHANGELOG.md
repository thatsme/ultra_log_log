# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Initial skeleton: module structure, typespecs, API contract documentation
- Property tests for `merge_registers/2` algebraic laws
- Reference vector test scaffold (fixtures TBD)

### Notes

- `UltraLogLog.Encoding.encode/2` and `merge_registers/2` are placeholders
  pending port from Hash4j Java reference
- `UltraLogLog.Estimator.FGRA` is a stub that returns a non-zero but
  incorrect value, suitable only for smoke tests
- `UltraLogLog.Hash.hash64/1` uses `:erlang.phash2/2` concatenation —
  acceptable for tests, not for production use
