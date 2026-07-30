defmodule Mix.Tasks.Atomboy.Screen do
  @shortdoc "Runs a ROM and prints its screen in the terminal"

  @moduledoc """
  The first look at the emulator.

      mix atomboy.screen <rom.gb> [frames]

  Runs the ROM for `frames` frames (180 by default — three seconds of DMG),
  renders the last one, prints it in the terminal as half-blocks, and writes it
  as PGM into `_build/screen.pgm` for an image viewer.

  blargg's test ROMs make an excellent first target: they write their report on
  screen as background tiles — if the rendering is right, the verdict reads in
  pixels.
  """

  use Mix.Task

  @impl true
  def run(argv) do
    Mix.Task.run("compile")

    {debug?, argv} = {"--debug" in argv, Enum.reject(argv, &(&1 == "--debug"))}

    {rom, frames} =
      case argv do
        [rom] -> {rom, 180}
        [rom, frames] -> {rom, String.to_integer(frames)}
        _ -> Mix.raise("usage: mix atomboy.screen <rom.gb> [frames] [--debug]")
      end

    unless File.regular?(rom), do: Mix.raise("ROM not found: #{rom}")

    {frame, state, ram} = Atomboy.Screen.run(rom, frames)

    IO.puts(Atomboy.Screen.to_text(frame))

    pgm = Path.join(Mix.Project.build_path(), "screen.pgm")
    File.write!(pgm, Atomboy.Screen.to_pgm(frame))
    Mix.shell().info("Frame #{frames} written to #{pgm}")

    if debug?, do: debug(state, ram)
  end

  # The autopsy of a blank screen: where the CPU is, whether the screen is on,
  # whether the palette is black, whether the tiles ever arrived.
  defp debug(state, ram) do
    hex = fn value -> "0x" <> Integer.to_string(value, 16) end

    vram_writes = Enum.count(ram, fn {k, _} -> is_integer(k) and k >= 0x8000 and k < 0xA000 end)
    oam_writes = Enum.count(ram, fn {k, _} -> is_integer(k) and k >= 0xFE00 and k < 0xFEA0 end)

    Mix.shell().info("""

    ── debug ─────────────────────────────────────────────
    pc=#{hex.(state.pc)}  sp=#{hex.(state.sp)}  ime=#{state.ime}  halted=#{state.halted}
    LCDC=#{hex.(Map.get(ram, 0xFF40, 0x91))}  STAT=#{hex.(Map.get(ram, 0xFF41, 0))}  BGP=#{hex.(Map.get(ram, 0xFF47, 0xE4))}
    SCX=#{Map.get(ram, 0xFF43, 0)}  SCY=#{Map.get(ram, 0xFF42, 0)}  WX=#{Map.get(ram, 0xFF4B, 0)}  WY=#{Map.get(ram, 0xFF4A, 0)}
    IE=#{hex.(Map.get(ram, 0xFFFF, 0))}  IF=#{hex.(Map.get(ram, 0xFF0F, 0))}
    VRAM writes=#{vram_writes}  OAM=#{oam_writes}  ROM bank base=#{hex.(Map.get(ram, :rom_bank_base, 0x4000))}
    """)
  end
end
