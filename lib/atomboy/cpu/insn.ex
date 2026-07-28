defmodule Atomboy.CPU.Insn do
  @moduledoc """
  La description d'une instruction SM83.

  ## Un struct de compilation, jamais d'exécution

  Ce struct décrit ce qu'*est* une instruction. Il est construit à la
  compilation par `Atomboy.CPU.Table`, consommé par `Atomboy.CPU.Gen` qui en
  dérive une clause de fonction, puis **il disparaît**. Aucun `%Insn{}` n'existe
  à l'exécution.

  La distinction est structurante, pas cosmétique. En Elixir un struct est une
  map. Un émulateur qui décoderait vers un `%Insn{}` à l'exécution paierait, par
  instruction émulée, une allocation de map plus un accès haché par champ — soit
  500 000 allocations par seconde pour représenter une information entièrement
  connue à la compilation. C'est le piège classique de l'interpréteur « propre »,
  et il est plus lent que le tableau de clauses qu'il remplace.

  Décrire l'instruction en donnée et la faire disparaître à la compilation donne
  les deux : une table lisible, et du code plat sans indirection.

  ## Le second consommateur

  L'intérêt réel de cette table n'est pas l'interpréteur — un `for` avec de
  l'arithmétique d'opcode aurait suffi. C'est qu'en **phase 5**, le
  recompilateur statique lira la *même* table pour émettre du Core Erlang. Sans
  elle, il faudrait maintenir deux décodages en parallèle et garantir à la main
  qu'ils s'accordent ; avec elle, l'interpréteur et le recompilateur sont deux
  backends d'une seule source de vérité.
  """

  @typedoc """
  Un opérande.

    * `{:reg, :b}` — un registre 8 bits
    * `:hl_ind` — l'octet en mémoire à l'adresse HL, l'encodage `r = 6`
    * `{:imm, 8}` — un octet immédiat, lu à PC ; l'instruction avance PC
    * `{:imm, 16}` — un mot immédiat little-endian, PC avance de deux
    * `{:pair, :bc}` — une paire 16 bits (`:bc`, `:de`, `:hl`, `:sp`)
    * `{:ind, :bc}` — l'octet en mémoire à l'adresse d'une paire ; `:hl_inc` et
      `:hl_dec` post-incrémentent ou décrémentent HL après l'accès
    * `:a16_ind` — la mémoire à l'adresse donnée par un mot immédiat
    * `{:rst, 0x28}` — la cible fixe d'un RST, encodée dans l'opcode
  """
  @type operand ::
          {:reg, atom()}
          | :hl_ind
          | {:imm, 8}
          | {:imm, 16}
          | {:pair, atom()}
          | {:ind, :bc | :de | :hl_inc | :hl_dec}
          | :a16_ind
          | {:rst, 0..0x38}

  @typedoc """
  Une condition de branchement, ou `nil` pour les instructions inconditionnelles.
  """
  @type condition :: nil | :nz | :z | :nc | :c

  @type t :: %__MODULE__{
          opcode: 0..0xFF,
          prefix: nil | :cb,
          mnemonic: atom(),
          operands: [operand()],
          condition: condition(),
          cycles: pos_integer(),
          cycles_untaken: nil | pos_integer()
        }

  @enforce_keys [:opcode, :mnemonic, :cycles]
  defstruct [
    :opcode,
    :mnemonic,
    :cycles,
    operands: [],
    prefix: nil,
    condition: nil,
    cycles_untaken: nil
  ]

  @doc """
  Le nom lisible de l'instruction, en syntaxe assembleur.

      iex> Atomboy.CPU.Insn.label(%Atomboy.CPU.Insn{opcode: 0x46, mnemonic: :ld, operands: [{:reg, :b}, :hl_ind], cycles: 8})
      "LD B, (HL)"

  Utilisé dans les messages d'erreur et le tableau de bord : `opcode 46` ne dit
  rien, `LD B, (HL)` désigne l'instruction.
  """
  @spec label(t()) :: String.t()
  def label(%__MODULE__{mnemonic: mnemonic, condition: condition, operands: operands}) do
    parts = condition_label(condition) ++ Enum.map(operands, &operand/1)
    name = mnemonic |> Atom.to_string() |> String.upcase()

    case parts do
      [] -> name
      parts -> name <> " " <> Enum.join(parts, ", ")
    end
  end

  defp condition_label(nil), do: []
  defp condition_label(condition), do: [condition |> Atom.to_string() |> String.upcase()]

  defp operand({:rst, target}),
    do: (target |> Integer.to_string(16) |> String.pad_leading(2, "0")) <> "H"

  defp operand(:hl_ind), do: "(HL)"
  defp operand(:a16_ind), do: "(a16)"
  defp operand({:imm, 8}), do: "d8"
  defp operand({:imm, 16}), do: "d16"
  defp operand({:ind, :hl_inc}), do: "(HL+)"
  defp operand({:ind, :hl_dec}), do: "(HL-)"
  defp operand({:ind, name}), do: "(" <> String.upcase(Atom.to_string(name)) <> ")"
  defp operand({:pair, name}), do: name |> Atom.to_string() |> String.upcase()
  defp operand({:reg, name}), do: name |> Atom.to_string() |> String.upcase()
end
