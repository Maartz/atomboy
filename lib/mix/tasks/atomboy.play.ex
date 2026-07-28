defmodule Mix.Tasks.Atomboy.Play do
  @shortdoc "Joue une ROM Game Boy dans le terminal"

  @moduledoc """
  La console dans le terminal : l'émulateur tourne à la cadence de la dalle,
  le clavier tient lieu de croix et de boutons.

      bin/play "Tetris (World) (Rev 1).gb"
      bin/play zelda.gb --hold 15

  Le lanceur `bin/play` équivaut à `ELIXIR_ERL_OPTIONS="-noinput" mix
  atomboy.play …` : sans `-noinput`, le lecteur interne du BEAM vole un
  octet sur trois au clavier et les flèches n'arrivent jamais entières —
  la tâche refuse alors de démarrer, avec ce mode d'emploi.

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
    {opts, argv} =
      OptionParser.parse!(args, strict: [hold: :integer, frames: :integer, dump: :string])

    rom =
      case argv do
        [rom] -> rom
        _ -> Mix.raise("usage : mix atomboy.play <rom.gb> [--hold N] [--frames N] [--dump f.pgm]")
      end

    File.exists?(rom) || Mix.raise("ROM introuvable : #{rom}")
    Mix.Task.run("app.start")

    case Atomboy.Play.run(rom, opts) do
      :ok -> :ok
      {:error, message} -> Mix.raise(message)
    end
  end
end
