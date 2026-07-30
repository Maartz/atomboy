defmodule Atomboy.Native.Cart do
  @moduledoc """
  The cartridge: more ROM than the address space has room for.

  A Game Boy sees 32 KB of cartridge and no more. Everything past Tetris carries
  far more than that, and the way out has always been the same -- a chip on the
  cartridge watches the address bus, and a *write* into the ROM's own address
  range, which memory could never answer, tells it which 16 KB to present at
  `0x4000`. That is the whole of an MBC, and `Atomboy.CPU.CartLoop` is this
  module's oracle for it.

  ## Where the bank actually lives

  Nowhere, is the honest answer, and that is the point of building this on
  `Atomboy.Native.Bus`'s page tables. There is no "current bank" variable the
  read path consults, because a read that had to consult one would pay for it on
  every fetch. The four read-table entries covering `0x4000`-`0x7FFF` *are* the
  bank: selecting one rewrites four words, and every read after that lands in
  the new bytes without knowing anything changed.

  So the cost is paid where it belongs. A bank switch is four stores and a
  little arithmetic, on a path a game takes a few hundred times a frame at
  worst; a read stays the five instructions it costs everyone.

  ## What the entries hold

  Pre-biased, as `Atomboy.Native.Bus.translate/3` requires: the host address of
  the bank, minus where the bank starts in the guest.

      pages 0-3   0x0000-0x3FFF   cart_rom
      pages 4-7   0x4000-0x7FFF   cart_rom + N * 0x4000 - 0x4000

  Bank 1 at `0x4000` therefore holds exactly `cart_rom`, which is why the eight
  entries installed at startup are all the same word.

  ## MBC1, and the two clamps that are not one

  `0x2000`-`0x3FFF` selects the bank, five bits of it. `Atomboy.CPU.CartLoop`
  reads

      max(max(value &&& 0x1F, 1) &&& banks - 1, 1)

  and the doubled `max` is not redundant. The first is the hardware's: bank 0
  cannot be selected at `0x4000`, so asking for it gets bank 1 -- which is why a
  ROM's second bank is reachable two ways and its first is not reachable there
  at all. The second catches what the first lets through: on a two-bank
  cartridge `banks - 1` is 1, so selecting bank 2 masks to 0, and *that* zero
  has to become 1 again. Dropping either clamp passes most ROMs and fails a few,
  which is the worst kind of wrong.

  The rest of MBC1 is not here yet. `0x0000`-`0x1FFF` enables save RAM,
  `0x4000`-`0x5FFF` picks its bank, and both are ignored for now --
  deliberately, and visibly: save RAM is still the flat bytes the 64 KB image
  carries, so a game that only uses one bank of it works and a game that
  switches banks silently gets the wrong one. That is the next commit, not this
  one.
  """

  import Bitwise, only: [&&&: 2]

  alias Atomboy.Native.Asm
  alias Atomboy.Native.Bus
  alias Atomboy.Native.Regs
  alias Atomboy.Native.RV32

  @bank_size 0x4000
  @window 0x4000

  # The eight entries below are written by hand, four at a time: a page table of
  # some other size would silently make that arithmetic address the wrong words.
  if Bus.table_bytes() != 64 do
    raise "the cartridge writes read entries 0-7 by hand: a resized page table invalidates that"
  end

  @doc "The size of one ROM bank -- 16 KB, and the size of the switchable window."
  @spec bank_size() :: pos_integer()
  def bank_size, do: @bank_size

  @doc """
  How many banks a ROM has, which must be a power of two.

  The masking MBC1 does is an `and`, not a modulo, so a cartridge whose bank
  count is not a power of two would wrap in a way no formula here describes.
  Hardware never shipped one.
  """
  @spec banks(binary()) :: pos_integer()
  def banks(rom) when is_binary(rom) do
    count = div(byte_size(rom), @bank_size)

    cond do
      rem(byte_size(rom), @bank_size) != 0 ->
        raise ArgumentError,
              "a ROM is a whole number of 16 KB banks, this one is #{byte_size(rom)} bytes"

      count < 2 or (count &&& count - 1) != 0 ->
        raise ArgumentError, "#{count} banks: a cartridge carries a power of two, at least two"

      true ->
        count
    end
  end

  @doc """
  The ROM, for the image's data section. Nothing at all without a cartridge.
  """
  @spec data(binary() | nil) :: [Asm.item()]
  def data(nil), do: []
  def data(rom) when is_binary(rom), do: [{:align, 4}, Asm.label(:cart_rom), rom]

  @doc """
  Points the eight ROM pages at the cartridge: bank 0 low, bank 1 high.

  For the driver, after `Atomboy.Native.Bus.install/0` has made every page flat.
  Without a cartridge this emits nothing and the pages stay flat, which is the
  32 KB image the native core ran before any of this existed.

  Clobbers `t0` and `t1`.
  """
  @spec install(binary() | nil) :: [Asm.item()]
  def install(nil), do: []

  def install(rom) when is_binary(rom) do
    _ = banks(rom)

    [
      Asm.la(:t0, :cart_rom),
      RV32.mv(:t1, Regs.pages()),
      for offset <- 0..28//4 do
        RV32.sw(:t0, :t1, offset)
      end
    ]
  end

  @doc """
  The seam's cartridge arm: a store below `0x8000`, decoded.

  `a0` holds the guest address and `t0` the byte, and the byte was **not**
  stored -- `Atomboy.Native.Bus.write/2` skips the store for this range. Leaves
  by `done`, whatever it decided.

  Without a cartridge the arm is a single jump: a store into ROM is then what it
  has always been, a store that does not happen.

  Clobbers `t0`, `t1` and `t2`.
  """
  @spec handle(binary() | nil, atom()) :: [Asm.item()]
  def handle(nil, done), do: [Asm.label(:cart_write), Asm.j(done)]

  def handle(rom, done) when is_binary(rom) do
    mask = banks(rom) - 1

    [
      Asm.label(:cart_write),

      # Only 0x2000-0x3FFF says anything this stage understands. Below it is the
      # save-RAM enable, above it the RAM bank and the MBC3 latch -- all three
      # ignored, and all three leaving the byte unwritten, which is already what
      # hardware does with them.
      RV32.li(:t1, 0x2000),
      Asm.bltu(:a0, :t1, done),
      RV32.li(:t1, 0x4000),
      Asm.bgeu(:a0, :t1, done),

      # The two clamps, in the order the oracle applies them. A `bne` skipping a
      # single `li` is `max(x, 1)` for a value that is almost never zero.
      RV32.andi(:t0, :t0, 0x1F),
      RV32.bne(:t0, :zero, 8),
      RV32.li(:t0, 1),
      RV32.andi(:t0, :t0, mask),
      RV32.bne(:t0, :zero, 8),
      RV32.li(:t0, 1),

      # The bias the page table wants: where the bank sits in the ROM, minus
      # where it will sit in the guest.
      RV32.slli(:t0, :t0, 14),
      Asm.la(:t1, :cart_rom),
      RV32.add(:t0, :t1, :t0),
      RV32.li(:t1, @window),
      RV32.sub(:t0, :t0, :t1),

      # Four words, and the bank has changed.
      RV32.addi(:t1, Regs.pages(), 4 * 4),
      for offset <- 0..12//4 do
        RV32.sw(:t0, :t1, offset)
      end,
      Asm.j(done)
    ]
  end

  @doc """
  The flat 64 KB's cartridge half: bank 0, then bank 1.

  The image still carries it, and not out of habit. The guest's ROM range is
  read through the page tables and never through these bytes, but the run hands
  the 64 KB back at the end and every equivalence test compares it against the
  oracle's memory there -- which holds the cartridge as first mapped. A banked
  read that wrongly fell through to flat memory would find the right bytes for
  bank 1 and the wrong ones for every other bank, so the copy is also what makes
  that failure loud instead of subtle.
  """
  @spec resident(binary()) :: binary()
  def resident(rom) when is_binary(rom) do
    _ = banks(rom)
    :binary.part(rom, 0, 2 * @bank_size)
  end
end
