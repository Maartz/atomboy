defmodule Atomboy.CPU.TableTest do
  @moduledoc """
  Cohérence interne de la table d'instructions.

  Ces invariants ne testent pas l'émulation — les vecteurs SM83 s'en chargent —
  mais des fautes que les vecteurs ne peuvent pas voir. Un opcode décrit deux
  fois donne une clause morte que le compilateur signale au mieux par un
  avertissement noyé dans la sortie ; les vecteurs, eux, passeraient sans rien
  dire puisque la première clause gagne.
  """

  use ExUnit.Case, async: true

  alias Atomboy.CPU.Insn
  alias Atomboy.CPU.Table

  test "aucun opcode n'est décrit deux fois" do
    duplicates =
      Table.all()
      |> Enum.frequencies_by(&{&1.prefix, &1.opcode})
      |> Enum.filter(fn {_key, count} -> count > 1 end)

    assert duplicates == []
  end

  test "les cycles sont des M-cycles entiers" do
    # Le SM83 n'a pas d'instruction plus courte qu'un M-cycle, et le bus ne se
    # divise pas : toute durée est un multiple de 4 T-cycles.
    bad =
      Enum.reject(Table.all(), fn insn ->
        insn.cycles > 0 and rem(insn.cycles, 4) == 0
      end)

    assert bad == [], "cycles invalides : #{inspect(Enum.map(bad, &{&1.opcode, &1.cycles}))}"
  end

  test "les opcodes tiennent sur un octet" do
    assert Enum.all?(Table.all(), &(&1.opcode in 0..0xFF))
  end

  test "0x76 est HALT, pas LD (HL), (HL)" do
    # « LD (HL), (HL) » tomberait naturellement ici si la compréhension du bloc
    # LD oubliait son exclusion — le doublon serait attrapé par le test
    # d'unicité, mais celui-ci nomme la cause.
    assert [%Insn{mnemonic: :halt}] = Enum.filter(Table.base(), &(&1.opcode == 0x76))
  end

  test "chaque instruction a un nom lisible" do
    for insn <- Table.all() do
      assert is_binary(Insn.label(insn))
      refute Insn.label(insn) == ""
    end
  end

  test "la table et le décodeur décrivent le même ensemble" do
    described = MapSet.new(Table.all(), &{&1.prefix, &1.opcode})
    compiled = MapSet.new(Atomboy.CPU.implemented())

    assert described == compiled
  end
end
