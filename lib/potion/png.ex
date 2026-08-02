defmodule Potion.PNG do
  @moduledoc """
  A PNG, read down to its pixels — and no further.

  This module knows nothing about tiles, shades or the Game Boy. It takes the
  bytes of a file and gives back a width, a height and one `{r, g, b, a}` per
  pixel, in reading order. What that becomes is `Potion.Tiles`' business.

  ## Why this is written rather than imported

  `mix.exs` carries one dependency and says why: the emulator's core stays
  dependency-free. This runs in the compiler and not on the console, so that
  argument does not reach it — but the one below it does. A PNG of pixel art is
  a zlib stream, which Erlang already inflates, wrapped in a chunk format that
  fits on a page. Everything hard about PNG is in the parts this refuses.

  ## What it refuses, and why those are the right two

  Interlacing and sixteen-bit samples. Adam7 rearranges the image into seven
  passes and would double this module; sixteen bits a sample is a photographic
  format. Neither has ever been what a tile sheet is saved as, and refusing them
  by name costs a line and a good error message.

  Everything a drawing tool actually emits is here: bit depths 1, 2, 4 and 8,
  and the five colour types — grayscale, RGB, indexed, and the two with alpha.
  That list is not generosity. ImageMagick, asked for a two-colour 16x8 image,
  writes bit depth **1**, and a reader that only understood eight would have
  passed every fixture written by hand and refused the first file a real tool
  produced.
  """

  @signature <<0x89, ?P, ?N, ?G, 0x0D, 0x0A, 0x1A, 0x0A>>

  @typedoc "A pixel, eight bits a channel, alpha included even when the file had none."
  @type pixel :: {0..255, 0..255, 0..255, 0..255}

  @type t :: %{width: pos_integer(), height: pos_integer(), pixels: [pixel()]}

  @doc """
  Reads a PNG file into its pixels.

  Raises `ArgumentError` on anything that is not a PNG this module reads, and
  the message says which of the two refusals applied.
  """
  @spec read!(Path.t()) :: t()
  def read!(path) do
    unless File.regular?(path) do
      raise ArgumentError, "no such image: #{path}"
    end

    path |> File.read!() |> decode!(path)
  end

  @doc """
  The same, on bytes already in hand. `source` only ever appears in messages.
  """
  @spec decode!(binary(), String.t()) :: t()
  def decode!(bytes, source \\ "<binary>")

  def decode!(@signature <> rest, source) do
    chunks = chunks(rest, [])
    header = header!(chunks, source)

    palette = Enum.find_value(chunks, <<>>, fn {type, data} -> type == "PLTE" && data end)
    alphas = Enum.find_value(chunks, <<>>, fn {type, data} -> type == "tRNS" && data end)

    data =
      chunks
      |> Enum.filter(fn {type, _} -> type == "IDAT" end)
      |> Enum.map_join(fn {_, data} -> data end)
      |> :zlib.uncompress()

    pixels =
      header
      |> unfilter(data, source)
      |> Enum.flat_map(&pixels(&1, header, palette, alphas, source))

    %{width: header.width, height: header.height, pixels: pixels}
  end

  def decode!(_bytes, source) do
    raise ArgumentError, "#{source} does not begin with a PNG signature"
  end

  # ── The container ────────────────────────────────────────────────────────────

  # Length, type, payload, CRC. The CRC is skipped rather than checked: a
  # corrupt tile sheet fails at the inflate or draws visible nonsense, and
  # neither is a failure mode worth a table of polynomials to name earlier.
  defp chunks(<<length::32, type::binary-4, rest::binary>>, acc) do
    <<data::binary-size(length), _crc::32, tail::binary>> = rest
    chunks(tail, [{type, data} | acc])
  end

  defp chunks(_, acc), do: Enum.reverse(acc)

  defp header!(chunks, source) do
    case Enum.find(chunks, fn {type, _} -> type == "IHDR" end) do
      {_, <<width::32, height::32, depth, colour, 0, 0, interlace>>} ->
        if interlace != 0 do
          raise ArgumentError, """
          #{source} is interlaced, and this reader does not deinterlace.

          Adam7 splits the image into seven passes that have to be woven back \
          together. Save the file again without interlacing — every drawing tool \
          offers it, and for a tile sheet it was never buying anything.
          """
        end

        if depth == 16 do
          raise ArgumentError, """
          #{source} carries sixteen bits a sample, and this reader reads eight.

          That is a photographic depth, and a tile ends up as one of four shades \
          whatever it started as. Save it at eight bits or fewer.
          """
        end

        %{width: width, height: height, depth: depth, colour: colour}

      _ ->
        raise ArgumentError, "#{source} has no readable IHDR"
    end
  end

  # ── The filters ──────────────────────────────────────────────────────────────
  #
  # Every scanline is prefixed by the filter it was written with, and each one
  # predicts a byte from its neighbours: `a` to the left, `b` above, `c` above
  # left. Undoing them is the only part of PNG that has to be done in order —
  # a line cannot be read before the one above it has been.
  #
  # `step` is how far back "the left" is, in bytes: one whole pixel, or one byte
  # when a pixel is smaller than that. Filtering never looks inside a byte.

  defp unfilter(header, data, source) do
    step = max(div(bits_per_pixel(header), 8), 1)
    stride = div(header.width * bits_per_pixel(header) + 7, 8)

    {rows, _last} =
      Enum.map_reduce(0..(header.height - 1)//1, :binary.copy(<<0>>, stride), fn row, above ->
        start = row * (stride + 1)

        case data do
          <<_::binary-size(start), filter, raw::binary-size(stride), _::binary>> ->
            line = apply_filter(filter, raw, above, step, source)
            {line, line}

          _ ->
            raise ArgumentError, "#{source} ends in the middle of row #{row}"
        end
      end)

    rows
  end

  defp apply_filter(0, raw, _above, _step, _source), do: raw

  defp apply_filter(filter, raw, above, step, _source) when filter in 1..4 do
    bytes = :binary.bin_to_list(raw)
    up_row = :binary.bin_to_list(above)

    {undone, _} =
      bytes
      |> Enum.with_index()
      |> Enum.map_reduce([], fn {x, index}, done ->
        # `done` holds what has been decoded so far, most recent first, so the
        # byte one pixel to the left is exactly `step - 1` into it. The row above
        # is indexed directly, and both neighbours are zero off the left edge --
        # which is what makes the first pixel of a line decodable at all.
        left = if index >= step, do: Enum.at(done, step - 1), else: 0
        up = Enum.at(up_row, index, 0)
        up_left = if index >= step, do: Enum.at(up_row, index - step, 0), else: 0

        value =
          case filter do
            1 -> x + left
            2 -> x + up
            3 -> x + div(left + up, 2)
            4 -> x + paeth(left, up, up_left)
          end

        byte = rem(value, 256)
        {byte, [byte | done]}
      end)

    :binary.list_to_bin(undone)
  end

  defp apply_filter(filter, _raw, _above, _step, source) do
    raise ArgumentError, "#{source} uses filter #{filter}, which PNG does not define"
  end

  # The predictor that reads as arithmetic and is really a choice: of the three
  # neighbours, take the one closest to what they jointly predict.
  defp paeth(a, b, c) do
    p = a + b - c
    pa = abs(p - a)
    pb = abs(p - b)
    pc = abs(p - c)

    cond do
      pa <= pb and pa <= pc -> a
      pb <= pc -> b
      true -> c
    end
  end

  # ── The samples ──────────────────────────────────────────────────────────────

  defp bits_per_pixel(%{depth: depth, colour: colour}), do: depth * channels(colour)

  defp channels(0), do: 1
  defp channels(2), do: 3
  defp channels(3), do: 1
  defp channels(4), do: 2
  defp channels(6), do: 4

  defp channels(colour) do
    raise ArgumentError, "colour type #{colour} is not one PNG defines"
  end

  # One unfiltered scanline into pixels. Sub-byte depths are unpacked first, and
  # the trailing bits of the last byte are dropped -- a row of five pixels at two
  # bits a pixel occupies two bytes and means only the first five.
  defp pixels(line, header, palette, alphas, source) do
    line
    |> unpack(header.depth)
    |> Enum.chunk_every(channels(header.colour))
    |> Enum.take(header.width)
    |> Enum.map(&pixel(&1, header, palette, alphas, source))
  end

  defp unpack(line, 8), do: :binary.bin_to_list(line)

  defp unpack(line, depth) when depth in [1, 2, 4] do
    for <<value::size(depth) <- line>>, do: value
  end

  # Grayscale and RGB are scaled to eight bits, so a 1-bit image reads 0 and 255
  # rather than 0 and 1 -- which is what makes one ordering of shades work for
  # every depth.
  defp pixel([grey], %{colour: 0, depth: depth}, _palette, _alphas, _source) do
    value = scale(grey, depth)
    {value, value, value, 255}
  end

  defp pixel([grey, alpha], %{colour: 4, depth: depth}, _palette, _alphas, _source) do
    value = scale(grey, depth)
    {value, value, value, scale(alpha, depth)}
  end

  defp pixel([r, g, b], %{colour: 2, depth: depth}, _palette, _alphas, _source) do
    {scale(r, depth), scale(g, depth), scale(b, depth), 255}
  end

  defp pixel([r, g, b, a], %{colour: 6, depth: depth}, _palette, _alphas, _source) do
    {scale(r, depth), scale(g, depth), scale(b, depth), scale(a, depth)}
  end

  defp pixel([index], %{colour: 3}, palette, alphas, source) do
    case palette do
      <<_::binary-size(index * 3), r, g, b, _::binary>> ->
        alpha =
          case alphas do
            <<_::binary-size(index), a, _::binary>> -> a
            _ -> 255
          end

        {r, g, b, alpha}

      _ ->
        raise ArgumentError,
              "#{source} names palette entry #{index}, which its PLTE does not hold"
    end
  end

  defp scale(value, 8), do: value
  defp scale(value, 1), do: value * 255
  defp scale(value, 2), do: value * 85
  defp scale(value, 4), do: value * 17
end
