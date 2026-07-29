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

  ## Sauvegardes

  La RAM à pile de la cartouche vit dans un `.sav` à côté de la ROM — la
  convention des émulateurs, fichiers échangeables dans les deux sens.
  Rechargée au lancement, écrite à la sortie et toutes les ~10 s dès que
  le jeu a écrit quelque chose.

  ## Options

    * `--fenetre` — jouer dans une vraie fenêtre (wxWidgets) plutôt que dans
      le terminal : vrais événements clavier, pixels nets à l'échelle, aucun
      des prérequis du terminal (ni `bin/play`, ni taille minimale).
    * `--hold N` — frames de maintien par frappe (défaut 10), pour les
      terminaux sans protocole clavier kitty ; avec lui (Ghostty…), l'état
      des touches est réel et ce réglage ne sert plus.
    * `--frames N` — s'arrêter après N frames (essais sans clavier).
    * `--son` / `--no-son` — forcer ou couper le son (défaut : actif en
      interactif si ffplay est installé — `brew install ffmpeg`).
    * `--palette dmg|gris` — le vert de la dalle d'origine (défaut) ou les
      gris neutres.
    * `--dump f.pgm` — écrire la dernière frame en image à la sortie.
    * `--ecoute [port]` / `--lien hôte:port` — le câble link en TCP : un
      côté écoute (7373 par défaut), l'autre appelle, et les deux consoles
      échangent leurs octets série comme par le vrai câble — échanges
      Pokémon compris. ⇄ au statut.

  ## En jeu

    * `s` fige la machine entière dans un `.state` à côté de la ROM,
      `r` la ranime — sauver avant un boss, réessayer à l'infini.
    * `Tab` bascule l'avance rapide (rendu 1/4, son coupé) — les intros
      passent en secondes.
    * `Retour arrière`, tenu, rembobine — jusqu'à quarante secondes en
      arrière, dix frames par pas. Mort sur un boss ? Remonte le temps.
    * `p` met en pause.

  L'affichage demande 160 colonnes sur 73 lignes — réduire la police
  (Cmd -) suffit généralement.
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    case Atomboy.CLI.parse(args) do
      {:ok, rom, opts} ->
        {fenetre, opts} = Keyword.pop(opts, :fenetre, false)
        runner = if fenetre, do: Atomboy.Window, else: Atomboy.Play

        case runner.run(rom, opts) do
          :ok -> :ok
          {:error, message} -> Mix.raise(message)
        end

      {:error, message} ->
        Mix.raise(message)
    end
  end
end
