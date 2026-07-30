defmodule Mix.Tasks.Atomboy.Progress do
  @shortdoc "Shows SM83 decoder coverage"

  @moduledoc """
  Where the decoder stands, opcode by opcode.

      mix atomboy.progress

  A 16×16 grid per table. `#` implemented, `·` remaining, `×` invalid encoding
  on the SM83, `»` the prefix of the extended table.

  What the grid gives over a plain percentage: the SM83 table is regular in
  blocks, so the holes read as families. A whole empty column is an unhandled
  `z` — one family to generate in a single pass, not eight opcodes to write.
  """

  use Mix.Task

  alias Mix.Tasks.Atomboy.Corpus

  @tables [{nil, "Base table"}, {:cb, "CB table"}]

  @impl true
  def run(_args) do
    Mix.Task.run("compile")

    implemented = MapSet.new(Atomboy.CPU.implemented())
    valid = if Corpus.available?(), do: Corpus.opcodes(), else: nil

    Enum.each(@tables, &render(&1, implemented, valid))

    if is_nil(valid) do
      Mix.shell().info(
        "\nCorpus missing — invalid encodings not singled out. `mix atomboy.corpus`"
      )
    end
  end

  defp render({prefix, title}, implemented, valid) do
    done = Enum.count(implemented, fn {p, _op} -> p == prefix end)

    # The denominator is what there is to write — so the corpus vectors plus,
    # for the base table, the prefix dispatcher that has none.
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
