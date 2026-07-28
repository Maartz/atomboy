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
  """
  @type operand :: {:reg, atom()} | :hl_ind | {:imm, 8}

  @type t :: %__MODULE__{
          opcode: 0..0xFF,
          prefix: nil | :cb,
          mnemonic: atom(),
          operands: [operand()],
          cycles: pos_integer()
        }

  @enforce_keys [:opcode, :mnemonic, :cycles]
  defstruct [:opcode, :mnemonic, :cycles, operands: [], prefix: nil]

  @doc """
  Le nom lisible de l'instruction, en syntaxe assembleur.

      iex> Atomboy.CPU.Insn.label(%Atomboy.CPU.Insn{opcode: 0x46, mnemonic: :ld, operands: [{:reg, :b}, :hl_ind], cycles: 8})
      "LD B, (HL)"

  Utilisé dans les messages d'erreur et le tableau de bord : `opcode 46` ne dit
  rien, `LD B, (HL)` désigne l'instruction.
  """
  @spec label(t()) :: String.t()
  def label(%__MODULE__{mnemonic: mnemonic, operands: []}) do
    mnemonic |> Atom.to_string() |> String.upcase()
  end

  def label(%__MODULE__{mnemonic: mnemonic, operands: operands}) do
    String.upcase(Atom.to_string(mnemonic)) <> " " <> Enum.map_join(operands, ", ", &operand/1)
  end

  defp operand(:hl_ind), do: "(HL)"
  defp operand({:imm, 8}), do: "d8"
  defp operand({:reg, name}), do: name |> Atom.to_string() |> String.upcase()
end
