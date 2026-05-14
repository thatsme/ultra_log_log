defmodule UltraLogLog.ReferenceVectorsTest do
  @moduledoc """
  Cross-check this implementation against Hash4j (Java reference).

  ## Workflow

  1. In the Hash4j source tree, write a small Java program that:
     - creates an UltraLogLog at known precisions (8, 10, 12, 14)
     - inserts a deterministic sequence of pre-computed 64-bit hashes
     - dumps the register binary at known checkpoints (0, 100, 1k, 10k, 100k, 1M)
     - writes `test/fixtures/ull_p{p}_n{n}.bin` files

  2. Generate fixtures once, commit them to the repo.

  3. This test loads each fixture, replays the same hash sequence through
     our Elixir implementation, and asserts byte-for-byte register equality.

  This is the single most important test in the suite — if it passes, the
  data structure is correct independent of estimator correctness.
  """

  use ExUnit.Case, async: true

  @moduletag :reference_vectors
  @moduletag :skip

  @fixtures_dir Path.join([__DIR__, "fixtures"])

  describe "register state matches Hash4j reference" do
    for p <- [8, 10, 12, 14], n <- [100, 1_000, 10_000, 100_000] do
      @p p
      @n n

      test "p=#{p}, n=#{n}" do
        fixture = Path.join(@fixtures_dir, "ull_p#{@p}_n#{@n}.bin")
        seeds = Path.join(@fixtures_dir, "ull_p#{@p}_n#{@n}.seeds")

        assert File.exists?(fixture), "missing fixture #{fixture} — generate from Hash4j"

        expected_registers = File.read!(fixture)
        hashes = seeds |> File.stream!() |> Enum.map(&(&1 |> String.trim() |> String.to_integer()))

        ull =
          Enum.reduce(hashes, UltraLogLog.new(precision: @p), fn h, acc ->
            UltraLogLog.add(acc, h)
          end)

        assert ull.registers == expected_registers,
               "register mismatch at p=#{@p}, n=#{@n}"
      end
    end
  end
end
