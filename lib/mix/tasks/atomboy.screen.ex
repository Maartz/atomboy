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

    {rom, frames} =
      case argv do
        [rom] -> {rom, 180}
        [rom, frames] -> {rom, String.to_integer(frames)}
        _ -> Mix.raise("usage : mix atomboy.screen <rom.gb> [frames]")
      end

    unless File.regular?(rom), do: Mix.raise("ROM introuvable : #{rom}")

    {frame, _state, _ram} = Atomboy.Screen.run(rom, frames)

    IO.puts(Atomboy.Screen.to_text(frame))

    pgm = Path.join(Mix.Project.build_path(), "screen.pgm")
    File.write!(pgm, Atomboy.Screen.to_pgm(frame))
    Mix.shell().info("Frame #{frames} écrite dans #{pgm}")
  end
end
