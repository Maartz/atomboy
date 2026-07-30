defmodule Atomboy.SingleStep do
  @moduledoc """
  Replays the SingleStepTests/sm83 vectors against `Atomboy.CPU`.

  Each vector gives a complete machine state before and after **one** single
  instruction: the ten registers, IME, IE, and the list of memory addresses
  touched along with their contents. The harness rebuilds that state, runs one
  `step/3`, and compares field by field.

  ## What is checked, and what is not

  Checked: the registers, the flags, IME, the final memory at each listed address,
  and the **number** of cycles.

  Not checked: the bus access log (`cycles`), which gives, for each M-cycle, the
  address touched and the direction. That is cycle-accuracy, a declared non-goal of
  the project — but the data is there, and the assertion will fit in a few lines the
  day the PPU demands to know *when* within the instruction an access falls.
  """

  import Bitwise

  alias Atomboy.CPU.State
  alias Atomboy.Memory.Flat
  alias Mix.Tasks.Atomboy.Corpus

  @typedoc "A failure: the offending vector and the fields that diverge."
  @type failure :: %{name: String.t(), diffs: [{atom(), term(), term()}]}

  @doc "Is the corpus installed?"
  @spec corpus?() :: boolean()
  defdelegate corpus?(), to: Corpus, as: :available?

  @doc "The opcodes for which the corpus supplies a file."
  @spec available_opcodes() :: MapSet.t({Atomboy.CPU.prefix(), 0..0xFF})
  defdelegate available_opcodes(), to: Corpus, as: :opcodes

  @doc """
  Replays every vector of one opcode.

  Returns `{vector_count, failures}`. A correct opcode yields an empty list of
  failures.
  """
  @spec run(Atomboy.CPU.prefix(), 0..0xFF) :: {non_neg_integer(), [failure()]}
  def run(prefix, opcode) do
    vectors = load(prefix, opcode)
    {length(vectors), Enum.flat_map(vectors, &check/1)}
  end

  @doc "Loads and decodes an opcode's vector file."
  @spec load(Atomboy.CPU.prefix(), 0..0xFF) :: [map()]
  def load(prefix, opcode) do
    Corpus.dir()
    |> Path.join("v1/#{file_name(prefix, opcode)}.json")
    |> File.read!()
    |> JSON.decode!()
  end

  @doc """
  An opcode's file name. Prefixed opcodes carry a space: `cb 40.json`.
  """
  @spec file_name(Atomboy.CPU.prefix(), 0..0xFF) :: String.t()
  def file_name(nil, opcode), do: hex(opcode)
  def file_name(:cb, opcode), do: "cb " <> hex(opcode)

  @doc """
  Formats a failure for the test report.

  The message aims at real use: you look at this after writing a family of opcodes,
  with dozens of correlated failures. Hence the overall count, the detail on a
  single vector, and the flags spelled out — `f: 176 instead of 144` says nothing,
  `Z-HC instead of Z-H-` names the bit.
  """
  @spec format_failures(Atomboy.CPU.prefix(), 0..0xFF, non_neg_integer(), [failure()]) ::
          String.t()
  def format_failures(prefix, opcode, total, failures) do
    first = hd(failures)

    diffs =
      Enum.map_join(first.diffs, "\n", fn {field, expected, got} ->
        "      #{field}: expected #{show(field, expected)}, got #{show(field, got)}"
      end)

    """
    opcode #{file_name(prefix, opcode)}: #{length(failures)}/#{total} vectors failing

      first failure — vector "#{first.name}"
    #{diffs}
    """
  end

  # ── Internals ───────────────────────────────────────────────────────────────

  defp check(%{"initial" => initial, "final" => final, "cycles" => cycles} = vector) do
    mem = Flat.new(for [addr, value] <- initial["ram"], do: {addr, value})

    {state, mem, t_cycles} = Atomboy.CPU.step(state_from(initial), mem)

    case diff(final, cycles, state, mem, t_cycles) do
      [] -> []
      diffs -> [%{name: vector["name"], diffs: diffs}]
    end
  end

  defp state_from(vector) do
    %State{
      a: vector["a"],
      f: vector["f"],
      b: vector["b"],
      c: vector["c"],
      d: vector["d"],
      e: vector["e"],
      h: vector["h"],
      l: vector["l"],
      sp: vector["sp"],
      pc: vector["pc"],
      ime: vector["ime"],
      ie: vector["ie"] || 0
    }
  end

  defp diff(final, cycles, state, mem, t_cycles) do
    got = Map.take(state, [:a, :f, :b, :c, :d, :e, :h, :l, :sp, :pc, :ime])

    register_diffs =
      for {field, actual} <- got,
          # `ie`, and sometimes `ime`, are absent from some vectors' final state:
          # what is not asserted is not compared.
          Map.has_key?(final, Atom.to_string(field)),
          expected = final[Atom.to_string(field)],
          expected != actual,
          do: {field, expected, actual}

    memory_diffs =
      for [addr, expected] <- final["ram"] || [],
          actual = Flat.read8(mem, addr),
          actual != expected,
          do: {:"mem[#{hex16(addr)}]", expected, actual}

    # One bus M-cycle is worth 4 T-cycles.
    expected_cycles = length(cycles) * 4

    cycle_diffs =
      if t_cycles == expected_cycles, do: [], else: [{:t_cycles, expected_cycles, t_cycles}]

    Enum.sort(register_diffs) ++ Enum.sort(memory_diffs) ++ cycle_diffs
  end

  defp hex(value),
    do: value |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(2, "0")

  defp hex16(value),
    do: "0x" <> (value |> Integer.to_string(16) |> String.upcase() |> String.pad_leading(4, "0"))

  # The F register deserves separate treatment: it is the field that breaks most
  # often, and its numeric value teaches you nothing.
  defp show(:f, value) do
    flags =
      [{0x80, "Z"}, {0x40, "N"}, {0x20, "H"}, {0x10, "C"}]
      |> Enum.map_join(fn {bit, letter} -> if (value &&& bit) != 0, do: letter, else: "-" end)

    "#{flags} (0x#{hex(value)})"
  end

  defp show(:t_cycles, value), do: "#{value} T"
  defp show(field, value) when field in [:sp, :pc], do: hex16(value)
  defp show(_field, value) when is_integer(value), do: "0x#{hex(value)}"
  defp show(_field, value), do: inspect(value)
end
