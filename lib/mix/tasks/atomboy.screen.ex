defmodule Mix.Tasks.Atomboy.Screen do
  @shortdoc "Exécute une ROM et affiche son écran dans le terminal"

  @moduledoc """
  Le premier regard sur l'émulateur.

      mix atomboy.screen <rom.gb> [frames]

  Exécute la ROM pendant `frames` frames (180 par défaut — trois secondes de
  DMG), rend la dernière, l'affiche dans le terminal en demi-blocs, et
  l'écrit en PGM dans `_build/screen.pgm` pour un visionneur d'images.

  Les ROMs de test blargg font une excellente première cible : elles écrivent
  leur rapport à l'écran en tuiles de fond — si le rendu est juste, le
  verdict se lit en pixels.
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
        _ -> Mix.raise("usage : mix atomboy.screen <rom.gb> [frames] [--debug]")
      end

    unless File.regular?(rom), do: Mix.raise("ROM introuvable : #{rom}")

    {frame, state, ram} = Atomboy.Screen.run(rom, frames)

    IO.puts(Atomboy.Screen.to_text(frame))

    pgm = Path.join(Mix.Project.build_path(), "screen.pgm")
    File.write!(pgm, Atomboy.Screen.to_pgm(frame))
    Mix.shell().info("Frame #{frames} écrite dans #{pgm}")

    if debug?, do: debug(state, ram)
  end

  # L'autopsie d'un écran vide : où est le CPU, l'écran est-il allumé, la
  # palette est-elle noire, les tuiles sont-elles arrivées.
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
    écritures VRAM=#{vram_writes}  OAM=#{oam_writes}  banque ROM base=#{hex.(Map.get(ram, :rom_bank_base, 0x4000))}
    """)
  end
end
