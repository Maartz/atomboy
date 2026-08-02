defmodule Potion.PNGTest do
  use ExUnit.Case, async: true

  @fixtures Path.join(__DIR__, "fixtures")

  # Each fixture is a PNG next to the pixels ImageMagick reads out of it, one
  # `RRGGBB` a line in reading order. The pair was made once, by a tool that
  # shares no code with this one, and committed — which is the only reason these
  # tests say anything. A decoder checked against its own encoder agrees with
  # itself about a format neither of them may have read correctly.
  #
  # The five between them cover the four bit depths a drawing tool emits, the
  # five colour types, and — this is the part that had to be checked rather than
  # hoped for — every one of PNG's five scanline filters:
  #
  #     gray1     depth 1, grayscale     filter 0
  #     indexed   depth 2, palette       filter 0
  #     rgb       depth 8, RGB           filters 1 and 2
  #     rgba      depth 8, RGBA          filters 1 and 2
  #     noise     depth 8, RGB           filters 1, 2, 3 and 4
  #
  # The plasma is there for the last line alone. The flat images are all written
  # unfiltered, so without it Average would have run on nothing and Paeth would
  # never have been called at all.
  @cases ~w(gray1 indexed rgb rgba noise)

  defp expected(name) do
    @fixtures
    |> Path.join("#{name}.pixels")
    |> File.read!()
    |> String.split("\n", trim: true)
  end

  defp read(name), do: Potion.PNG.read!(Path.join(@fixtures, "#{name}.png"))

  defp hex({r, g, b, _alpha}) do
    [r, g, b]
    |> Enum.map_join(&(&1 |> Integer.to_string(16) |> String.pad_leading(2, "0")))
    |> String.upcase()
  end

  describe "reading what a drawing tool wrote" do
    for name <- @cases do
      test "#{name} reads pixel for pixel as ImageMagick does" do
        image = read(unquote(name))
        assert Enum.map(image.pixels, &hex/1) == expected(unquote(name))
      end
    end

    test "the pixels are in reading order, and there are width times height" do
      image = read("gray1")

      assert image.width == 16
      assert image.height == 8
      assert length(image.pixels) == 128

      # The fixture is a black square against white, left half filled. That the
      # 8th pixel is black and the 9th white is what says the row was walked
      # left to right, and not, say, unpacked from the low bit of each byte
      # upward -- which reads plausibly and mirrors every tile.
      assert {0, 0, 0, 255} = Enum.at(image.pixels, 7)
      assert {255, 255, 255, 255} = Enum.at(image.pixels, 8)
    end

    test "a bit depth below eight is scaled up, not left as it was found" do
      # gray1 stores one bit a pixel. Read literally, white would be 1 — and a
      # shade ordering that sorted by brightness would still put it in the right
      # place, so nothing downstream would notice until an image mixed depths.
      assert read("gray1").pixels |> Enum.uniq() |> Enum.sort() ==
               [{0, 0, 0, 255}, {255, 255, 255, 255}]
    end
  end

  describe "what it refuses" do
    test "a file that is not a PNG" do
      assert_raise ArgumentError, ~r/does not begin with a PNG signature/, fn ->
        Potion.PNG.decode!("GIF89a and the rest of it", "not-a.png")
      end
    end

    test "a missing file says so before it says anything about PNG" do
      assert_raise ArgumentError, ~r/no such image/, fn ->
        Potion.PNG.read!(Path.join(@fixtures, "nothing-here.png"))
      end
    end

    # The two refusals are stated in the moduledoc, so they are stated here too:
    # a message that names the fix is the whole benefit of refusing rather than
    # decoding something half-right.
    test "an interlaced file, by name, with the way out" do
      png = with_header(read_bytes("rgb"), fn <<w::32, h::32, d, c, z1, z2, _>> ->
        <<w::32, h::32, d, c, z1, z2, 1>>
      end)

      assert_raise ArgumentError, ~r/interlaced.*without interlacing/s, fn ->
        Potion.PNG.decode!(png, "interlaced.png")
      end
    end

    test "sixteen bits a sample, by name, with the reason" do
      png = with_header(read_bytes("rgb"), fn <<w::32, h::32, _d, c, z1, z2, i>> ->
        <<w::32, h::32, 16, c, z1, z2, i>>
      end)

      assert_raise ArgumentError, ~r/sixteen bits a sample/, fn ->
        Potion.PNG.decode!(png, "deep.png")
      end
    end
  end

  defp read_bytes(name), do: File.read!(Path.join(@fixtures, "#{name}.png"))

  # Rewrites the thirteen bytes of IHDR in place. The CRC that follows is left
  # wrong on purpose: this reader does not check them, and a test that had to
  # recompute one would be asserting that it does.
  defp with_header(<<signature::binary-8, 13::32, "IHDR", header::binary-13, rest::binary>>, fun) do
    <<signature::binary, 13::32, "IHDR", fun.(header)::binary, rest::binary>>
  end
end
