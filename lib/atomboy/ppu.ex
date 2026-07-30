defmodule Atomboy.PPU do
  @moduledoc """
  The DMG's picture rendering, in BEAM: background, window, sprites.

  This is the brief's "the game shows up on screen" phase, on the Mac side:
  the PPU reads the VRAM and the OAM the CPU wrote and draws pixels out of
  them, scanline by scanline. The C/NIF version of phase 3 will do the same
  into a DMA framebuffer; this one renders from `Atomboy.CPU.CartLoop`'s map
  of writes, and will serve as that version's oracle.

  ## The three layers

    * **Background** — the 32×32 grid, scrolled by SCX/SCY, BGP palette.
    * **Window** — the second grid, anchored at (WX-7, WY), on top of the
      background. Its internal line counter only advances on the scanlines
      where it actually showed up — the quirk dmg-acid2 checks by toggling it
      mid-frame, and that the `ly - WY` approximation gets wrong.
    * **Sprites** — 40 OAM entries, 10 at most per scanline (OAM order
      decides, as on hardware), 8×8 or 8×16, mirroring, OBP0/OBP1 palettes,
      colour 0 transparent. Priority between sprites: the smallest X wins,
      the lowest OAM entry breaks the tie. The "behind the background" flag
      yields to background colours 1-3 — hence rendering the background in
      *raw* colour, the palette being applied only at the moment of choosing.

  ## Registers consulted

      0xFF40  LCDC     0xFF42/43  SCY/SCX    0xFF47  BGP
      0xFF48  OBP0     0xFF49     OBP1       0xFF4A/4B  WY/WX
      OAM     0xFE00-0xFE9F

  A rendered shade is a byte 0..3 — 0 the lightest, as on the panel.
  """

  import Bitwise

  @typedoc "One rendered scanline: 160 shades 0..3."
  @type line :: binary()

  @typedoc "One rendered frame: 144 scanlines concatenated, 23,040 shades."
  @type frame :: binary()

  @width 160
  @height 144
  @oam 0xFE00

  @doc "Width and height of the DMG screen."
  @spec dimensions() :: {160, 144}
  def dimensions, do: {@width, @height}

  @doc """
  Renders scanline `ly` from the CPU's memory state, along with the window's
  internal line counter. Returns `{scanline, counter}` — the counter only
  advances if the window showed up on that line.

  In DMG mode, one byte per pixel: the shade 0..3. In colour mode (`:cgb`,
  set by `Screen.boot_ram/1`), two bytes per pixel: the little-endian RGB555
  drawn from the game's palettes.

  A screen that is off renders shade 0 — or white — everywhere.
  """
  @spec render_line(map(), 0..143, non_neg_integer()) :: {line(), non_neg_integer()}
  def render_line(ram, ly, window_line) do
    if Map.get(ram, :cgb, false) do
      render_line_cgb(ram, ly, window_line)
    else
      render_line_dmg(ram, ly, window_line)
    end
  end

  defp render_line_dmg(ram, ly, window_line) do
    lcdc = Map.get(ram, 0xFF40, 0x91)

    if band(lcdc, 0x80) == 0 do
      {:binary.copy(<<0>>, @width), window_line}
    else
      {raw, window_line} = background_raw(ram, lcdc, ly, window_line)
      sprites = if band(lcdc, 0x02) != 0, do: sprite_pixels(ram, lcdc, ly), else: %{}
      bgp = Map.get(ram, 0xFF47, 0xE4)

      line =
        for x <- 0..(@width - 1), into: <<>> do
          bg_color = :binary.at(raw, x)

          case sprites do
            %{^x => {shade, behind?}} when not behind? or bg_color == 0 -> <<shade>>
            _ -> <<band(bsr(bgp, bg_color * 2), 3)>>
          end
        end

      {line, window_line}
    end
  end

  # ── Colour mode ─────────────────────────────────────────────────────────────
  #
  # Each tile's attributes live in VRAM bank 1 (keys +0x10000): palette 0-7,
  # mirroring, pattern bank, priority. The colours come out of the palette
  # RAM (0x20000 background, 0x20040 sprites): 8 palettes × 4 colours ×
  # RGB555. Priority is the GBC's: LCDC bit 0 at zero = sprites always win;
  # otherwise the tile attribute or the sprite's "behind" flag yields to
  # background colours 1-3. Sprites break ties on the OAM index alone — not
  # on X, unlike the DMG.

  defp render_line_cgb(ram, ly, window_line) do
    lcdc = Map.get(ram, 0xFF40, 0x91)

    if band(lcdc, 0x80) == 0 do
      {:binary.copy(<<0xFF, 0x7F>>, @width), window_line}
    else
      {bg, window_line} = background_cgb(ram, lcdc, ly, window_line)
      sprites = if band(lcdc, 0x02) != 0, do: sprite_pixels_cgb(ram, lcdc, ly), else: %{}
      master = band(lcdc, 0x01) != 0

      line =
        for x <- 0..(@width - 1), into: <<>> do
          {bg_color, bg_prio, bg_rgb} = elem(bg, x)

          case sprites do
            %{^x => {rgb, behind?}} ->
              sprite_hidden = master and bg_color != 0 and (bg_prio or behind?)
              if sprite_hidden, do: <<bg_rgb::16-little>>, else: <<rgb::16-little>>

            _ ->
              <<bg_rgb::16-little>>
          end
        end

      {line, window_line}
    end
  end

  defp background_cgb(ram, lcdc, ly, window_line) do
    scy = Map.get(ram, 0xFF42, 0)
    scx = Map.get(ram, 0xFF43, 0)
    wy = Map.get(ram, 0xFF4A, 0)
    wx = Map.get(ram, 0xFF4B, 0) - 7
    window? = band(lcdc, 0x20) != 0 and ly >= wy and wx < @width

    bg_map = if band(lcdc, 0x08) == 0, do: 0x9800, else: 0x9C00
    win_map = if band(lcdc, 0x40) == 0, do: 0x9800, else: 0x9C00
    signed? = band(lcdc, 0x10) == 0

    y = band(ly + scy, 0xFF)
    bg_row = bg_map + bsr(y, 3) * 32
    bg_line = band(y, 7)

    win_row = win_map + bsr(window_line, 3) * 32
    win_line = band(window_line, 7)

    pixels =
      for x <- 0..(@width - 1) do
        if window? and x >= wx do
          cgb_tile_pixel(ram, win_row + bsr(x - wx, 3), win_line, band(x - wx, 7), signed?)
        else
          xx = band(x + scx, 0xFF)
          cgb_tile_pixel(ram, bg_row + bsr(xx, 3), bg_line, band(xx, 7), signed?)
        end
      end

    {List.to_tuple(pixels), if(window?, do: window_line + 1, else: window_line)}
  end

  # One background pixel: {raw colour 0-3, tile priority, RGB555}.
  defp cgb_tile_pixel(ram, map_addr, tile_line, pixel, signed?) do
    tile = Map.get(ram, map_addr, 0)
    attr = Map.get(ram, map_addr + 0x10000, 0)

    tile_line = if band(attr, 0x40) != 0, do: 7 - tile_line, else: tile_line
    bank = band(bsr(attr, 3), 1) * 0x10000

    tile_addr =
      if signed? do
        0x9000 + (tile - bsl(bsr(tile, 7), 8)) * 16
      else
        0x8000 + tile * 16
      end

    low = Map.get(ram, tile_addr + bank + tile_line * 2, 0)
    high = Map.get(ram, tile_addr + bank + tile_line * 2 + 1, 0)
    bit = if band(attr, 0x20) != 0, do: pixel, else: 7 - pixel
    color = bsl(band(bsr(high, bit), 1), 1) ||| band(bsr(low, bit), 1)

    {color, band(attr, 0x80) != 0, cgb_color(ram, 0x20000, band(attr, 0x07), color)}
  end

  # The RGB555 colour of palette n: two little-endian bytes in the palette
  # RAM.
  defp cgb_color(ram, base, palette, color) do
    at = base + palette * 8 + color * 2
    Map.get(ram, at, 0xFF) ||| bsl(Map.get(ram, at + 1, 0x7F), 8)
  end

  defp sprite_pixels_cgb(ram, lcdc, ly) do
    height = if band(lcdc, 0x04) == 0, do: 8, else: 16

    selected =
      for index <- 0..39,
          base = @oam + index * 4,
          y = Map.get(ram, base, 0) - 16,
          ly >= y and ly < y + height,
          do: {index, y, base}

    # Ten per line, priority to the smallest OAM index — rendered from the
    # lowest priority to the highest, which overwrites.
    selected
    |> Enum.take(10)
    |> Enum.sort_by(fn {index, _y, _base} -> -index end)
    |> Enum.reduce(%{}, fn {_index, y, base}, acc ->
      draw_sprite_cgb(ram, acc, ly, y, base, height)
    end)
  end

  defp draw_sprite_cgb(ram, acc, ly, y, base, height) do
    x = Map.get(ram, base + 1, 0) - 8
    tile = Map.get(ram, base + 2, 0)
    flags = Map.get(ram, base + 3, 0)

    row = ly - y
    row = if band(flags, 0x40) != 0, do: height - 1 - row, else: row
    tile = if height == 16, do: band(tile, 0xFE), else: tile

    bank = band(bsr(flags, 3), 1) * 0x10000
    tile_addr = 0x8000 + bank + tile * 16 + row * 2
    low = Map.get(ram, tile_addr, 0)
    high = Map.get(ram, tile_addr + 1, 0)

    palette = band(flags, 0x07)
    behind? = band(flags, 0x80) != 0
    x_flip? = band(flags, 0x20) != 0

    Enum.reduce(0..7, acc, fn i, acc ->
      px = x + i

      if px < 0 or px >= @width do
        acc
      else
        bit = if x_flip?, do: i, else: 7 - i
        color = bsl(band(bsr(high, bit), 1), 1) ||| band(bsr(low, bit), 1)

        if color == 0 do
          acc
        else
          Map.put(acc, px, {cgb_color(ram, 0x20040, palette, color), behind?})
        end
      end
    end)
  end

  @doc "Renders the 144 scanlines of a frame."
  @spec render_frame(map()) :: frame()
  def render_frame(ram) do
    {frame, _window_line} =
      Enum.reduce(0..(@height - 1), {<<>>, 0}, fn ly, {frame, window_line} ->
        {line, window_line} = render_line(ram, ly, window_line)
        {frame <> line, window_line}
      end)

    frame
  end

  # ── Background and window — raw colours, before the palette ─────────────────

  defp background_raw(ram, lcdc, ly, window_line) do
    if band(lcdc, 0x01) == 0 do
      {:binary.copy(<<0>>, @width), window_line}
    else
      scy = Map.get(ram, 0xFF42, 0)
      scx = Map.get(ram, 0xFF43, 0)
      wy = Map.get(ram, 0xFF4A, 0)
      wx = Map.get(ram, 0xFF4B, 0) - 7
      window? = band(lcdc, 0x20) != 0 and ly >= wy and wx < @width

      bg_map = if band(lcdc, 0x08) == 0, do: 0x9800, else: 0x9C00
      win_map = if band(lcdc, 0x40) == 0, do: 0x9800, else: 0x9C00
      signed? = band(lcdc, 0x10) == 0

      y = band(ly + scy, 0xFF)
      bg_row = bg_map + bsr(y, 3) * 32
      bg_tile_line = band(y, 7) * 2

      win_row = win_map + bsr(window_line, 3) * 32
      win_tile_line = band(window_line, 7) * 2

      raw =
        for x <- 0..(@width - 1), into: <<>> do
          if window? and x >= wx do
            <<tile_color(ram, win_row + bsr(x - wx, 3), win_tile_line, band(x - wx, 7), signed?)>>
          else
            xx = band(x + scx, 0xFF)
            <<tile_color(ram, bg_row + bsr(xx, 3), bg_tile_line, band(xx, 7), signed?)>>
          end
        end

      {raw, if(window? and wx < @width, do: window_line + 1, else: window_line)}
    end
  end

  defp tile_color(ram, map_addr, tile_line, pixel, signed?) do
    tile = Map.get(ram, map_addr, 0)

    tile_addr =
      if signed? do
        0x9000 + (tile - bsl(bsr(tile, 7), 8)) * 16
      else
        0x8000 + tile * 16
      end

    low = Map.get(ram, tile_addr + tile_line, 0)
    high = Map.get(ram, tile_addr + tile_line + 1, 0)
    bit = 7 - pixel
    bsl(band(bsr(high, bit), 1), 1) ||| band(bsr(low, bit), 1)
  end

  # ── Sprites ─────────────────────────────────────────────────────────────────

  # The x → {shade, behind?} map of the scanline's sprite pixels.
  defp sprite_pixels(ram, lcdc, ly) do
    height = if band(lcdc, 0x04) == 0, do: 8, else: 16

    selected =
      for index <- 0..39,
          base = @oam + index * 4,
          y = Map.get(ram, base, 0) - 16,
          ly >= y and ly < y + height,
          do: {index, y, base}

    # The hardware keeps the line's first ten OAM entries. Display priority:
    # the smallest X wins, the lowest OAM breaks the tie — so rendered from
    # the lowest priority to the highest, which overwrites.
    selected
    |> Enum.take(10)
    |> Enum.sort_by(fn {index, _y, base} -> {-Map.get(ram, base + 1, 0), -index} end)
    |> Enum.reduce(%{}, fn {_index, y, base}, acc ->
      draw_sprite(ram, acc, ly, y, base, height)
    end)
  end

  defp draw_sprite(ram, acc, ly, y, base, height) do
    x = Map.get(ram, base + 1, 0) - 8
    tile = Map.get(ram, base + 2, 0)
    flags = Map.get(ram, base + 3, 0)

    row = ly - y
    row = if band(flags, 0x40) != 0, do: height - 1 - row, else: row
    # In 8×16, bit 0 of the index is ignored: two tiles stacked.
    tile = if height == 16, do: band(tile, 0xFE), else: tile

    tile_addr = 0x8000 + tile * 16 + row * 2
    low = Map.get(ram, tile_addr, 0)
    high = Map.get(ram, tile_addr + 1, 0)

    palette = Map.get(ram, if(band(flags, 0x10) == 0, do: 0xFF48, else: 0xFF49), 0xE4)
    behind? = band(flags, 0x80) != 0
    x_flip? = band(flags, 0x20) != 0

    Enum.reduce(0..7, acc, fn i, acc ->
      px = x + i

      if px < 0 or px >= @width do
        acc
      else
        bit = if x_flip?, do: i, else: 7 - i
        color = bsl(band(bsr(high, bit), 1), 1) ||| band(bsr(low, bit), 1)

        # A sprite's colour 0 is transparent, whatever the palette says.
        if color == 0 do
          acc
        else
          Map.put(acc, px, {band(bsr(palette, color * 2), 3), behind?})
        end
      end
    end)
  end
end
