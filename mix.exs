defmodule Atomboy.MixProject do
  use Mix.Project

  def project do
    [
      app: :atomboy,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps()
    ]
  end

  def application do
    # Pas de `extra_applications` : tout ce qui est listé ici finit dans le
    # packbeam flashé sur l'ESP32, et AtomVM n'a ni :logger ni la majorité
    # d'OTP. Autant que la contrainte morde dès la phase 1 sur le Mac plutôt
    # qu'à la phase 2 quand le code aura pris l'habitude.
    []
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    # Aucune dépendance, et c'est une contrainte à tenir : le JSON du corpus est
    # décodé par le module `JSON` intégré à Elixir 1.18. Chaque dépendance est
    # du code à faire tenir dans AtomVM, qui n'implémente qu'un sous-ensemble
    # d'OTP et des instructions BEAM.
    []
  end
end
