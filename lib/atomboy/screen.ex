defmodule Atomboy.Screen do
  @moduledoc """
  La boucle de frame : le CPU avance scanline par scanline, LY vit, le PPU
  rend.

  C'est la structure que le brief prévoyait : le CPU tourne pour 456 T-cycles
  — une scanline — puis le matériel simulé avance d'un cran. Ici « le matériel »
  se réduit à LY (0xFF44), que les jeux scrutent pour attendre le vblank ; le
  registre est écrit dans la map entre deux tranches, exactement là où le PPU
  de la phase 3 viendra se brancher.

  Le rendu se fait ligne à ligne pendant la partie visible de la dernière
  frame demandée — les registres de défilement sont donc lus à la scanline,
  comme sur la dalle, pas figés en fin de frame.
  """

  import Bitwise

  alias Atomboy.CPU.CartLoop
  alias Atomboy.CPU.State
  alias Atomboy.PPU

  @line_cycles 456
  @visible 144
  @lines 154

  @doc """
  Exécute `frames` frames depuis l'état de démarrage et rend la dernière.

  Renvoie `{frame, state, ram}`.
  """
  @spec run(Path.t(), pos_integer()) :: {PPU.frame(), State.t(), map()}
  def run(rom_path, frames) do
    rom = load(rom_path)
    state = boot_state()
    ram = boot_ram(rom)

    Enum.reduce(1..frames, {<<>>, state, ram}, fn frame_index, {_frame, state, ram} ->
      render? = frame_index == frames
      frame(state, rom, ram, render?)
    end)
  end

  @doc """
  L'état des registres à la sortie de la ROM de boot DMG — le point de départ
  de tout jeu.
  """
  @spec boot_state() :: State.t()
  def boot_state do
    %State{
      a: 0x01,
      f: 0xB0,
      b: 0x00,
      c: 0x13,
      d: 0x00,
      e: 0xD8,
      h: 0x01,
      l: 0x4D,
      sp: 0xFFFE,
      pc: 0x0100
    }
  end

  @doc """
  La map mémoire de départ : nombre de banques et famille de MBC, lus dans
  l'en-tête cartouche (0x147). MBC3 pour les types 0x0F-0x13 — Pokémon et
  sa génération 2 Mo — MBC1 pour le reste.
  """
  @spec boot_ram(binary()) :: map()
  def boot_ram(rom) do
    mbc = if :binary.at(rom, 0x147) in 0x0F..0x13, do: :mbc3, else: :mbc1
    %{rom_banks: div(byte_size(rom), 0x4000), mbc: mbc}
  end

  @doc """
  Une frame de machine : 154 scanlines, rendues si `render?`.
  Renvoie `{pixels, state, ram}` — pixels vide sans rendu.
  """
  @spec frame(State.t(), binary(), map(), boolean()) :: {PPU.frame(), State.t(), map()}
  def frame(state, rom, ram, render?) do
    {pixels, state, ram, _window_line} =
      Enum.reduce(0..(@lines - 1), {<<>>, state, ram, 0}, fn ly,
                                                             {pixels, state, ram, window_line} ->
        {state, ram} = step_line(state, rom, ram, ly)

        if render? and ly < @visible do
          {line, window_line} = PPU.render_line(ram, ly, window_line)
          {pixels <> line, state, ram, window_line}
        else
          {pixels, state, ram, window_line}
        end
      end)

    {pixels, state, ram}
  end

  @doc """
  Une scanline de machine : LY avance, le vblank se lève à la ligne 144, le
  CPU tourne 456 T-cycles, le timer les rattrape. La brique commune de toute
  boucle de frame — Screen, le runner blargg, et la phase 3 un jour.
  """
  @spec step_line(State.t(), binary(), map(), 0..153) :: {State.t(), map()}
  def step_line(state, rom, ram, ly) do
    ram = Map.put(ram, 0xFF44, ly)

    # L'entrée en vblank lève le bit 0 d'IF — l'interruption que les jeux
    # attendent pour toucher la VRAM. Le service lui-même vit dans le fetch
    # de la boucle.
    ram =
      if ly == @visible do
        Map.update(ram, 0xFF0F, 0x01, &bor(&1, 0x01))
      else
        ram
      end

    # La coïncidence LY=LYC : le bit 2 de STAT la reflète, et si le jeu a armé
    # le bit 6, l'interruption STAT part — c'est l'outil des effets raster, et
    # dmg-acid2 s'endormait dessus.
    stat = Map.get(ram, 0xFF41, 0)

    ram =
      if ly == Map.get(ram, 0xFF45, 0) do
        ram = Map.put(ram, 0xFF41, bor(stat, 0x04))

        if band(stat, 0x40) != 0 do
          Map.update(ram, 0xFF0F, 0x02, &bor(&1, 0x02))
        else
          ram
        end
      else
        Map.put(ram, 0xFF41, band(stat, 0xFB))
      end

    {state, ram, cycles} = CartLoop.run(state, rom, ram, @line_cycles)
    {state, Atomboy.Timer.advance(ram, cycles)}
  end

  @doc """
  Charge une ROM : les petites sont complétées à 32 Ko ; les grandes gardent
  leurs banques telles quelles, le MBC1 de CartLoop fait le reste.
  """
  @spec load(Path.t()) :: binary()
  def load(path) do
    rom = File.read!(path)

    if byte_size(rom) < 0x8000 do
      rom <> :binary.copy(<<0xFF>>, 0x8000 - byte_size(rom))
    else
      rom
    end
  end

  @doc """
  La frame en texte pour le terminal : deux scanlines par rangée de
  caractères, le demi-bloc `▀` portant la ligne du haut en avant-plan et
  celle du bas en arrière-plan, quatre gris ANSI pour les quatre teintes.

  La séquence de couleur n'est émise qu'au changement de paire — les aplats,
  majoritaires sur une frame de jeu, coûtent un octet par cellule. C'est ce
  qui laisse un terminal suivre 60 frames par seconde.
  """
  @spec to_text(PPU.frame(), :gris | :dmg) :: String.t()
  def to_text(frame, palette \\ :gris) do
    {width, height} = PPU.dimensions()
    colors = colors(palette)

    rows =
      for row <- 0..(div(height, 2) - 1) do
        top = :binary.part(frame, row * 2 * width, width)
        bottom = :binary.part(frame, (row * 2 + 1) * width, width)

        {cells, _} =
          Enum.map_reduce(0..(width - 1), nil, fn x, prev ->
            fg = elem(colors, :binary.at(top, x))
            bg = elem(colors, :binary.at(bottom, x))
            pair = {fg, bg}

            if pair == prev do
              {"▀", prev}
            else
              {"\e[38;#{fg};48;#{bg}m▀", pair}
            end
          end)

        [cells, "\e[0m\n"]
      end

    IO.iodata_to_binary(rows)
  end

  # Les teintes précompilées en paramètres SGR : 256 couleurs pour les gris,
  # truecolor pour le vert de la dalle DMG d'origine.
  defp colors(:gris), do: {"5;255", "5;250", "5;243", "5;236"}

  defp colors(:dmg) do
    {"2;155;188;15", "2;139;172;15", "2;48;98;48", "2;15;56;15"}
  end

  @doc """
  La frame en PGM binaire (P5) — lisible par tout visionneur d'images.
  """
  @spec to_pgm(PPU.frame()) :: binary()
  def to_pgm(frame) do
    {width, height} = PPU.dimensions()
    shades = {0xFF, 0xAA, 0x55, 0x00}
    pixels = for <<shade <- frame>>, into: <<>>, do: <<elem(shades, shade)>>
    "P5\n#{width} #{height}\n255\n" <> pixels
  end
end
