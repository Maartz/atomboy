defmodule Atomboy.Native.Asm do
  @moduledoc """
  Labels, forward references, and the pass that fills the holes.

  `Atomboy.Native.RV32` encodes an instruction whose operands are all known. An
  interpreter produces almost none of those: `j fetch` jumps to a label whose
  address depends on everything emitted after it. This module is the missing
  layer -- and it is small, because one rule keeps it small.

  ## The rule: no size depends on a distance

  Nothing is compressed (see `Atomboy.Native.RV32`), so every item knows its
  size before a single address is resolved. Pass one walks the items summing
  sizes and notes where each label lands; pass two walks again emitting bytes,
  filling the holes with the distances now known.

  Without that rule this would need a fixed point: a distant branch takes more
  room, which pushes later targets further away, which lengthens other branches.
  That is branch relaxation, and it costs a hundred times its worth in bytes as
  long as the code fits in the instruction cache.

  The invariant that locks it down -- *the number of bytes emitted in pass two
  equals the size computed in pass one* -- is checked on every assembly, not
  just in tests. A size regression is the kind of bug that produces code which
  runs and gives wrong answers.

  ## The items

      binary                    already-encoded bytes -- instruction or data
      {:label, name}            zero size; defines an address
      {:align, n}               zero padding up to a multiple of n
      {:ref, name, encoder}     4 bytes, filled by `encoder.(distance)`
      {:addr, name}             4 bytes: the label's absolute address
      {:la, rd, name}           8 bytes: loads name's address into rd
      {:space, n}               n zero bytes

  `{:addr, name}` is what makes the jump table possible: 256 words holding each
  handler's address, loaded with an `lw` and followed by a `jr`.
  """

  import Bitwise

  alias Atomboy.Native.RV32

  @typedoc "One assembly item."
  @type item ::
          binary()
          | {:label, atom()}
          | {:align, pos_integer()}
          | {:ref, atom(), (integer() -> binary())}
          | {:addr, atom()}
          | {:la, RV32.reg(), atom()}
          | {:space, non_neg_integer()}

  @typedoc "The result of an assembly: the bytes, and where each label landed."
  @type assembled :: %{
          code: binary(),
          labels: %{atom() => non_neg_integer()},
          size: non_neg_integer()
        }

  @doc """
  Assembles a list of items starting from address `base`.

  `base` is where the image will be loaded: `{:addr, _}` items hold absolute
  addresses, so the assembler has to know it.
  """
  @spec assemble([item()], non_neg_integer()) :: assembled()
  def assemble(items, base \\ 0) do
    items = List.flatten(items)
    {size, labels} = measure(items)
    code = emit(items, base, labels)

    unless byte_size(code) == size do
      raise "inconsistent assembly: pass one announced #{size} bytes, pass two emitted #{byte_size(code)}"
    end

    %{code: code, labels: labels, size: size}
  end

  @doc """
  A label's absolute address within an assembly.
  """
  @spec address(assembled(), atom(), non_neg_integer()) :: non_neg_integer()
  def address(%{labels: labels}, name, base \\ 0) do
    case labels do
      %{^name => offset} -> base + offset
      _ -> raise ArgumentError, "unknown label: #{inspect(name)}"
    end
  end

  # ══ Pass one: sizes and labels ═══════════════════════════════════════════════

  defp measure(items) do
    Enum.reduce(items, {0, %{}}, fn item, {offset, labels} ->
      case item do
        {:label, name} ->
          if Map.has_key?(labels, name) do
            raise ArgumentError, "label defined twice: #{inspect(name)}"
          end

          {offset, Map.put(labels, name, offset)}

        _ ->
          {offset + size(item, offset), labels}
      end
    end)
  end

  defp size(binary, _offset) when is_binary(binary), do: byte_size(binary)
  defp size({:ref, _, _}, _offset), do: 4
  defp size({:addr, _}, _offset), do: 4
  defp size({:la, _, _}, _offset), do: 8
  defp size({:space, n}, _offset), do: n
  defp size({:align, n}, offset), do: padding(offset, n)

  defp size(item, _offset) do
    raise ArgumentError, "unknown assembly item: #{inspect(item)}"
  end

  defp padding(offset, n) do
    case rem(offset, n) do
      0 -> 0
      r -> n - r
    end
  end

  # ══ Pass two: the bytes ══════════════════════════════════════════════════════

  defp emit(items, base, labels) do
    {chunks, _offset} =
      Enum.reduce(items, {[], 0}, fn item, {chunks, offset} ->
        case item do
          {:label, _} ->
            {chunks, offset}

          _ ->
            bytes = bytes(item, offset, base, labels)
            {[bytes | chunks], offset + byte_size(bytes)}
        end
      end)

    chunks |> Enum.reverse() |> IO.iodata_to_binary()
  end

  defp bytes(binary, _offset, _base, _labels) when is_binary(binary), do: binary
  defp bytes({:space, n}, _offset, _base, _labels), do: <<0::size(n * 8)>>
  defp bytes({:align, n}, offset, _base, _labels), do: <<0::size(padding(offset, n) * 8)>>

  defp bytes({:addr, name}, _offset, base, labels) do
    <<base + resolve!(labels, name)::32-little>>
  end

  defp bytes({:ref, name, encoder}, offset, _base, labels) do
    encoder.(resolve!(labels, name) - offset)
  end

  # `auipc` lays down the top 20 bits of a PC-relative distance, `addi` adds the
  # low 12 -- and since `addi` sign-extends, the high bits are rounded to
  # compensate, exactly as in `RV32.li/2`. PC-relative rather than absolute: the
  # image stays relocatable, which will matter the day it is no longer loaded at
  # 0x8000_0000 but somewhere in a C6's flash.
  defp bytes({:la, rd, name}, offset, _base, labels) do
    delta = resolve!(labels, name) - offset
    high = (delta + 0x800) >>> 12 &&& 0xFFFFF
    low = delta - (high <<< 12) &&& 0xFFF
    low = if low > 0x7FF, do: low - 0x1000, else: low

    RV32.auipc(rd, high) <> RV32.addi(rd, rd, low)
  end

  defp resolve!(labels, name) do
    case labels do
      %{^name => offset} ->
        offset

      _ ->
        raise ArgumentError,
              "unknown label: #{inspect(name)} -- defined: #{labels |> Map.keys() |> Enum.sort() |> Enum.join(", ")}"
    end
  end

  # ══ The emitters that target a label ═════════════════════════════════════════

  @doc "Defines a label at the current position."
  @spec label(atom()) :: item()
  def label(name), do: {:label, name}

  @doc "An unconditional jump to a label."
  @spec j(atom()) :: item()
  def j(name), do: {:ref, name, &RV32.j/1}

  @doc "A subroutine call: the return address goes into `ra`."
  @spec call(atom()) :: item()
  def call(name), do: {:ref, name, &RV32.jal(:ra, &1)}

  @doc """
  Loads a label's address into a register -- two instructions.

  This is what lets the driver point at the jump table, the state area and the
  64 KB of emulated memory without a single absolute address hard-coded
  anywhere.
  """
  @spec la(RV32.reg(), atom()) :: item()
  def la(rd, name), do: {:la, rd, name}

  for branch <- [:beq, :bne, :blt, :bge, :bltu, :bgeu] do
    @doc "`#{branch} rs1, rs2, label`"
    @spec unquote(branch)(RV32.reg(), RV32.reg(), atom()) :: item()
    def unquote(branch)(rs1, rs2, name) do
      {:ref, name, &RV32.unquote(branch)(rs1, rs2, &1)}
    end
  end

  @doc "A branch taken when the register is zero -- `beq rs, zero`."
  @spec beqz(RV32.reg(), atom()) :: item()
  def beqz(rs, name), do: beq(rs, :zero, name)

  @doc "A branch taken when the register is non-zero -- `bne rs, zero`."
  @spec bnez(RV32.reg(), atom()) :: item()
  def bnez(rs, name), do: bne(rs, :zero, name)
end
