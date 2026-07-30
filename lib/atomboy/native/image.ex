defmodule Atomboy.Native.Image do
  @moduledoc """
  The bootable image -- raw binary, no C compiler and no linker.

  qemu's `virt` board starts the processor at `0x8000_0000`, exactly where
  `-kernel` drops a binary file. So there is nothing to link: the first byte
  `Atomboy.Native.Asm` emits is the first instruction executed.

  That is what makes the harness bearable. No cross toolchain to install, no
  linker script to maintain, no object format to produce -- Elixir emits bytes
  and qemu runs them.

  ## The `virt` memory map

      0x0010_0000  sifive_test  -- writing 0x5555 there powers the machine off
      0x1000_0000  16550 UART   -- +0 data, +5 status
      0x8000_0000  RAM, and our image

  The UART wants bit 5 of its status register polled ("transmit register empty")
  before each byte. qemu would accept a write without the wait; real hardware
  would not, and this routine will end up on real hardware.

  ## What the runtime provides

  `putc` writes a byte, `puts` a string, `poweroff` ends the machine. These are
  the project's only I/O primitives: everything coming back from the guest --
  vector results, registers, memory hashes -- goes through that one byte.
  """

  alias Atomboy.Native.Asm
  alias Atomboy.Native.RV32

  @base 0x8000_0000
  @uart 0x1000_0000
  @test_device 0x0010_0000
  @stack_top 0x8010_0000

  @doc "The image's load address."
  @spec base() :: non_neg_integer()
  def base, do: @base

  @doc """
  Builds a complete image: prelude, code, runtime, data.

  The code gets control with the stack installed; it ends by jumping to
  `:poweroff`, or by falling into it.

  Data comes **after** all the code, and that is not cosmetic: RISC-V
  conditional branches only reach ±4 KB. Slipping 64 KB of emulated memory into
  the middle of the code would put every branch spanning it out of range, and
  the assembler would say so -- but much later, once the table is full.
  """
  @spec build([Asm.item()], [Asm.item()]) :: Atomboy.Native.Asm.assembled()
  def build(code, data \\ []) do
    Asm.assemble([prelude(), code, runtime(), data], @base)
  end

  @doc """
  The smoke image: it says hello and powers off.

  It emulates nothing. Its job is to settle, once and for all, the questions no
  amount of documentation answers with certainty -- does the processor really
  start at `0x8000_0000`, does the UART want its status polled, does
  `sifive_test` hand control back cleanly.
  """
  @spec smoke() :: Atomboy.Native.Asm.assembled()
  def smoke do
    build([
      RV32.li(:a0, ?O),
      Asm.call(:putc),
      RV32.li(:a0, ?K),
      Asm.call(:putc),
      RV32.li(:a0, ?\n),
      Asm.call(:putc),
      Asm.j(:poweroff)
    ])
  end

  # ══ The prelude ══════════════════════════════════════════════════════════════

  defp prelude do
    [
      Asm.label(:_start),
      RV32.li(:sp, @stack_top)
    ]
  end

  # ══ The runtime ══════════════════════════════════════════════════════════════

  @doc """
  The runtime, exposed for images that lay themselves out.
  """
  @spec runtime() :: [Asm.item()]
  def runtime do
    [putc(), puts(), poweroff()]
  end

  # a0: the byte to emit. Clobbers t0 and t1, preserves everything else.
  defp putc do
    [
      Asm.label(:putc),
      RV32.li(:t0, @uart),
      Asm.label(:putc_wait),
      RV32.lbu(:t1, :t0, 5),
      RV32.andi(:t1, :t1, 0x20),
      Asm.beqz(:t1, :putc_wait),
      RV32.sb(:a0, :t0, 0),
      RV32.ret()
    ]
  end

  # a1: a string's address, a2: its length. Clobbers a0, t0, t1, t2.
  defp puts do
    [
      Asm.label(:puts),
      RV32.mv(:t2, :ra),
      Asm.label(:puts_loop),
      Asm.beqz(:a2, :puts_done),
      RV32.lbu(:a0, :a1, 0),
      Asm.call(:putc),
      RV32.addi(:a1, :a1, 1),
      RV32.addi(:a2, :a2, -1),
      Asm.j(:puts_loop),
      Asm.label(:puts_done),
      RV32.jr(:t2)
    ]
  end

  # The trailing loop is not superstition: writing to sifive_test does not stop
  # the processor, it asks qemu to hand control back. The next few instructions
  # run anyway, and without the loop they would be whatever follows in the image.
  defp poweroff do
    [
      Asm.label(:poweroff),
      RV32.li(:t0, @test_device),
      RV32.li(:t1, 0x5555),
      RV32.sw(:t1, :t0, 0),
      Asm.label(:poweroff_loop),
      Asm.j(:poweroff_loop)
    ]
  end
end
