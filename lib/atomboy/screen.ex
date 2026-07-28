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
      ram = Map.put(ram, 0xFF44, ly)
      {state, ram, _cycles} = CartLoop.run(state, rom, ram, @line_cycles)

      pixels =
        if render? and ly < @visible, do: pixels <> PPU.render_line(ram, ly), else: pixels

      {pixels, state, ram}
    end)
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
