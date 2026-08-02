defmodule Potion.TilesTest do
  use ExUnit.Case, async: true

  doctest Potion.Tiles

  @fixtures Path.join(__DIR__, "fixtures")

  defp read(name), do: Potion.Tiles.read!(Path.join(@fixtures, "#{name}.png"))

  describe "cutting a drawing into tiles" do
    # `shades.png` is 16x8 and was written grey by grey rather than drawn, so
    # every byte below can be worked out by hand and none of it is a recording
    # of what this module happened to produce.
    #
    #   tile 0   four horizontal bands, two rows each: shades 0, 1, 2, 3
    #   tile 1   the left four columns black, the right four white
    #
    # The four shades are the point. A black-and-white fixture cannot tell the
    # two bitplanes apart — swapping them leaves 0 and 3 exactly where they were
    # and only moves 1 and 2 — so a sheet drawn in two colours would have passed
    # this module with the planes backwards, and every four-shade drawing after
    # it would have come out with its midtones exchanged.
    test "a row's two bytes are the low plane then the high one" do
      [bands, _split] = read("shades")

      assert bands ==
               <<
                 0x00,
                 0x00,
                 0x00,
                 0x00,
                 0xFF,
                 0x00,
                 0xFF,
                 0x00,
                 0x00,
                 0xFF,
                 0x00,
                 0xFF,
                 0xFF,
                 0xFF,
                 0xFF,
                 0xFF
               >>
    end

    # Shade 1 is a one in the low plane and a zero in the high one; shade 2 is
    # the other way about. Stated on its own because the assertion above would
    # also pass if both planes were built from the same bit.
    test "shade 1 and shade 2 are not the same byte pattern" do
      [bands, _split] = read("shades")

      assert binary_part(bands, 4, 2) == <<0xFF, 0x00>>
      assert binary_part(bands, 8, 2) == <<0x00, 0xFF>>
    end

    test "the leftmost pixel is the high bit" do
      [_bands, split] = read("shades")

      # Black on the left four columns, white on the right: 0xF0 and not 0x0F.
      assert split == :binary.copy(<<0xF0, 0xF0>>, 8)
    end

    test "tiles come out left to right, then down" do
      # gray1 is one black square then one white one, side by side.
      assert [black, white] = read("gray1")
      assert black == :binary.copy(<<0xFF>>, 16)
      assert white == <<0::128>>
    end

    test "a sheet gives width times height over sixty-four tiles" do
      # noise.png is 24x16: three across, two down.
      tiles = read("noise")

      assert length(tiles) == 6
      assert Enum.all?(tiles, &(byte_size(&1) == 16))
    end
  end

  describe "the shade a colour becomes" do
    test "brightness is banded, and the bands do not move with the drawing" do
      assert Potion.Tiles.shade({255, 255, 255, 255}) == 0
      assert Potion.Tiles.shade({192, 192, 192, 255}) == 0
      assert Potion.Tiles.shade({191, 191, 191, 255}) == 1
      assert Potion.Tiles.shade({128, 128, 128, 255}) == 1
      assert Potion.Tiles.shade({127, 127, 127, 255}) == 2
      assert Potion.Tiles.shade({64, 64, 64, 255}) == 2
      assert Potion.Tiles.shade({63, 63, 63, 255}) == 3
      assert Potion.Tiles.shade({0, 0, 0, 255}) == 3
    end

    # Colour 0 is the transparent one for sprites, so this is what lets a sprite
    # drawn on a transparent background behave like one without anybody being
    # told about palettes.
    test "a pixel less than half opaque is the transparent shade" do
      assert Potion.Tiles.shade({0, 0, 0, 0}) == 0
      assert Potion.Tiles.shade({0, 0, 0, 127}) == 0
      assert Potion.Tiles.shade({0, 0, 0, 128}) == 3
    end

    test "green weighs more than blue, as an eye has it" do
      # Equal channel values that an average would call the same shade. Rec. 601
      # puts pure green five bands above pure blue.
      assert Potion.Tiles.shade({0, 255, 0, 255}) < Potion.Tiles.shade({0, 0, 255, 255})
    end
  end

  describe "what it refuses" do
    test "a drawing that is not a whole number of tiles, with the two sizes that fit" do
      image = %{width: 20, height: 8, pixels: List.duplicate({0, 0, 0, 255}, 160)}

      assert_raise ArgumentError, ~r/20x8.*16x8.*24x8/s, fn ->
        Potion.Tiles.cut!(image, "odd.png")
      end
    end
  end
end
