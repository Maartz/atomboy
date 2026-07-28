defmodule Atomboy.BlarggTest do
  @moduledoc """
  Les ROMs individuelles de blargg `cpu_instrs` — le test d'intégration de la
  phase 1.

  Les vecteurs SM83 valident chaque instruction isolément ; blargg valide
  l'ensemble en situation : enchaînements, pile, DAA après de vraies
  séquences BCD, sauts calculés. C'est le critère de fin de phase 1 du brief.

  Exclus du `mix test` ordinaire (~30 s de plus) :

      mix test --include blargg

  `02-interrupts` est ignoré tant que le contrôleur d'interruptions n'existe
  pas — c'est le premier chantier de la phase suivante, pas un oubli.
  """

  use ExUnit.Case, async: true

  @moduletag :blargg
  @moduletag timeout: 300_000

  alias Mix.Tasks.Atomboy.Corpus

  if Corpus.cpu_instrs_roms() == [] do
    IO.warn("ROMs blargg absentes — `mix atomboy.corpus` pour les récupérer.", [])
  end

  for rom <- Corpus.cpu_instrs_roms() do
    name = Path.basename(rom, ".gb")

    test name do
      case Atomboy.Blargg.run(unquote(rom)) do
        {:passed, _report} ->
          :ok

        {:failed, report} ->
          flunk("échec :\n#{report}")

        {:timeout, report} ->
          flunk("pas de verdict avant la limite de cycles :\n#{report}")
      end
    end
  end
end
