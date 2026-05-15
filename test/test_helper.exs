# `:statistical` runs the FGRA estimator over many trials at multiple
# (p, N) pairs — minutes wall time, excluded by default. Run via
# `mix test --include statistical` when validating the estimator.
ExUnit.start(exclude: [:reference_vectors, :statistical])
