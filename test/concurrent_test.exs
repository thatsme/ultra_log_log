defmodule UltraLogLog.ConcurrentTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Bitwise

  alias UltraLogLog.Concurrent

  # The CAS path is correct iff the concurrent snapshot is bit-for-bit
  # equal to a serial reference build of the same elements, for ANY
  # interleaving. Merge is commutative, associative, and idempotent
  # (proven in UltraLogLog.PropertyTest), so order independence is a
  # consequence of those laws — the equivalence assertion is exact,
  # not approximate.

  defp deterministic_elements(seed, n) do
    state = :rand.seed_s(:exsss, {seed, seed + 1, seed + 2})
    Enum.map_reduce(1..n, state, fn _, s -> :rand.uniform_s(1 <<< 60, s) end) |> elem(0)
  end

  defp build_serial(p, elements) do
    Enum.reduce(elements, UltraLogLog.new(precision: p), &UltraLogLog.add(&2, &1))
  end

  defp build_concurrent(p, elements, procs) do
    {:ok, c} = Concurrent.new(precision: p)
    chunk_size = max(1, ceil(length(elements) / procs))

    elements
    |> Enum.chunk_every(chunk_size)
    |> Enum.map(fn chunk ->
      Task.async(fn -> Enum.each(chunk, &Concurrent.add(c, &1)) end)
    end)
    |> Task.await_many(:infinity)

    c
  end

  describe "new/1" do
    test "default precision" do
      assert {:ok, c} = Concurrent.new()
      assert c.precision == 12
      assert c.m == 4096
    end

    test "custom precision" do
      assert {:ok, c} = Concurrent.new(precision: 10)
      assert c.precision == 10
      assert c.m == 1024
    end

    test "rejects out-of-range precision" do
      assert_raise ArgumentError, ~r/precision must be an integer in 3\.\.26/, fn ->
        Concurrent.new(precision: 2)
      end

      assert_raise ArgumentError, ~r/precision must be an integer in 3\.\.26/, fn ->
        Concurrent.new(precision: 27)
      end

      assert_raise ArgumentError, ~r/precision must be an integer in 3\.\.26/, fn ->
        Concurrent.new(precision: :twelve)
      end
    end

    test "fresh sketch snapshots to all-zero registers" do
      {:ok, c} = Concurrent.new(precision: 10)
      snap = Concurrent.snapshot(c)
      assert snap.registers == :binary.copy(<<0>>, 1024)
      assert snap.martingale == nil
    end
  end

  describe "add/2" do
    test "returns :ok" do
      {:ok, c} = Concurrent.new(precision: 12)
      assert Concurrent.add(c, "x") == :ok
    end

    test "accepts pre-computed integer hash" do
      {:ok, c} = Concurrent.new(precision: 12)
      assert Concurrent.add(c, 0xDEADBEEFCAFEBABE) == :ok
    end

    test "term and pre-computed-hash arms agree" do
      {:ok, c1} = Concurrent.new(precision: 12)
      {:ok, c2} = Concurrent.new(precision: 12)
      :ok = Concurrent.add(c1, "session-abc")
      :ok = Concurrent.add(c2, UltraLogLog.Hash.hash64("session-abc"))
      assert Concurrent.snapshot(c1).registers == Concurrent.snapshot(c2).registers
    end

    test "serial inserts via Concurrent match serial inserts via UltraLogLog" do
      # Sanity floor: with one process there is no contention, so the
      # CAS loop reduces to read-merge-write and must agree with the
      # immutable path byte-for-byte.
      elements = deterministic_elements(1, 5_000)
      reference = build_serial(12, elements)

      {:ok, c} = Concurrent.new(precision: 12)
      Enum.each(elements, &Concurrent.add(c, &1))

      assert Concurrent.snapshot(c).registers == reference.registers
    end
  end

  describe "snapshot/1" do
    test "preserves cardinality estimate within expected error" do
      n = 10_000
      p = 12
      elements = 1..n |> Enum.map(&{:elem, &1})

      {:ok, c} = Concurrent.new(precision: p)
      Enum.each(elements, &Concurrent.add(c, &1))

      snap = Concurrent.snapshot(c)
      {:ok, est} = UltraLogLog.cardinality(snap)

      # FGRA stderr is 0.782/√m at p=12 (m=4096) ≈ 1.22%. Allow 6σ.
      stderr = 0.782 / :math.sqrt(1 <<< p)
      assert abs(est - n) / n < 6 * stderr
    end

    test "snapshot martingale is nil; martingale estimator returns invalidated" do
      {:ok, c} = Concurrent.new(precision: 12)
      :ok = Concurrent.add(c, "x")
      snap = Concurrent.snapshot(c)
      assert snap.martingale == nil

      assert UltraLogLog.cardinality(snap, estimator: :martingale) ==
               {:error, :invalidated_by_merge}
    end

    test "FGRA and MLE both work on a snapshot" do
      {:ok, c} = Concurrent.new(precision: 12)
      Enum.each(1..1_000, &Concurrent.add(c, &1))
      snap = Concurrent.snapshot(c)
      assert {:ok, _} = UltraLogLog.cardinality(snap, estimator: :fgra)
      assert {:ok, _} = UltraLogLog.cardinality(snap, estimator: :mle)
    end
  end

  describe "equivalence under contention" do
    # The core correctness property: a concurrent sketch built by many
    # processes inserting in parallel is bit-identical to an immutable
    # sketch built by inserting the same elements serially. Holds
    # because the CAS loop only ever applies merge_registers, which is
    # commutative/associative/idempotent.
    #
    # At p=10 (m=1024) with N=10k, birthday math guarantees many
    # same-register collisions across writers — so this case
    # genuinely exercises the CAS retry path, not just the happy path.
    for p <- [10, 12, 14], n <- [1_000, 10_000, 100_000] do
      test "p=#{p}, n=#{n}: concurrent snapshot == serial reference" do
        p = unquote(p)
        n = unquote(n)
        elements = deterministic_elements(42, n)

        reference = build_serial(p, elements)
        c = build_concurrent(p, elements, System.schedulers_online() * 4)

        assert Concurrent.snapshot(c).registers == reference.registers
      end
    end
  end

  describe "idempotence under contention" do
    # CRDT idempotence: inserting the same element set twice in
    # parallel produces the same registers as inserting it once. This
    # exercises a deliberately collision-heavy interleaving.
    test "double-insert under contention equals single-insert" do
      p = 12
      elements = deterministic_elements(7, 5_000)
      procs = System.schedulers_online() * 4

      c_single = build_concurrent(p, elements, procs)
      c_double = build_concurrent(p, elements ++ elements, procs)

      assert Concurrent.snapshot(c_double).registers ==
               Concurrent.snapshot(c_single).registers
    end
  end

  describe "stress / interleaving" do
    @moduletag :statistical

    property "concurrent snapshot == serial reference for arbitrary inputs" do
      check all(
              p <- integer(8..12),
              n <- integer(100..5_000),
              seed <- integer(1..1_000_000),
              procs_mult <- integer(1..6),
              max_runs: 30
            ) do
        elements = deterministic_elements(seed, n)
        reference = build_serial(p, elements)
        c = build_concurrent(p, elements, System.schedulers_online() * procs_mult)
        assert Concurrent.snapshot(c).registers == reference.registers
      end
    end
  end
end
