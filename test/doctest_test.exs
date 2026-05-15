defmodule UltraLogLog.DoctestTest do
  @moduledoc """
  Wires the `UltraLogLog` moduledoc's `iex>` examples into the test
  runner. ExUnit auto-tags generated doctests with `:doctest`, so they
  can be focused via `mix test --only doctest` and remain part of the
  default `mix test` run.
  """

  use ExUnit.Case, async: true

  doctest UltraLogLog
end
