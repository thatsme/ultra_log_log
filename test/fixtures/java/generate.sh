#!/usr/bin/env bash
# Regenerate UltraLogLog test fixtures from the Hash4j Java reference.
#
# Requires Docker (or an OrbStack/colima/Rancher Desktop drop-in). The
# container is native arm64 on Apple Silicon — no Rosetta, no emulation,
# fast cold start. See ./Dockerfile for the underlying build.
#
# Output lands in the parent directory (test/fixtures/):
#   - ull_p{p}_n{n}.bin  for p ∈ {8,10,12,14}, n ∈ {100, 1k, 10k, 100k}
#   - ull_n{n}.seeds     cumulative u64 hashes (one per line), shared
#                        across precisions since the RNG seed is fixed
#   - encoding_vectors.json

set -euo pipefail
cd "$(dirname "$0")"

docker build -t ull-fixtures .
docker run --rm -v "$(pwd)/..:/out" ull-fixtures
