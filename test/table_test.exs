defmodule Atomboy.CPU.TableTest do
  @moduledoc """
  Internal consistency of the instruction table.

  These invariants do not test the emulation — the SM83 vectors take care of that
  — but the kinds of mistake the vectors cannot see. An opcode described twice
  yields a dead clause, which the compiler reports at best as a warning drowned in
  the output; the vectors would pass without a word, since the first clause wins.
  """

  use ExUnit.Case, async: true

  alias Atomboy.CPU.Insn
  alias Atomboy.CPU.Table

  test "no opcode is described twice" do
    duplicates =
      Table.all()
      |> Enum.frequencies_by(&{&1.prefix, &1.opcode})
      |> Enum.filter(fn {_key, count} -> count > 1 end)

    assert duplicates == []
  end

  test "cycle counts are whole M-cycles" do
    # The SM83 has no instruction shorter than an M-cycle, and the bus does not
    # subdivide: every duration is a multiple of 4 T-cycles.
    bad =
      Enum.reject(Table.all(), fn insn ->
        insn.cycles > 0 and rem(insn.cycles, 4) == 0
      end)

    assert bad == [], "invalid cycles: #{inspect(Enum.map(bad, &{&1.opcode, &1.cycles}))}"
  end

  test "opcodes fit in one byte" do
    assert Enum.all?(Table.all(), &(&1.opcode in 0..0xFF))
  end

  test "0x76 is HALT, not LD (HL), (HL)" do
    # "LD (HL), (HL)" would land here naturally if the LD block's comprehension
    # forgot its exclusion — the duplicate would be caught by the uniqueness test,
    # but this one names the cause.
    assert [%Insn{mnemonic: :halt}] = Enum.filter(Table.base(), &(&1.opcode == 0x76))
  end

  test "every instruction has a readable name" do
    for insn <- Table.all() do
      assert is_binary(Insn.label(insn))
      refute Insn.label(insn) == ""
    end
  end

  test "the table and the decoder describe the same set" do
    described = MapSet.new(Table.all(), &{&1.prefix, &1.opcode})

    # The 0xCB dispatcher is implemented without appearing in the table: it is a
    # prefix, not an instruction — it has neither cycles nor semantics of its own.
    compiled =
      Atomboy.CPU.implemented()
      |> MapSet.new()
      |> MapSet.delete({nil, Mix.Tasks.Atomboy.Corpus.prefix_opcode()})

    assert described == compiled
  end
end
