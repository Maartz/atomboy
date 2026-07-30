defmodule Atomboy.CPU.Insn do
  @moduledoc """
  The description of one SM83 instruction.

  ## A compile-time struct, never a runtime one

  This struct describes what an instruction *is*. It is built at compile time by
  `Atomboy.CPU.Table`, consumed by `Atomboy.CPU.Gen` which derives a function
  clause from it, and then **it vanishes**. No `%Insn{}` exists at runtime.

  The distinction is structural, not cosmetic. In Elixir a struct is a map. An
  emulator that decoded into an `%Insn{}` at runtime would pay, per emulated
  instruction, one map allocation plus a hashed lookup per field — 500,000
  allocations per second to represent information entirely known at compile time.
  That is the classic trap of the "clean" interpreter, and it is slower than the
  table of clauses it replaces.

  Describing the instruction as data and making it vanish at compile time gives
  you both: a readable table, and flat code with no indirection.

  ## The second consumer

  The real value of this table is not the interpreter — a `for` with some opcode
  arithmetic would have been enough. It is that in **phase 5**, the static
  recompiler will read the *same* table to emit Core Erlang. Without it, two
  decoders would have to be maintained in parallel and kept in agreement by
  hand; with it, the interpreter and the recompiler are two backends over a
  single source of truth.
  """

  @typedoc """
  An operand.

    * `{:reg, :b}` — an 8-bit register
    * `:hl_ind` — the byte in memory at address HL, the `r = 6` encoding
    * `{:imm, 8}` — an immediate byte, read at PC; the instruction advances PC
    * `{:imm, 16}` — a little-endian immediate word, PC advances by two
    * `{:pair, :bc}` — a 16-bit pair (`:bc`, `:de`, `:hl`, `:sp`)
    * `{:ind, :bc}` — the byte in memory at a pair's address; `:hl_inc` and
      `:hl_dec` post-increment or post-decrement HL after the access
    * `:a16_ind` — the memory at the address given by an immediate word
    * `{:rst, 0x28}` — a RST's fixed target, encoded in the opcode
    * `:a8_ind` — the high page: 0xFF00 + an immediate byte
    * `:c_ind` — the high page through C: 0xFF00 + C
    * `{:bit, 3}` — a BIT/RES/SET's bit number, encoded in the opcode
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
          | :a8_ind
          | :c_ind
          | {:bit, 0..7}

  @typedoc """
  A branch condition, or `nil` for unconditional instructions.
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
  The instruction's readable name, in assembler syntax.

      iex> Atomboy.CPU.Insn.label(%Atomboy.CPU.Insn{opcode: 0x46, mnemonic: :ld, operands: [{:reg, :b}, :hl_ind], cycles: 8})
      "LD B, (HL)"

  Used in error messages and on the dashboard: `opcode 46` says nothing,
  `LD B, (HL)` names the instruction.
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
  defp operand({:bit, n}), do: Integer.to_string(n)
  defp operand(:a8_ind), do: "(a8)"
  defp operand(:c_ind), do: "(C)"
  defp operand({:imm, 8}), do: "d8"
  defp operand({:imm, 16}), do: "d16"
  defp operand({:ind, :hl_inc}), do: "(HL+)"
  defp operand({:ind, :hl_dec}), do: "(HL-)"
  defp operand({:ind, name}), do: "(" <> String.upcase(Atom.to_string(name)) <> ")"
  defp operand({:pair, name}), do: name |> Atom.to_string() |> String.upcase()
  defp operand({:reg, name}), do: name |> Atom.to_string() |> String.upcase()
end
