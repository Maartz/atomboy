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

  describe "the response curve" do
    # A frame of one shade, corner to corner.
    defp flat(shade), do: :binary.copy(<<shade>>, 160 * 144)

    test "raw and colour frames pass through untouched, state unchanged" do
      frame = flat(2)
      raw = LCD.compile(:raw, :dmg)

      assert Screen.to_rgb(frame, :dmg, raw, nil) == {Screen.to_rgb(frame, :dmg, raw), nil}
      assert Screen.to_rgb(frame, :dmg, nil, nil) == {Screen.to_rgb(frame, :dmg), nil}

      color = LCD.compile(:cgb, :dmg, true)

      assert Screen.to_rgb(white_frame(), :dmg, color, nil) ==
               {Screen.to_rgb(white_frame(), :dmg, color), nil}
    end

    test "the first frame arrives ghost-free" do
      # A nil state seeds from the frame itself: a panel left on this
      # picture, already settled — pixel for pixel the tableless rendering.
      lcd = LCD.compile(:dmg)
      frame = for shade <- 0..3, _ <- 1..(160 * 36), into: <<>>, do: <<shade>>

      {rgb, state} = Screen.to_rgb(frame, :dmg, lcd, nil)
      assert rgb == Screen.to_rgb(frame, :dmg, lcd)
      assert byte_size(state) == 160 * 144 * 4
    end

    test "the ramp passes through the four shades exactly" do
      lcd = LCD.compile(:pocket)

      for {shade, level} <- [{0, 0}, {1, 85}, {2, 170}, {3, 255}] do
        assert elem(lcd.ramp, level) == elem(lcd.shades, shade)
      end
    end

    test "darkening runs ahead of brightening — the asymmetry" do
      # One pixel going light→dark, one going dark→light, one step each:
      # the darkening pixel must have covered more of its journey. This is
      # the inversion most emulators get wrong, frozen into a test.
      lcd = LCD.compile(:dmg)

      {_, settled_light} = Screen.to_rgb(flat(0), :dmg, lcd, nil)
      {_, settled_dark} = Screen.to_rgb(flat(3), :dmg, lcd, nil)

      {_, darkening} = Screen.to_rgb(flat(3), :dmg, lcd, settled_light)
      {_, brightening} = Screen.to_rgb(flat(0), :dmg, lcd, settled_dark)

      <<down::float-32-native, _::binary>> = darkening
      <<up::float-32-native, _::binary>> = brightening

      # Both left 0 or 255 heading for the other end; the fraction covered:
      assert down / 255 > (255 - up) / 255
      assert down / 255 > 0.4
      assert (255 - up) / 255 < 0.4
    end

    test "a held frame converges to the settled colour" do
      lcd = LCD.compile(:dmg)
      {_, state} = Screen.to_rgb(flat(0), :dmg, lcd, nil)
      target = flat(3)

      {rgb, _state} =
        Enum.reduce(1..90, {nil, state}, fn _, {_, state} ->
          Screen.to_rgb(target, :dmg, lcd, state)
        end)

      # A second and a half of the same picture: the float state has carried
      # the pixel all the way home — no byte-quantization stall.
      assert binary_part(rgb, 0, 3) == elem(lcd.shades, 3)
    end

    test "the state has one float per pixel and stays in range" do
      lcd = LCD.compile(:cgb)
      {_, state} = Screen.to_rgb(flat(1), :dmg, lcd, nil)
      {_, state} = Screen.to_rgb(flat(2), :dmg, lcd, state)

      for <<s::float-32-native <- state>> do
        assert s >= 0.0 and s <= 255.0
      end
    end
  end

  describe "the dial" do
    test "turned up, every shade darkens — shade 0 most, shade 3 least" do
      rest = LCD.compile(:dmg).shades |> Tuple.to_list() |> Enum.map(&luma/1)
      inked = LCD.compile(:dmg, :dmg, false, 90).shades |> Tuple.to_list() |> Enum.map(&luma/1)

      deltas = Enum.zip_with(rest, inked, &(&1 - &2))

      assert Enum.all?(deltas, &(&1 >= 0)), "a shade brightened: #{inspect(deltas)}"

      # The article's measurement, as a shape: the lightest shade moves
      # more than twice as far as the darkest, which is already home.
      assert List.first(deltas) > 2 * List.last(deltas),
             "no asymmetry: #{inspect(deltas)}"
    end

    test "turned down, the image sinks into the reflector" do
      rest = LCD.compile(:dmg).shades
      pale = LCD.compile(:dmg, :dmg, false, 10).shades

      # The darkest shade pales — pulled toward the bright background.
      assert luma(elem(pale, 3)) > luma(elem(rest, 3))
    end

    test "raw has no panel, so no dial" do
      assert LCD.compile(:raw, :dmg, false, 90).shades == LCD.compile(:raw).shades
    end

    test "the colour table follows the dial" do
      rest = LCD.compile(:cgb, :dmg, true)
      inked = LCD.compile(:cgb, :dmg, true, 90)

      white = 0x7FFF * 3
      assert luma(binary_part(inked.colors, white, 3)) < luma(binary_part(rest.colors, white, 3))
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
