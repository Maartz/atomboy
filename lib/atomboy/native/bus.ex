defmodule Atomboy.Native.Bus do
  @moduledoc """
  Memory access, isolated -- the seam where the cartridge will one day go.

  `Atomboy.CPU.Loop` and `Atomboy.CPU.CartLoop` come out of the same generator
  and differ **only** in their two memory accessors: one sees a flat 64 KB
  space, the other grafts MBC banks, save RAM and I/O registers onto it. This
  module is the native equivalent of that boundary, and it exists now for the
  same reason -- the day the native side has to talk to a real cartridge, this
  is the only file that grows.

  Reads still do nothing but add the 64 KB base to a 16-bit address: flat memory
  is the contract the SM83 vectors validate, and no address the SM83 tests read
  behaves differently on the way in.

  ## The write hook: where a store stops being a store

  Writes are the asymmetric half. On real hardware some addresses *do* something
  when written -- the joypad recomposes its matrix, `0xFF46` copies 160 bytes
  into OAM, `0xFF04` resets the divider, and everything below `0x8000` is a
  cartridge register rather than memory. `Atomboy.CPU.CartLoop.ram_write/3` is
  the oracle for all of it.

  Every single-byte write therefore goes through the seam, and *every* form goes:
  `LD (HL), r` as much as `LD (a16), A`. Routing only the forms that name an
  address absolutely was tempting -- those are the ones an assembler produces for
  `ld ($FF46), a` -- and it was wrong. `LD HL, $FF46 / LD (HL), A` is a perfectly
  ordinary way to ask for an OAM DMA, and under a seam that only watched the
  absolute forms it laid down a plain byte and no sprite ever appeared.

  ## What the hook costs, and why it is shaped backwards

  It sits on the hot path of every store, so the fast path is four instructions
  where it used to be two:

      bltu address, rom_top, done    # below 0x8000 the cartridge answers: drop
      add  t1, mem, address
      sb   source, t1, 0
      bltu address, io_base, done    # below 0xFF00 a store is only a store

  The store happens *before* the range check rather than after it, which reads
  backwards and is the point: had the check come first, the fast path would need
  a jump to skip the seam call, and that jump costs the same as the store it
  guards. Writing first and letting the seam correct what it has to means the
  common case never branches over anything. A write into the I/O page therefore
  lands twice -- once raw, once composed -- and nothing can observe the interval,
  because nothing runs in it.

  The two bounds live in registers (`Atomboy.Native.Regs`) instead of being
  materialised, so the check is two instructions and no immediate has to hold
  `0xFF00`. That they are registers is also what lets one code shape serve two
  memory models: `bounds/1` installs a console's bounds, or bounds that no
  address can satisfy, and the flat interpreter keeps its every-store-is-a-store
  contract without a second copy of a hundred handlers. Its seam is then a bare
  `ret` -- see `flat_seam/0`.

  Sixteen-bit writes are **not** routed, and that is a decision rather than an
  omission. They are the stack (`PUSH`, `CALL`, `RST`, the interrupt service) and
  `LD (a16), SP`; a stack in the I/O page is not a thing hardware offers, since
  HRAM begins at `0xFF80`, above every register the seam models. The one case the
  oracle does model -- a push landing on `0xFF0F` while an interrupt is being
  serviced -- is written out explicitly where the service is emitted. Routing the
  stack would double the cost of the table's hottest writes to cover a program
  nobody writes.

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

  @doc "The label a write that is more than a write jumps to."
  @spec seam() :: atom()
  def seam, do: :mmio_write

  @doc """
  The bounds outside which a store is not only a store.

  `:console` is the DMG's: the cartridge answers below `0x8000`, the registers
  from `0xFF00`. `:flat` is the interpreter's -- `0` and `0x10000`, which no
  16-bit address can fall outside, so the seam is never entered and a store is
  always exactly a store.
  """
  @spec bounds(:console | :flat) :: [Asm.item()]
  def bounds(:console) do
    [RV32.li(Regs.rom_top(), 0x8000), RV32.li(Regs.io_base(), 0xFF00)]
  end

  def bounds(:flat) do
    [RV32.li(Regs.rom_top(), 0), RV32.li(Regs.io_base(), 0x10000)]
  end

  @doc """
  The seam a flat memory needs: nothing at all.

  Unreachable under `bounds(:flat)`, and correct if it ever were reached -- the
  byte has already been stored by the time the seam is called, and in a flat
  memory that is the whole of it. One instruction of honest dead code, against
  emitting the handlers twice.
  """
  @spec flat_seam() :: [Asm.item()]
  def flat_seam, do: [Asm.label(seam()), RV32.ret()]

  @doc """
  Writes `source` at `address`, through the seam.

  Only the low eight bits go -- `sb` sees to that. The seam is called with the
  guest address in `a0` and the byte in `t0`, and it may clobber `t0` to `t4`,
  `a0` and `ra`: nothing an opcode handler still needs after a store, which is
  what makes the call free of spills.
  """
  @spec write(RV32.reg(), RV32.reg()) :: [Asm.item()]
  def write(address, source) do
    # The seam's calling convention, arranged only on the path that calls it.
    setup = place(address, source)

    # The instructions between the second check and the point both paths meet:
    # the moves, then the call itself.
    tail = 4 * (length(setup) + 1)

    [
      RV32.bltu(address, Regs.rom_top(), 16 + tail),
      RV32.add(:t1, Regs.mem(), address),
      RV32.sb(source, :t1, 0),
      RV32.bltu(address, Regs.io_base(), 4 + tail),
      setup,
      Asm.call(seam())
    ]
  end

  # `a0` takes the address and `t0` the byte, with the moves ordered so that
  # neither operand is overwritten before it has been read. `t1` is free here:
  # the store above has already used and finished with it.
  defp place(:a0, :t0), do: []
  defp place(:a0, source), do: [RV32.mv(:t0, source)]

  defp place(:t0, :a0) do
    [RV32.mv(:t1, :t0), RV32.mv(:t0, :a0), RV32.mv(:a0, :t1)]
  end

  defp place(address, :a0), do: [RV32.mv(:t0, :a0), RV32.mv(:a0, address)]
  defp place(address, :t0), do: [RV32.mv(:a0, address)]
  defp place(address, source), do: [RV32.mv(:a0, address), RV32.mv(:t0, source)]

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
  what lets `PUSH` pass SP itself. Both bytes go straight to memory: see the
  moduledoc for why the stack does not go through the seam.
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
