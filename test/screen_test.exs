defmodule Atomboy.ScreenTest do
  @moduledoc """
  The golden test of the rendering: the exact frame blargg displays.

  After 900 frames of `06-ld r,r`, the screen shows "06-ld r,r" then
  "Passed" in background tiles — readable text, rendered pixel by pixel.
  The CRC freezes that frame: any drift in the PPU (palette, scrolling,
  tile addressing, bit order) breaks here, with a clean starting point for
  the diff.

  A *deliberate* change to the rendering updates the CRC by regenerating:

      MIX_ENV=dev mix run -e '{f, _, _} = Atomboy.Screen.run(rom, 900); ...crc32...'

  and by reading the screen back with your own eyes through
  `mix atomboy.screen` — the text must stay readable, which is the whole
  value of this ROM as a reference.
  """

  use ExUnit.Case, async: true

  @moduletag :blargg
  @moduletag timeout: 300_000

  @rom "test/fixtures/gb-test-roms/cpu_instrs/individual/06-ld r,r.gb"
  @golden_crc 0xF8C8FA9B

  test "the 06-ld r,r screen shows its verdict, pixel for pixel" do
    # dmg: true — the golden frame is that of a monochrome machine; the
    # blargg ROM claims CGB compatibility and would switch to color.
    {frame, _state, _ram} = Atomboy.Screen.run(@rom, 900, dmg: true)

    assert byte_size(frame) == 160 * 144
    assert :erlang.crc32(frame) == @golden_crc
  end

  @acid2 "test/fixtures/dmg-acid2.gb"
  @acid2_crc 0x9F51DD25

  test "dmg-acid2 draws its face, pixel for pixel" do
    # The PPU acceptance test: every feature of the face names the feature
    # that breaks it — 8×16 sprites, mirroring, priorities, the window and
    # its internal line counter. One CRC for the whole rendering.
    {frame, _state, _ram} = Atomboy.Screen.run(@acid2, 120)
    assert :erlang.crc32(frame) == @acid2_crc
  end

  @cgb_acid2 "test/fixtures/cgb-acid2.gbc"
  @cgb_acid2_crc 0x36574FC1

  test "cgb-acid2 draws its face in color, pixel for pixel" do
    # The color PPU acceptance test: verified at zero pixels of difference
    # against the official reference (img/reference.png, with the 5→8 bit
    # rounding tolerance) the day this CRC was frozen. Tile attributes in
    # bank 1, eight RGB555 palettes, GBC priorities, sprites by OAM index —
    # every feature of the face names one of them.
    {frame, _state, _ram} = Atomboy.Screen.run(@cgb_acid2, 120)
    assert byte_size(frame) == 2 * 160 * 144
    assert :erlang.crc32(frame) == @cgb_acid2_crc
  end

  test "a rendered frame contains DMG shades only" do
    {frame, _state, _ram} = Atomboy.Screen.run(@rom, 60, dmg: true)
    assert for(<<shade <- frame>>, shade > 3, do: shade) == []
  end
end
