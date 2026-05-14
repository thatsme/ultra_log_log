defmodule UltraLogLog.PropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias UltraLogLog.Encoding

  describe "merge_registers/2 algebraic properties" do
    property "commutative" do
      check all a <- integer(0..255),
                b <- integer(0..255) do
        assert Encoding.merge_registers(a, b) == Encoding.merge_registers(b, a)
      end
    end

    property "associative" do
      check all a <- integer(0..255),
                b <- integer(0..255),
                c <- integer(0..255) do
        left = Encoding.merge_registers(Encoding.merge_registers(a, b), c)
        right = Encoding.merge_registers(a, Encoding.merge_registers(b, c))
        assert left == right
      end
    end

    property "idempotent" do
      check all a <- integer(0..255) do
        assert Encoding.merge_registers(a, a) == a
      end
    end

    property "identity element is 0" do
      check all a <- integer(0..255) do
        assert Encoding.merge_registers(a, 0) == a
      end
    end
  end

  describe "UltraLogLog as a CRDT" do
    property "add is idempotent" do
      check all p <- integer(8..12),
                terms <- list_of(term(), min_length: 1, max_length: 100) do
        ull1 = build(p, terms)
        ull2 = build(p, terms ++ terms)
        assert ull1.registers == ull2.registers
      end
    end

    property "merge is commutative" do
      check all p <- integer(8..12),
                terms_a <- list_of(term(), max_length: 50),
                terms_b <- list_of(term(), max_length: 50) do
        a = build(p, terms_a)
        b = build(p, terms_b)
        assert UltraLogLog.merge(a, b).registers == UltraLogLog.merge(b, a).registers
      end
    end

    property "merging with self is identity" do
      check all p <- integer(8..12),
                terms <- list_of(term(), max_length: 50) do
        a = build(p, terms)
        assert UltraLogLog.merge(a, a).registers == a.registers
      end
    end
  end

  # TODO: statistical tests — insert N items, assert error < 3 * theoretical_stderr
  # These belong in a separate test file (test/statistical_test.exs) since they
  # need a real estimator implementation, not the placeholder.

  defp build(p, terms) do
    Enum.reduce(terms, UltraLogLog.new(precision: p), &UltraLogLog.add(&2, &1))
  end
end
