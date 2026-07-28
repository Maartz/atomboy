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

    state = %State{
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

    Enum.reduce(1..frames, {<<>>, state, %{}}, fn frame_index, {_frame, state, ram} ->
      render? = frame_index == frames
      frame(state, rom, ram, render?)
    end)
  end

  defp frame(state, rom, ram, render?) do
    Enum.reduce(0..(@lines - 1), {<<>>, state, ram}, fn ly, {pixels, state, ram} ->
      {state, ram} = step_line(state, rom, ram, ly)

      pixels =
        if render? and ly < @visible, do: pixels <> PPU.render_line(ram, ly), else: pixels

      {pixels, state, ram}
    end)
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

    {state, ram, cycles} = CartLoop.run(state, rom, ram, @line_cycles)
    {state, Atomboy.Timer.advance(ram, cycles)}
  end

  defp load(path) do
    rom = File.read!(path)

    if byte_size(rom) > 0x8000 do
      raise "ROM de #{byte_size(rom)} octets : le banking MBC n'existe pas encore, 32 Ko max"
    end

    rom <> :binary.copy(<<0xFF>>, 0x10000 - byte_size(rom))
  end

  @doc """
  La frame en texte pour le terminal : deux scanlines par rangée de
  caractères, le demi-bloc `▀` portant la ligne du haut en avant-plan et
  celle du bas en arrière-plan, quatre gris ANSI pour les quatre teintes.
  """
  @spec to_text(PPU.frame()) :: String.t()
  def to_text(frame) do
    {width, height} = PPU.dimensions()
    grays = {255, 250, 243, 236}

    rows =
      for row <- 0..(div(height, 2) - 1) do
        top = :binary.part(frame, row * 2 * width, width)
        bottom = :binary.part(frame, (row * 2 + 1) * width, width)

        cells =
          for x <- 0..(width - 1) do
            fg = elem(grays, :binary.at(top, x))
            bg = elem(grays, :binary.at(bottom, x))
            "\e[38;5;#{fg};48;5;#{bg}m▀"
          end

        [cells, "\e[0m\n"]
      end

    IO.iodata_to_binary(rows)
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
