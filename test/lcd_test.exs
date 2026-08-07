defmodule Atomboy.LCDTest do
  @moduledoc """
  The panel, checked on its promises rather than on its constants.

  The numbers in `Atomboy.LCD` are meant to be moved — asserting on them
  would only freeze a judgement of taste. What is asserted here is what the
  panel *claims to be*: that `:raw` changes nothing, that the shades stay
  ordered, that the dial holds the darkest one still, and that the color
  table caps its whites where a real Game Boy Color capped them.
  """

  use ExUnit.Case, async: true

  import Bitwise

  alias Atomboy.LCD
  alias Atomboy.Screen

  # Rec. 601 luminance, the same weighting the panel uses to desaturate.
  defp luma(<<r, g, b>>), do: 0.299 * r + 0.587 * g + 0.114 * b

  defp shades(preset), do: LCD.compile(preset) |> Map.fetch!(:shades) |> Tuple.to_list()

  describe "raw" do
    test "reproduces the historical palettes byte for byte" do
      assert shades(:raw) == [
               <<0x9B, 0xBC, 0x0F>>,
               <<0x8B, 0xAC, 0x0F>>,
               <<0x30, 0x62, 0x30>>,
               <<0x0F, 0x38, 0x0F>>
             ]

      assert LCD.compile(:raw, :gray).shades ==
               {<<0xFF, 0xFF, 0xFF>>, <<0xAA, 0xAA, 0xAA>>, <<0x55, 0x55, 0x55>>, <<0, 0, 0>>}
    end

    test "carries no color table — a monochrome game never reads one" do
      assert LCD.compile(:raw, :dmg, true).colors == nil
    end

    test "renders a frame exactly as the palette alone does" do
      frame = for shade <- 0..3, _ <- 1..(160 * 36), into: <<>>, do: <<shade>>

      assert Screen.to_rgb(frame, :dmg, LCD.compile(:raw, :dmg)) == Screen.to_rgb(frame, :dmg)
      assert Screen.to_rgb(frame, :gray, LCD.compile(:raw, :gray)) == Screen.to_rgb(frame, :gray)
    end
  end

  describe "the panels" do
    test "keep the four shades ordered, brightest to darkest" do
      for preset <- LCD.presets() do
        lumas = Enum.map(shades(preset), &luma/1)

        assert lumas == Enum.sort(lumas, :desc),
               "#{preset} does not descend: #{inspect(lumas)}"

        assert Enum.uniq(lumas) == lumas, "#{preset} has two identical shades"
      end
    end

    test "separate shades 0 and 1 further than the web's green does" do
      # The complaint that started this: on the mythical #9BBC0F palette the
      # two lightest shades sit fourteen points of luminance apart, which is
      # not enough to judge artwork by. A modelled panel must do better.
      [raw0, raw1 | _] = Enum.map(shades(:raw), &luma/1)
      assert_in_delta raw1 - raw0, -14.0, 1.0

      for preset <- LCD.presets() -- [:raw] do
        [l0, l1 | _] = Enum.map(shades(preset), &luma/1)
        assert l0 - l1 > 20.0, "#{preset} separates 0 and 1 by only #{l0 - l1}"
      end
    end

    test "never clip to pure black or pure white — a reflective panel does neither" do
      for preset <- LCD.presets() -- [:raw],
          shade <- shades(preset) do
        assert luma(shade) > 4.0, "#{preset} clipped to black"
        assert luma(shade) < 252.0, "#{preset} clipped to white"
      end
    end
  end

  describe "the color table" do
    test "holds one entry per RGB555 color" do
      lcd = LCD.compile(:cgb, :dmg, true)
      assert byte_size(lcd.colors) == 32768 * 3
    end

    test "caps white where the hardware caps it" do
      # The correction ares applies clamps at 960 and shifts down two bits:
      # a saturated channel arrives at 240, never at 255. The warm bias and
      # the black lift move it a little, never all the way home.
      white = Screen.to_rgb(white_frame(), :dmg, LCD.compile(:cgb, :dmg, true))
      <<r, g, b>> = binary_part(white, 0, 3)

      for channel <- [r, g, b] do
        assert channel < 255, "a CGB white reached #{channel}"
        assert channel > 200, "a CGB white fell to #{channel}"
      end
    end

    test "leaves the order of the ramp intact" do
      lcd = LCD.compile(:cgb, :dmg, true)

      ramp =
        for v <- [0, 8, 16, 24, 31] do
          color = v ||| v <<< 5 ||| v <<< 10
          luma(binary_part(lcd.colors, color * 3, 3))
        end

      assert ramp == Enum.sort(ramp)
    end

    test "is what Screen.to_rgb reads for a color frame" do
      lcd = LCD.compile(:cgb, :dmg, true)
      rendered = Screen.to_rgb(white_frame(), :dmg, lcd)

      assert byte_size(rendered) == 160 * 144 * 3
      assert binary_part(rendered, 0, 3) == binary_part(lcd.colors, 0x7FFF * 3, 3)
    end

    test "is skipped when the panel carries none" do
      # No table: the historical widening of five bits to eight, unchanged.
      assert Screen.to_rgb(white_frame(), :dmg, LCD.compile(:dmg, :dmg, false)) ==
               Screen.to_rgb(white_frame(), :dmg)
    end
  end

  describe "next/2" do
    test "cycles both ways through the presets" do
      presets = LCD.presets()
      first = hd(presets)
      last = List.last(presets)

      assert LCD.next(last, 1) == first
      assert LCD.next(first, -1) == last
      assert presets |> Enum.reduce(first, fn _, p -> LCD.next(p, 1) end) == first
    end
  end

  # A full frame of RGB555 white, little-endian — two bytes per pixel.
  defp white_frame, do: :binary.copy(<<0x7FFF::16-little>>, 160 * 144)
end
