defmodule Mix.Tasks.Atomboy.Play do
  @shortdoc "Joue une ROM Game Boy dans le terminal"

  @moduledoc """
  La console dans le terminal : l'émulateur tourne à la cadence de la dalle,
  le clavier tient lieu de croix et de boutons.

      mix atomboy.play "Tetris (World) (Rev 1).gb"
      mix atomboy.play zelda.gb --hold 15

  ## Touches

      flèches    la croix        x  A        c  B
      Entrée     Start           ␣  Select   q ou Ctrl-C  quitter

  ## Options

    * `--hold N` — frames de maintien par frappe (défaut 10). Un terminal ne
      signalant pas les relâchements, chaque frappe presse la touche N frames,
      la répétition automatique du clavier prolonge un maintien réel.
    * `--frames N` — s'arrêter après N frames (essais sans clavier).

  L'affichage demande 160 colonnes sur 73 lignes — réduire la police
  (Cmd -) suffit généralement.
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, argv} = OptionParser.parse!(args, strict: [hold: :integer, frames: :integer])

    rom =
      case argv do
        [rom] -> rom
        _ -> Mix.raise("usage : mix atomboy.play <rom.gb> [--hold N] [--frames N]")
      end

    File.exists?(rom) || Mix.raise("ROM introuvable : #{rom}")
    Mix.Task.run("app.start")
    check_size!()
    Atomboy.Play.run(rom, opts)
  end

  defp check_size! do
    case Atomboy.Play.terminal_size() do
      {rows, cols} when rows < 73 or cols < 160 ->
        Mix.raise(
          "Le terminal fait #{cols}×#{rows} ; il faut 160×73 pour l'écran DMG.\n" <>
            "Réduire la police (Cmd -) ou agrandir la fenêtre, puis relancer."
        )

      _ ->
        :ok
    end
  end
end
