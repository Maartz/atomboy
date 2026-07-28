defmodule Atomboy.PPU do
  @moduledoc """
  Le rendu d'image de la DMG, en BEAM : fond, fenêtre, sprites.

  C'est la phase « le jeu s'affiche » du brief, côté Mac : le PPU lit la VRAM
  et l'OAM que le CPU a écrites et en tire des pixels, scanline par scanline.
  La version C/NIF de la phase 3 fera pareil dans un framebuffer DMA ;
  celle-ci rend depuis la map des écritures de `Atomboy.CPU.CartLoop`, et lui
  servira d'oracle.

  ## Les trois couches

    * **Fond** — la grille 32×32, défilée par SCX/SCY, palette BGP.
    * **Fenêtre** — la seconde grille, ancrée à (WX-7, WY), par-dessus le
      fond. Son compteur de ligne est approximé par `ly - WY` : exact tant
      que la fenêtre n'est pas basculée en cours de frame.
    * **Sprites** — 40 entrées d'OAM, 10 au plus par scanline (l'ordre OAM
      décide, comme le matériel), 8×8 ou 8×16, miroirs, palettes OBP0/OBP1,
      couleur 0 transparente. La priorité entre sprites : le X le plus petit
      gagne, l'entrée OAM la plus basse départage. Le drapeau « derrière le
      fond » cède aux couleurs 1-3 du fond — d'où le rendu du fond en couleur
      *brute*, la palette n'étant appliquée qu'au moment de trancher.

  ## Registres consultés

      0xFF40  LCDC     0xFF42/43  SCY/SCX    0xFF47  BGP
      0xFF48  OBP0     0xFF49     OBP1       0xFF4A/4B  WY/WX
      OAM     0xFE00-0xFE9F

  Une teinte rendue est un octet 0..3 — 0 le plus clair, comme la dalle.
  """

  import Bitwise

  @typedoc "Une scanline rendue : 160 teintes 0..3."
  @type line :: binary()

  @typedoc "Une frame rendue : 144 scanlines concaténées, 23 040 teintes."
  @type frame :: binary()

  @width 160
  @height 144
  @oam 0xFE00

  @doc "Largeur et hauteur de l'écran DMG."
  @spec dimensions() :: {160, 144}
  def dimensions, do: {@width, @height}

  @doc """
  Rend la scanline `ly` depuis l'état mémoire du CPU.

  L'écran éteint rend la teinte 0 partout.
  """
  @spec render_line(map(), 0..143) :: line()
  def render_line(ram, ly) do
    lcdc = Map.get(ram, 0xFF40, 0x91)

    if band(lcdc, 0x80) == 0 do
      :binary.copy(<<0>>, @width)
    else
      raw = background_raw(ram, lcdc, ly)
      sprites = if band(lcdc, 0x02) != 0, do: sprite_pixels(ram, lcdc, ly), else: %{}
      bgp = Map.get(ram, 0xFF47, 0xE4)

      for x <- 0..(@width - 1), into: <<>> do
        bg_color = :binary.at(raw, x)

        case sprites do
          %{^x => {shade, behind?}} when not behind? or bg_color == 0 -> <<shade>>
          _ -> <<band(bsr(bgp, bg_color * 2), 3)>>
        end
      end
    end
  end

  @doc "Rend les 144 scanlines d'une frame."
  @spec render_frame(map()) :: frame()
  def render_frame(ram) do
    for ly <- 0..(@height - 1), into: <<>>, do: render_line(ram, ly)
  end

  # ── Fond et fenêtre — couleurs brutes, avant palette ────────────────────────

  defp background_raw(ram, lcdc, ly) do
    if band(lcdc, 0x01) == 0 do
      :binary.copy(<<0>>, @width)
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

      win_y = ly - wy
      win_row = win_map + bsr(win_y, 3) * 32
      win_tile_line = band(win_y, 7) * 2

      for x <- 0..(@width - 1), into: <<>> do
        if window? and x >= wx do
          <<tile_color(ram, win_row + bsr(x - wx, 3), win_tile_line, band(x - wx, 7), signed?)>>
        else
          xx = band(x + scx, 0xFF)
          <<tile_color(ram, bg_row + bsr(xx, 3), bg_tile_line, band(xx, 7), signed?)>>
        end
      end
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

  # La map x → {teinte, derrière?} des pixels de sprites de la scanline.
  defp sprite_pixels(ram, lcdc, ly) do
    height = if band(lcdc, 0x04) == 0, do: 8, else: 16

    selected =
      for index <- 0..39,
          base = @oam + index * 4,
          y = Map.get(ram, base, 0) - 16,
          ly >= y and ly < y + height,
          do: {index, y, base}

    # Le matériel retient les dix premières entrées d'OAM de la ligne.
    # Priorité d'affichage : X le plus petit gagne, OAM le plus bas départage —
    # donc rendu du moins prioritaire au plus prioritaire, qui écrase.
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
    # En 8×16, le bit 0 de l'indice est ignoré : deux tuiles empilées.
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

        # La couleur 0 d'un sprite est transparente, quelle que soit la palette.
        if color == 0 do
          acc
        else
          Map.put(acc, px, {band(bsr(palette, color * 2), 3), behind?})
        end
      end
    end)
  end
end
