defmodule Atomboy.Memory.Flat do
  @moduledoc """
  A sparse 64 KB address space, carried by a map. The phase 1 backend.

  Addresses that were never written read 0. That is exactly the assumption the
  SingleStepTests vectors make, since they enumerate every address touched.

  This backend is **not** meant to run a ROM: a map means one hash per access
  and an allocation on every write. It exists so that the CPU test harness has
  no dependency at all on the definitive memory model, which is segmented (ROM
  as a binary, mutable regions apart).
  """

  @behaviour Atomboy.Memory

  import Bitwise

  @type t :: %{Atomboy.Memory.addr() => Atomboy.Memory.value()}

  @doc """
  Builds a memory out of a list of `{address, byte}` pairs.
  """
  @spec new(Enumerable.t()) :: t()
  def new(pairs \\ []), do: Map.new(pairs)

  @impl true
  def read8(mem, addr), do: Map.get(mem, addr, 0)

  @impl true
  def write8(mem, addr, value), do: Map.put(mem, addr, value)

  @impl true
  def read16(mem, addr) do
    lo = Map.get(mem, addr, 0)
    hi = Map.get(mem, addr + 1 &&& 0xFFFF, 0)
    bsl(hi, 8) ||| lo
  end

  @impl true
  def write16(mem, addr, value) do
    mem
    |> Map.put(addr, value &&& 0xFF)
    |> Map.put(addr + 1 &&& 0xFFFF, bsr(value, 8) &&& 0xFF)
  end
end
