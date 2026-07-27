defmodule Atomboy.SM83Test do
  @moduledoc """
  Un test ExUnit par opcode implémenté, rejouant les ~1 000 vecteurs du corpus.

  Le découpage est volontaire : un test par opcode, pas un test par vecteur.
  500 000 tests ExUnit coûteraient plus cher en surcoût de framework qu'en
  émulation, et le grain utile est l'opcode — c'est l'unité qu'on écrit, et
  celle qu'on corrige.

  La liste des tests est dérivée de `Atomboy.CPU.implemented/0`, elle-même
  accumulée par les clauses du décodeur à la compilation. Un opcode ajouté est
  donc testé sans que personne ait à inscrire quoi que ce soit ici — et il n'y a
  pas d'état où le décodeur avance sans que les tests suivent.
  """

  use ExUnit.Case, async: true

  alias Atomboy.SingleStep

  if SingleStep.corpus?() do
    available = SingleStep.available_opcodes()
    implemented = Atomboy.CPU.implemented()

    for {prefix, opcode} <- implemented, MapSet.member?(available, {prefix, opcode}) do
      test "opcode #{SingleStep.file_name(prefix, opcode)}" do
        prefix = unquote(prefix)
        opcode = unquote(opcode)

        {total, failures} = SingleStep.run(prefix, opcode)

        assert total > 0, "aucun vecteur chargé pour #{SingleStep.file_name(prefix, opcode)}"

        # `assert/2` évalue son message même quand l'assertion tient : le
        # formateur ne doit être appelé que sur un échec réel.
        if failures != [] do
          flunk(SingleStep.format_failures(prefix, opcode, total, failures))
        end
      end
    end

    # Un opcode implémenté sans fichier de vecteurs est un opcode inventé — à une
    # exception près : 0xCB est le préfixe de la table étendue, il sera bien
    # implémenté et n'aura jamais de vecteurs propres.
    for {prefix, opcode} <- implemented,
        not MapSet.member?(available, {prefix, opcode}),
        {prefix, opcode} != {nil, Mix.Tasks.Atomboy.Corpus.prefix_opcode()} do
      test "opcode #{SingleStep.file_name(prefix, opcode)} n'existe pas sur le SM83" do
        flunk("""
        #{SingleStep.file_name(unquote(prefix), unquote(opcode))} est implémenté dans \
        Atomboy.CPU mais n'a pas de fichier de vecteurs.

        Les onze encodages 0xD3, 0xDB, 0xDD, 0xE3, 0xE4, 0xEB, 0xEC, 0xED, 0xF4, \
        0xFC et 0xFD sont invalides sur le SM83 — ils bloquent le CPU. Si celui-ci \
        en fait partie, la clause vient probablement d'une table Z80.
        """)
      end
    end
  else
    IO.warn(
      """
      Corpus SingleStepTests absent — les tests CPU ne sont pas générés.

          mix atomboy.corpus
      """,
      []
    )
  end
end
