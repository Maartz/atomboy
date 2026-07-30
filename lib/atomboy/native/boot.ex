defmodule Atomboy.Native.Boot do
  @moduledoc """
  The I/O registers a DMG hands the cartridge, written out -- a harness fixture.

  Two emulators can only be compared if they start from the same bytes, and this
  project's two memory models disagree about bytes nobody wrote. `Atomboy.Screen`
  runs on `Atomboy.CPU.CartLoop`: a map of writes, where an address never written
  reads back 0xFF from the open bus, and where some readers substitute a default
  instead of asking. The native core runs on a flat 64 KB array. Where the two
  models differ, they differ silently:

    * `Atomboy.Timer` reads an absent TAC as zero -- a timer at rest -- where the
      CPU reading the same absent address gets 0xFF, which is an *enabled* timer
      at the slowest rate;
    * `Atomboy.PPU` reads an absent BGP, OBP0 or OBP1 as 0xE4, the identity
      palette, where the open bus gives 0xFF -- the palette that maps every colour
      to the darkest shade. A frame compared without pinning those three differs
      in **every pixel**, and the diff says nothing about the renderer;
    * `Atomboy.Screen` spells LCDC's default 0x91 in `step_line/4`.

  One of the two readers is wrong about each of those registers. Writing them all
  down removes the question, and this module is where they are written down, once,
  because two harnesses had begun keeping their own list and a list kept twice
  drifts.

  ## What this is not

  It is **not** emulator behaviour, and it must not become any. Real games read
  these registers, and pre-seeding them into `Atomboy.Screen.boot_ram/2` would
  change what every ROM sees on its first frame -- which is a decision about
  fidelity, taken deliberately, with the golden CRC tests (dmg-acid2, blargg) as
  its judges. This map exists for harnesses and for native/Elixir comparisons,
  which is a narrower and much cheaper claim: that both sides be told the same
  thing.

  What the values *are* is nonetheless the post-boot state a real DMG leaves
  behind after its boot ROM has run, which is why they are worth having in one
  place rather than being whatever each test found convenient.
  """

  # 0xFF46 is deliberately absent: the OAM DMA register has no post-boot value
  # worth asserting, and writing it would ask the seam to perform a transfer
  # before a game has said anything.
  @io_state %{
    0xFF00 => 0xFF,
    0xFF04 => 0x00,
    0xFF05 => 0x00,
    0xFF06 => 0x00,
    0xFF07 => 0x00,
    0xFF0F => 0x00,
    0xFF40 => 0x91,
    0xFF41 => 0x00,
    0xFF42 => 0x00,
    0xFF43 => 0x00,
    0xFF44 => 0x00,
    0xFF45 => 0x00,
    0xFF47 => 0xE4,
    0xFF48 => 0xE4,
    0xFF49 => 0xE4,
    0xFF4A => 0x00,
    0xFF4B => 0x00,
    0xFFFF => 0x00
  }

  @doc """
  The post-boot I/O state, as a map an `Atomboy.Screen` memory can be merged with
  and a flat 64 KB can be built from.
  """
  @spec io_state() :: %{(0..0xFFFF) => 0..255}
  def io_state, do: @io_state
end
