defmodule Atomboy.MixProject do
  use Mix.Project

  @version "0.2.0"

  def project do
    [
      app: :atomboy,
      version: version(),
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      # wx (la fenêtre native) vit dans OTP, pas dans nos deps : sans ceci,
      # mix élague son chemin de code et :wx devient introuvable.
      prune_code_paths: false,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      releases: releases()
    ]
  end

  # La version porte le SHA du commit (et l'heure si l'arbre est sale) :
  # le binaire Burrito extrait son contenu dans un cache nommé par version —
  # sans cela, un rebuild de même numéro fait tourner l'ancien code. Chaque
  # build a désormais sa clé ; le cache s'accumule dans
  # ~/Library/Application Support/.burrito, à purger de temps en temps.
  defp version do
    case System.cmd("git", ["rev-parse", "--short", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} ->
        dirty =
          case System.cmd("git", ["status", "--porcelain"], stderr_to_stdout: true) do
            {"", 0} -> ""
            _ -> ".#{System.os_time(:second)}"
          end

        "#{@version}+#{String.trim(sha)}#{dirty}"

      _ ->
        @version
    end
  end

  def application do
    # Pas de `extra_applications` : tout ce qui est listé ici finit dans le
    # packbeam flashé sur l'ESP32, et AtomVM n'a ni :logger ni la majorité
    # d'OTP. Autant que la contrainte morde dès la phase 1 sur le Mac plutôt
    # qu'à la phase 2 quand le code aura pris l'habitude.
    #
    # En prod (l'exécutable Burrito), l'app démarre Atomboy.CLI — le point
    # d'entrée du binaire distribué. Jamais en dev/test : `mix test` ne doit
    # pas lancer une partie.
    if Mix.env() == :prod, do: [mod: {Atomboy.CLI, []}], else: []
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    # Une seule dépendance, et cantonnée à l'empaquetage : Burrito enveloppe
    # la release (app + BEAM entier) dans un exécutable unique par plateforme.
    # Le cœur de l'émulateur reste sans dépendance — chaque ajout serait du
    # code à faire tenir dans AtomVM, qui n'implémente qu'un sous-ensemble
    # d'OTP. Le JSON du corpus est décodé par le module `JSON` d'Elixir 1.18.
    [
      {:burrito, "~> 1.0", runtime: false}
    ]
  end

  defp releases do
    [
      atomboy: [
        applications: [wx: :load],
        steps: [:assemble, &Burrito.wrap/1],
        burrito: [
          targets: [
            macos_arm: [os: :darwin, cpu: :aarch64],
            linux_x64: [os: :linux, cpu: :x86_64]
          ]
        ]
      ]
    ]
  end
end
