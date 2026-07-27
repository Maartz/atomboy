defmodule Mix.Tasks.Atomboy.Progress do
  @shortdoc "Affiche la couverture du décodeur SM83"

  @moduledoc """
  Où en est le décodeur, opcode par opcode.

      mix atomboy.progress

  Une grille 16×16 par table. `#` implémenté, `·` restant, `×` encodage
  invalide sur le SM83, `»` le préfixe de la table étendue.

  L'intérêt de la grille sur un simple pourcentage : la table SM83 est régulière
  par blocs, donc les trous se lisent par familles. Une colonne entière vide,
  c'est un `z` non traité — une famille à générer d'un coup, pas huit opcodes à
  écrire.
  """

  use Mix.Task

  alias Mix.Tasks.Atomboy.Corpus

  @tables [{nil, "Table de base"}, {:cb, "Table CB"}]

  @impl true
  def run(_args) do
    Mix.Task.run("compile")

    implemented = MapSet.new(Atomboy.CPU.implemented())
    valid = if Corpus.available?(), do: Corpus.opcodes(), else: nil

    Enum.each(@tables, &render(&1, implemented, valid))

    if is_nil(valid) do
      Mix.shell().info(
        "\nCorpus absent — encodages invalides non distingués. `mix atomboy.corpus`"
      )
    end
  end

  defp render({prefix, title}, implemented, valid) do
    done = Enum.count(implemented, fn {p, _op} -> p == prefix end)

    # Le dénominateur, c'est ce qu'il y a à écrire — donc les vecteurs du corpus
    # plus, pour la table de base, le dispatcher de préfixe qui n'en a pas.
    total =
      cond do
        is_nil(valid) -> 256
        prefix == nil -> Enum.count(valid, fn {p, _op} -> p == prefix end) + 1
        true -> Enum.count(valid, fn {p, _op} -> p == prefix end)
      end

    Mix.shell().info("\n#{title} — #{done}/#{total}\n")
    Mix.shell().info("     " <> Enum.map_join(0..15, " ", &digit/1))

    Enum.each(0..15, fn hi ->
      row =
        Enum.map_join(0..15, " ", fn lo ->
          cell(prefix, hi * 16 + lo, implemented, valid)
        end)

      Mix.shell().info("  #{digit(hi)}x #{row}")
    end)
  end

  defp cell(prefix, opcode, implemented, valid) do
    key = {prefix, opcode}

    cond do
      MapSet.member?(implemented, key) -> "#"
      key == {nil, Corpus.prefix_opcode()} -> "»"
      valid && not MapSet.member?(valid, key) -> "×"
      true -> "·"
    end
  end

  defp digit(n), do: n |> Integer.to_string(16) |> String.downcase()
end
