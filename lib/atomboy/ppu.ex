defmodule Atomboy.PPU do
  @moduledoc """
  Le rendu d'image de la DMG — version fond seul, en BEAM.

  C'est la phase « le jeu s'affiche, même à 5 fps » du brief, côté Mac : le
  PPU lit la VRAM que le CPU a écrite et en tire des pixels. La version C/NIF
  de la phase 3 fera la même chose scanline par scanline dans un framebuffer
  DMA ; celle-ci rend depuis la map des écritures de `Atomboy.CPU.CartLoop`,
  ce qui suffit pour voir — et pour servir d'oracle au rendu C plus tard.

  ## Ce qui est rendu

  Le **fond** (background) uniquement : la grille 32×32 de tuiles 8×8,
  défilée par SCX/SCY, à travers la palette BGP. Ni fenêtre ni sprites pour
  l'instant — les ROMs de test blargg écrivent leur rapport en tuiles de
  fond, c'est exactement ce qu'il faut pour un premier écran auto-vérifiant :
  si le rendu est juste, on peut *lire* « Passed ».

  ## Registres consultés

      0xFF40  LCDC — bit 7 écran, bit 4 base des tuiles, bit 3 base de la
              carte, bit 0 fond activé
      0xFF42  SCY / 0xFF43 SCX — défilement
      0xFF47  BGP — la palette : deux bits par teinte

  Une teinte rendue est un octet 0..3 — 0 le plus clair, comme la dalle.
  """

  import Bitwise

  @typedoc "Une scanline rendue : 160 teintes 0..3."
  @type line :: binary()

  @typedoc "Une frame rendue : 144 scanlines concaténées, 23 040 teintes."
  @type frame :: binary()

  @width 160
  @height 144

  @doc "Largeur et hauteur de l'écran DMG."
  @spec dimensions() :: {160, 144}
  def dimensions, do: {@width, @height}

  @doc """
  Rend la scanline `ly` depuis l'état mémoire du CPU.

  L'écran ou le fond désactivés rendent la teinte 0 partout.
  """
  @spec render_line(map(), 0..143) :: line()
  def render_line(ram, ly) do
    lcdc = Map.get(ram, 0xFF40, 0x91)

    if band(lcdc, 0x81) != 0x81 do
      :binary.copy(<<0>>, @width)
    else
      scy = Map.get(ram, 0xFF42, 0)
      scx = Map.get(ram, 0xFF43, 0)
      bgp = Map.get(ram, 0xFF47, 0xE4)
      map_base = if band(lcdc, 0x08) == 0, do: 0x9800, else: 0x9C00
      # Bit 4 bas : les indices de tuile sont signés autour de 0x9000.
      signed? = band(lcdc, 0x10) == 0

      y = band(ly + scy, 0xFF)
      map_row = map_base + bsr(y, 3) * 32
      tile_line = band(y, 7) * 2

      for x <- 0..(@width - 1), into: <<>> do
        xx = band(x + scx, 0xFF)
        tile = Map.get(ram, map_row + bsr(xx, 3), 0)

        tile_addr =
          if signed? do
            0x9000 + (tile - bsl(bsr(tile, 7), 8)) * 16
          else
            0x8000 + tile * 16
          end

        low = Map.get(ram, tile_addr + tile_line, 0)
        high = Map.get(ram, tile_addr + tile_line + 1, 0)
        bit = 7 - band(xx, 7)
        color = bsl(band(bsr(high, bit), 1), 1) ||| band(bsr(low, bit), 1)
        <<band(bsr(bgp, color * 2), 3)>>
      end
    end
  end

  @doc "Rend les 144 scanlines d'une frame."
  @spec render_frame(map()) :: frame()
  def render_frame(ram) do
    for ly <- 0..(@height - 1), into: <<>>, do: render_line(ram, ly)
  end
end
