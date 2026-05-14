defmodule UltraLogLog.Cluster do
  @moduledoc """
  Sharded UltraLogLog distributed across a `PartitionSupervisor`, with
  cluster-wide merge support over distributed Erlang.

  > **Status:** v0.3 target. Skeleton-only in v0.1.

  ## Architecture

  Each shard is a `UltraLogLog.Concurrent` instance owned by a process
  under `PartitionSupervisor`. Inserts are routed by `:erlang.phash2/2`
  of the key — this is **not** the same hash used inside the sketch, just
  the routing hash, so collisions across shards don't double-count.

  Cardinality estimation merges all shards (and optionally all remote
  nodes' shards via `:erpc.multicall/4`) into a single snapshot, then runs
  the chosen estimator.

  ## Why this layout

    - **Local fan-out** via `PartitionSupervisor` keeps the lock-free path
      hot on each scheduler — same Leopardi pattern as elsewhere in the
      Musketeers ecosystem.
    - **Cluster fan-out** via `:erpc` keeps the merge trivial: ULL is a
      CRDT, so `merge/2` is associative across any topology. No
      coordinator, no consensus, no quorum.
    - **Decoupled**: the routing layer doesn't know about the sketch
      internals; the sketch doesn't know about the cluster. Either can be
      swapped (e.g. for a cuckoo filter or a quantile sketch — same
      structural pattern).

  ## Planned API

      {:ok, _} = UltraLogLog.Cluster.start_link(
        name: :unique_visitors,
        precision: 14,
        partitions: System.schedulers_online() * 2
      )

      UltraLogLog.Cluster.add(:unique_visitors, visitor_id)

      # Local merge
      {:ok, count} = UltraLogLog.Cluster.cardinality(:unique_visitors)

      # Cluster-wide merge across all connected nodes
      {:ok, count} = UltraLogLog.Cluster.cardinality(:unique_visitors, scope: :cluster)
  """

  # TODO: implement in v0.3
end
