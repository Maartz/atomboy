defmodule Atomboy.Native.Bus do
  @moduledoc """
  Memory access, isolated -- the seam where the cartridge will one day go.

  `Atomboy.CPU.Loop` and `Atomboy.CPU.CartLoop` come out of the same generator
  and differ **only** in their two memory accessors: one sees a flat 64 KB
  space, the other grafts MBC banks, save RAM and I/O registers onto it. This
  module is the native equivalent of that boundary, and it exists now for the
  same reason -- the day the native side has to talk to a real cartridge, this
  is the only file that grows.

  Today it does nothing but add the 64 KB base to a 16-bit address. That is
  exactly what we want: flat memory is the contract the SM83 vectors validate.

  ## The address register

  `t1` is the temporary for every access. A caller may therefore hold the
  address there -- `add t1, mem, t1` stays correct -- but must keep nothing in
  it across an access.
  """

  alias Atomboy.Native.Asm
  alias Atomboy.Native.Regs
  alias Atomboy.Native.RV32

  @doc "Reads the byte at `address` into `dest`."
  @spec read(RV32.reg(), RV32.reg()) :: [Asm.item()]
  def read(address, dest) do
    [
      RV32.add(:t1, Regs.mem(), address),
      RV32.lbu(dest, :t1, 0)
    ]
  end

  @doc "Writes `source` at `address`. Only the low eight bits go -- `sb` sees to that."
  @spec write(RV32.reg(), RV32.reg()) :: [Asm.item()]
  def write(address, source) do
    [
      RV32.add(:t1, Regs.mem(), address),
      RV32.sb(source, :t1, 0)
    ]
  end

  @doc """
  Reads the two-byte little-endian word at `address` into `dest`.

  The high byte sits at `address + 1` **wrapped to 16 bits**: a stack at
  `0xFFFF` takes its high byte from address 0, and that is what the hardware
  does. Clobbers `t1`, `t2` and `t3`; `dest` must be none of the three.
  """
  @spec read16(RV32.reg(), RV32.reg()) :: [Asm.item()]
  def read16(address, dest) do
    [
      RV32.add(:t1, Regs.mem(), address),
      RV32.lbu(dest, :t1, 0),
      next_address(address),
      RV32.add(:t1, Regs.mem(), :t3),
      RV32.lbu(:t2, :t1, 0),
      RV32.slli(:t2, :t2, 8),
      RV32.or_(dest, dest, :t2)
    ]
  end

  @doc """
  Writes `source` as two bytes at `address`, low byte first.

  Same 16-bit wrap as `read16/2`, and `address` comes out untouched -- which is
  what lets `PUSH` pass SP itself.
  """
  @spec write16(RV32.reg(), RV32.reg()) :: [Asm.item()]
  def write16(address, source) do
    [
      RV32.add(:t1, Regs.mem(), address),
      RV32.sb(source, :t1, 0),
      next_address(address),
      RV32.add(:t1, Regs.mem(), :t3),
      RV32.srli(:t2, source, 8),
      RV32.sb(:t2, :t1, 0)
    ]
  end

  defp next_address(address) do
    [
      RV32.addi(:t3, address, 1),
      RV32.and_(:t3, :t3, Regs.mask16())
    ]
  end

  @doc """
  Moves SP by `delta`, wrapped to 16 bits -- the gesture the stack shares.
  """
  @spec move_stack(integer()) :: [Asm.item()]
  def move_stack(delta) do
    [
      RV32.addi(Regs.sp(), Regs.sp(), delta),
      RV32.and_(Regs.sp(), Regs.sp(), Regs.mask16())
    ]
  end

  @doc """
  Composes into `dest` the address an indirect pair designates.

  For `HL` it is a copy, and that is where packing HL into a single 16-bit
  register pays: the split form would need a shift and an or on every `(HL)`,
  that is, on a whole column of the table plus the entire CB block.
  """
  @spec address({:ind, atom()} | :hl_ind, RV32.reg()) :: [Asm.item()]
  def address(:hl_ind, dest), do: [RV32.mv(dest, Regs.hl())]
  def address({:ind, hl}, dest) when hl in [:hl_inc, :hl_dec], do: [RV32.mv(dest, Regs.hl())]
  def address({:ind, :bc}, dest), do: pair(Regs.b(), Regs.c(), dest)
  def address({:ind, :de}, dest), do: pair(Regs.d(), Regs.e(), dest)

  defp pair(high, low, dest) do
    [
      RV32.slli(dest, high, 8),
      RV32.or_(dest, dest, low)
    ]
  end

  @doc """
  The HL adjustment `LD (HL+), A` and `LD (HL-), A` drag along.

  It comes **after** the access: the address is the one from before the
  increment.
  """
  @spec adjust({:ind, atom()}) :: [Asm.item()]
  def adjust({:ind, :hl_inc}), do: step(1)
  def adjust({:ind, :hl_dec}), do: step(-1)
  def adjust({:ind, _}), do: []

  defp step(delta) do
    [
      RV32.addi(Regs.hl(), Regs.hl(), delta),
      RV32.and_(Regs.hl(), Regs.hl(), Regs.mask16())
    ]
  end

  @doc """
  The high-page address: `0xFF00 + offset`.

  `0xFF00` does not fit a 12-bit immediate, but subtracting 256 and folding back
  to 16 bits gives exactly the same result for a one-byte offset -- two
  instructions instead of three.
  """
  @spec high_page(RV32.reg(), RV32.reg()) :: [Asm.item()]
  def high_page(offset, dest) do
    [
      RV32.addi(dest, offset, -256),
      RV32.and_(dest, dest, Regs.mask16())
    ]
  end
end
