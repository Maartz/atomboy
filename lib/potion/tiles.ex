defmodule Potion.Tiles do
  @moduledoc """
  A drawing, cut into the sixteen-byte tiles the console reads.

  `Potion.PNG` gives pixels; this gives tiles. Between the two sit three
  decisions, and they are the whole of this module: how a colour becomes one of
  four shades, in what order the tiles are cut, and how eight pixels become two
  bytes.

  ## Four shades, by brightness and not by rank

  The DMG draws four shades and the kernel installs the identity palette, so
  shade 0 is the lightest and shade 3 the darkest. A pixel's brightness is
  banded into those four:

      192-255  shade 0     128-191  shade 1
       64-127  shade 2       0-63   shade 3

  Banding absolute brightness rather than ranking the colours found is the
  choice worth defending. A ranking would make the same drawing mean different
  things depending on what else was on the sheet: black on white would come out
  0 and 1 on a two-colour image and 0 and 3 on a four-colour one, so adding a
  grey somewhere would silently darken every tile already drawn. Bands do not
  move.

  It also means white is shade 0 without anybody saying so, which matters more
  than it looks: colour 0 is the transparent one for sprites, so a sprite drawn
  on white gets a transparent background by the ordinary act of drawing it on
  white.

  A pixel less than half opaque is shade 0 for the same reason — that is what
  transparency means on this hardware, and it is the only thing alpha can mean.

  ## Reading order

  Left to right, then down: the tile at column 1 of row 0 is the second, not the
  ninth. That is how every tile sheet is laid out and how names are handed to
  tiles in `Potion`.

  ## Two bytes a row

  A tile is 8x8 and a pixel is two bits, but the two bits are not adjacent. The
  console stores a row as two bytes, the first holding every pixel's low bit and
  the second every pixel's high bit, leftmost pixel in bit 7 of each. So shade 2
  is a zero in the first byte and a one in the second — a fact that is invisible
  in any single tile and unmistakable across a whole sheet, since getting it
  backwards swaps shades 1 and 2 everywhere and leaves 0 and 3 correct.
  """

  alias Potion.PNG

  @tile 8
  @bytes_per_tile 16

  @doc "The side of a tile in pixels, and the number of bytes one occupies."
  @spec tile_size() :: {pos_integer(), pos_integer()}
  def tile_size, do: {@tile, @bytes_per_tile}

  @doc """
  Reads an image and cuts it into tiles, in reading order.

  Returns a list of sixteen-byte binaries, each ready to be copied into VRAM as
  it stands.

      tiles = Potion.Tiles.read!("art/pong.png")

  A 16x8 drawing gives two of them: the left square first, then the right.
  """
  @spec read!(Path.t()) :: [binary()]
  def read!(path) do
    path |> PNG.read!() |> cut!(path)
  end

  @doc """
  The same on an image already read. `source` only ever appears in messages.
  """
  @spec cut!(PNG.t(), String.t()) :: [binary()]
  def cut!(image, source \\ "<image>") do
    unless rem(image.width, @tile) == 0 and rem(image.height, @tile) == 0 do
      raise ArgumentError, """
      #{source} is #{image.width}x#{image.height}, and a tile is 8x8.

      Both sides have to be a whole number of tiles. The nearest that fit are \
      #{div(image.width, @tile) * @tile}x#{div(image.height, @tile) * @tile} and \
      #{(div(image.width - 1, @tile) + 1) * @tile}x#{(div(image.height - 1, @tile) + 1) * @tile}.
      """
    end

    shades = Enum.map(image.pixels, &shade/1)
    across = div(image.width, @tile)
    down = div(image.height, @tile)

    for row <- 0..(down - 1)//1, column <- 0..(across - 1)//1 do
      encode(shades, image.width, row, column)
    end
  end

  @doc """
  The shade a pixel becomes: 0 the lightest, 3 the darkest.

      iex> Potion.Tiles.shade({255, 255, 255, 255})
      0
      iex> Potion.Tiles.shade({0, 0, 0, 255})
      3
      iex> Potion.Tiles.shade({0, 0, 0, 0})
      0
  """
  @spec shade(PNG.pixel()) :: 0..3
  def shade({_r, _g, _b, alpha}) when alpha < 128, do: 0

  def shade({r, g, b, _alpha}) do
    # Rec. 601, which weighs green the way an eye does. Averaging the three
    # instead would put a saturated green and a mid grey in different bands from
    # the ones a person sorting the sheet by eye would have put them in.
    luma = div(299 * r + 587 * g + 114 * b, 1000)

    3 - div(luma, 64)
  end

  @doc """
  One 8x8 grid of shades into the console's sixteen bytes — the two bitplanes,
  a row at a time, leftmost pixel in bit 7.

  The private path below encodes straight out of an image; this public door is
  for callers that rework grids first — a screen conversion deduplicating
  tiles holds grids, not images.
  """
  @spec encode_grid([[0..3]]) :: binary()
  def encode_grid(rows) do
    for line <- rows, into: <<>> do
      low = Enum.reduce(line, 0, fn shade, acc -> acc * 2 + rem(shade, 2) end)
      high = Enum.reduce(line, 0, fn shade, acc -> acc * 2 + div(shade, 2) end)
      <<low, high>>
    end
  end

  # One tile, from the flat list of shades. The two planes are built a row at a
  # time and the leftmost pixel lands in bit 7, which is the order the console
  # reads them out in.
  defp encode(shades, width, row, column) do
    for line <- 0..(@tile - 1)//1, into: <<>> do
      start = (row * @tile + line) * width + column * @tile

      pixels = shades |> Enum.slice(start, @tile)

      low = Enum.reduce(pixels, 0, fn shade, acc -> acc * 2 + rem(shade, 2) end)
      high = Enum.reduce(pixels, 0, fn shade, acc -> acc * 2 + div(shade, 2) end)

      <<low, high>>
    end
  end
end
