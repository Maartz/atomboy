defmodule Potion.AssemblerTest do
  @moduledoc """
  The assembler against the table it is drawn from.

  The first test is the only one that really counts: it rebuilds a source
  instruction for **each** of the instructions in `Atomboy.CPU.Table.all/0`,
  assembles it, and compares the bytes with what the table announces — prefix,
  opcode, immediates in little-endian. It enumerates nothing by hand and has
  nothing to keep up to date: a family added to the table is covered
  immediately, and an operand shape the assembler would not know how to write
  fails here rather than in a ROM.

  It is the same mechanism `Atomboy.CPU.LoopTest` applies to the two execution
  backends: rather than checking a chosen sample, we check the whole set and
  report every divergence at once. A failure lists the offending instructions,
  not just the first one.

  The rest checks what the table does not say: label resolution, immediate
  ranges, and — the last link — that an assembled program does run on the CPU
  oracle and computes what is written.
  """

  use ExUnit.Case, async: true

  alias Atomboy.CPU.Insn
  alias Atomboy.CPU.State
  alias Atomboy.CPU.Table
  alias Atomboy.Memory.Flat
  alias Potion.Assembler

  doctest Potion.Assembler

  # Recognisable dummy values: a byte that is not an interesting opcode, a word
  # whose two halves differ — enough to spot a flipped little-endian.
  @d8 0x12
  @d16 0x1234

  describe "round trip with the table" do
    test "the #{length(Table.all())} instructions of the table assemble as they decode" do
      divergences =
        for %Insn{} = insn <- Table.all(),
            emitted = Assembler.assemble([source(insn)]),
            expected = expected(insn),
            emitted != expected,
            do: {Insn.label(insn), insn.prefix, insn.opcode, expected, emitted}

      assert divergences == []
    end

    test "every instruction takes up exactly the bytes it announces" do
      # Assembling two instructions back to back is the concatenation of the
      # two: nothing overlaps, nothing is lost. It is the size invariant seen
      # from the outside.
      for %Insn{} = insn <- Table.all() do
        alone = Assembler.assemble([source(insn)])
        doubled = Assembler.assemble([source(insn), source(insn)])

        assert doubled == alone <> alone, "incorrect chaining for #{Insn.label(insn)}"
      end
    end
  end

  describe "the ambiguous operands" do
    test ":c reads as a register or a condition depending on the instruction" do
      # No syntactic rule tells them apart — only the table knows which of the
      # two readings names an existing instruction.
      assert Assembler.assemble([{:inc, :c}]) == <<0x0C>>
      assert Assembler.assemble([{:ret, :c}]) == <<0xD8>>
      assert Assembler.assemble([{:ret}]) == <<0xC9>>
      assert Assembler.assemble([{:jr, :c, 2}]) == <<0x38, 0x02>>
      assert Assembler.assemble([{:add, :a, :c}]) == <<0x81>>
      assert Assembler.assemble([{:ldh, :a, {:high, :c}}]) == <<0xF2>>
    end

    test "the width of an immediate is deduced from the table" do
      assert Assembler.assemble([{:ld, :a, 0x42}]) == <<0x3E, 0x42>>
      assert Assembler.assemble([{:ld, :hl, 0xC000}]) == <<0x21, 0x00, 0xC0>>
      assert Assembler.assemble([{:jp, 0xC000}]) == <<0xC3, 0x00, 0xC0>>
      assert Assembler.assemble([{:jr, 0x10}]) == <<0x18, 0x10>>
    end

    test "an integer also serves as an RST target or a bit number" do
      assert Assembler.assemble([{:rst, 0x00}]) == <<0xC7>>
      assert Assembler.assemble([{:rst, 0x38}]) == <<0xFF>>
      assert Assembler.assemble([{:bit, 7, {:mem, :hl}}]) == <<0xCB, 0x7E>>
      assert Assembler.assemble([{:res, 0, :a}]) == <<0xCB, 0x87>>
      assert Assembler.assemble([{:set, 3, :b}]) == <<0xCB, 0xD8>>
    end

    test "the signed immediates of JR and ADD SP go through two's complement" do
      assert Assembler.assemble([{:jr, -2}]) == <<0x18, 0xFE>>
      assert Assembler.assemble([{:add_sp, :sp, -2}]) == <<0xE8, 0xFE>>
      assert Assembler.assemble([{:add_sp, :hl, 8}]) == <<0xF8, 0x08>>
      assert Assembler.assemble([{:add_sp, :sp, -128}]) == <<0xE8, 0x80>>
      assert Assembler.assemble([{:add_sp, :sp, 127}]) == <<0xE8, 0x7F>>
    end
  end

  describe "the labels" do
    test "a backward JR counts a negative gap" do
      # NOP at 0x0150, JR at 0x0151: PC is 0x0153 when the gap applies, the
      # target is 0x0150, hence -3.
      program = [{:label, :main_loop}, {:nop}, {:jr, {:label, :main_loop}}]

      assert Assembler.assemble(program) == <<0x00, 0x18, 0xFD>>
    end

    test "a forward JR counts a positive gap" do
      program = [{:jr, {:label, :done}}, {:nop}, {:nop}, {:label, :done}, {:halt}]

      assert Assembler.assemble(program) == <<0x18, 0x02, 0x00, 0x00, 0x76>>
    end

    test "a conditional JR aims at the same address" do
      program = [{:label, :main_loop}, {:jr, :nz, {:label, :main_loop}}]

      assert Assembler.assemble(program) == <<0x20, 0xFE>>
    end

    test "the two exact bounds of a JR's range" do
      # +127: the label is 127 bytes from the address following the JR.
      forward = [{:jr, {:label, :far}}, {:bytes, padding(127)}, {:label, :far}]
      assert <<0x18, 0x7F, _::binary>> = Assembler.assemble(forward)

      # -128: the JR is 126 bytes from the label, plus its own two.
      backward = [{:label, :far}, {:bytes, padding(126)}, {:jr, {:label, :far}}]
      assert <<_::binary-size(126), 0x18, 0x80>> = Assembler.assemble(backward)
    end

    test "a JR out of range names the gap and both addresses" do
      program = [{:jr, {:label, :far}}, {:bytes, padding(128)}, {:label, :far}]

      error = assert_raise ArgumentError, fn -> Assembler.assemble(program) end

      assert error.message =~ "relative jump out of range"
      assert error.message =~ "The gap is 128 bytes"
      assert error.message =~ "0x0152"
      assert error.message =~ "0x01D2"
      assert error.message =~ ":far"
    end

    test "JP and CALL take the absolute address" do
      program = [
        {:label, :start},
        {:jp, {:label, :start}},
        {:call, {:label, :start}},
        {:call, :nz, {:label, :start}}
      ]

      assert Assembler.assemble(program) ==
               <<0xC3, 0x50, 0x01, 0xCD, 0x50, 0x01, 0xC4, 0x50, 0x01>>
    end

    test "a label also serves as a memory address" do
      program = [
        {:ld, :a, {:mem, {:label, :data}}},
        {:label, :data},
        {:bytes, <<0x42>>}
      ]

      assert Assembler.assemble(program) == <<0xFA, 0x53, 0x01, 0x42>>
    end

    test "a label in the high page is written with LDH" do
      program = [
        {:ldh, {:high, {:label, :bgp}}, :a},
        {:bytes, padding(0xFF47 - 0x0152)},
        {:label, :bgp}
      ]

      assert <<0xE0, 0x47, _::binary>> = Assembler.assemble(program)
    end

    test "a label outside the high page is refused by LDH" do
      program = [{:ldh, {:high, {:label, :here}}, :a}, {:label, :here}]

      error = assert_raise ArgumentError, fn -> Assembler.assemble(program) end

      assert error.message =~ "outside the high page"
      assert error.message =~ "0x0152"
    end

    test "an unknown label lists the ones that exist" do
      program = [{:label, :here}, {:jp, {:label, :elsewhere}}]

      error = assert_raise ArgumentError, fn -> Assembler.assemble(program) end

      assert error.message =~ "unknown label: :elsewhere"
      assert error.message =~ "defined: :here"
    end

    test "a duplicate label gives both addresses" do
      program = [{:label, :here}, {:nop}, {:label, :here}]

      error = assert_raise ArgumentError, fn -> Assembler.assemble(program) end

      assert error.message =~ "duplicate label: :here"
      assert error.message =~ "0x0150"
      assert error.message =~ "0x0151"
    end

    test "addresses/2 returns the map without emitting the bytes" do
      program = [{:bytes, <<1, 2, 3>>}, {:label, :here}, {:nop}, {:label, :after}]

      assert Assembler.addresses(program, origin: 0x4000) == %{here: 0x4003, after: 0x4004}
    end
  end

  describe "raw bytes and origin" do
    test "raw bytes are inserted as they are" do
      program = [{:nop}, {:bytes, <<0xDE, 0xAD>>}, {:nop}, {:bytes, <<>>}]

      assert Assembler.assemble(program) == <<0x00, 0xDE, 0xAD, 0x00>>
    end

    test "the origin shifts every resolved address" do
      program = [{:label, :here}, {:jp, {:label, :here}}]

      assert Assembler.assemble(program, origin: 0x0000) == <<0xC3, 0x00, 0x00>>
      assert Assembler.assemble(program, origin: 0x0150) == <<0xC3, 0x50, 0x01>>
      assert Assembler.assemble(program, origin: 0x4000) == <<0xC3, 0x00, 0x40>>
    end

    test "the origin does not change a relative gap" do
      program = [{:label, :main_loop}, {:jr, {:label, :main_loop}}]

      assert Assembler.assemble(program, origin: 0x0000) ==
               Assembler.assemble(program, origin: 0x7FF0)
    end

    test "an empty program gives an empty binary" do
      assert Assembler.assemble([]) == <<>>
      assert Assembler.assemble([{:label, :lonely}]) == <<>>
    end
  end

  describe "the refusals" do
    test "an out-of-range immediate names the value and the expected range" do
      error = assert_raise ArgumentError, fn -> Assembler.assemble([{:ld, :a, 0x100}]) end

      assert error.message =~ "immediate out of range"
      assert error.message =~ "256 does not fit in a byte"
      assert error.message =~ "0..255"
    end

    test "the bounds of the unsigned immediates" do
      assert Assembler.assemble([{:ld, :a, 0xFF}]) == <<0x3E, 0xFF>>
      assert Assembler.assemble([{:ld, :bc, 0xFFFF}]) == <<0x01, 0xFF, 0xFF>>
      assert_raise ArgumentError, fn -> Assembler.assemble([{:ld, :a, -1}]) end
      assert_raise ArgumentError, fn -> Assembler.assemble([{:ld, :bc, 0x10000}]) end
      assert_raise ArgumentError, fn -> Assembler.assemble([{:ld, {:mem, 0x10000}, :a}]) end
    end

    test "a signed displacement outside -128..127" do
      assert_raise ArgumentError, fn -> Assembler.assemble([{:add_sp, :sp, -129}]) end
      assert_raise ArgumentError, fn -> Assembler.assemble([{:jr, -129}]) end
    end

    test "an unknown instruction shows the forms that exist" do
      error = assert_raise ArgumentError, fn -> Assembler.assemble([{:ld, :a, :bc}]) end

      assert error.message =~ "unknown instruction"
      assert error.message =~ "{:ld, :a, :bc}"
      assert error.message =~ "element #0"
      # The suggested forms come from `Insn.label/1` — the same name the
      # dashboard displays.
      assert error.message =~ "LD A, (BC)"
    end

    test "a neighbouring mnemonic is suggested" do
      error = assert_raise ArgumentError, fn -> Assembler.assemble([{:lb, :a, 1}]) end

      assert error.message =~ "unknown mnemonic"
      assert error.message =~ "Did you mean :ld"
    end

    test "an operand with no shape is named explicitly" do
      error = assert_raise ArgumentError, fn -> Assembler.assemble([{:ld, :a, {:mem, :sp}}]) end

      assert error.message =~ "operand of unknown shape"
      assert error.message =~ "{:mem, :sp}"
    end

    test "a label does not slip into an 8-bit immediate" do
      program = [{:ld, :a, {:label, :here}}, {:label, :here}]

      error = assert_raise ArgumentError, fn -> Assembler.assemble(program) end

      assert error.message =~ "label where LD expects a byte"
    end

    test "the offending element is located by its index and its address" do
      program = [{:nop}, {:nop}, {:ld, :a, 0x100}]

      error = assert_raise ArgumentError, fn -> Assembler.assemble(program) end

      assert error.message =~ "element #2 (0x0152)"
    end

    test "an element that is neither a label, nor bytes, nor an instruction" do
      assert_raise ArgumentError, fn -> Assembler.assemble([:nop]) end
      assert_raise ArgumentError, fn -> Assembler.assemble([{:bytes, ~c"abc"}]) end
      assert_raise ArgumentError, fn -> Assembler.assemble([{:label, "here"}]) end
    end
  end

  describe "execution on the oracle" do
    test "an addition and a store to memory" do
      program = [
        {:ld, :a, 5},
        {:ld, :b, 3},
        {:add, :a, :b},
        {:ld, {:mem, 0xC000}, :a},
        {:label, :done},
        {:jr, {:label, :done}}
      ]

      {state, mem} = run(program, 20)

      assert state.a == 8
      assert Flat.read8(mem, 0xC000) == 8
      # The JR onto itself: PC has come back to the instruction, the ROM does
      # not spill into what follows.
      assert state.pc == 0x0150 + 8
    end

    test "a conditional loop multiplies by adding" do
      # 3 × 5, decrementing C until Z drops. The JR NZ jumps backwards to a
      # label: it is the first program whose meaning depends on an address only
      # the assembler knows.
      program = [
        {:ld, :a, 0},
        {:ld, :b, 3},
        {:ld, :c, 5},
        {:label, :main_loop},
        {:add, :a, :b},
        {:dec, :c},
        {:jr, :nz, {:label, :main_loop}},
        {:ld, {:mem, 0xC000}, :a},
        {:label, :done},
        {:jr, {:label, :done}}
      ]

      {state, mem} = run(program, 200)

      assert state.a == 15
      assert state.c == 0
      assert Flat.read8(mem, 0xC000) == 15
    end

    test "a CALL, a RET, and data read through a label" do
      program = [
        {:ld, :sp, 0xDFFF},
        {:call, {:label, :fetch}},
        {:ld, {:mem, 0xC000}, :a},
        {:label, :done},
        {:jr, {:label, :done}},
        {:label, :fetch},
        {:ld, :a, {:mem, {:label, :data}}},
        {:ret},
        {:label, :data},
        {:bytes, <<0x5A>>}
      ]

      {state, mem} = run(program, 50)

      assert state.a == 0x5A
      assert Flat.read8(mem, 0xC000) == 0x5A
      # SP is back to its pre-call value: the RET did pop.
      assert state.sp == 0xDFFF
    end
  end

  # ── Rebuilding a source from the table ───────────────────────────────────────

  defp source(%Insn{} = insn) do
    operands = Enum.map(insn.operands, &source_operand/1)
    arguments = if insn.condition, do: [insn.condition | operands], else: operands

    List.to_tuple([insn.mnemonic | arguments])
  end

  defp source_operand({:reg, register}), do: register
  defp source_operand({:pair, pair}), do: pair
  defp source_operand(:hl_ind), do: {:mem, :hl}
  defp source_operand({:ind, target}), do: {:mem, target}
  defp source_operand(:a16_ind), do: {:mem, @d16}
  defp source_operand(:a8_ind), do: {:high, @d8}
  defp source_operand(:c_ind), do: {:high, :c}
  defp source_operand({:imm, 8}), do: @d8
  defp source_operand({:imm, 16}), do: @d16
  defp source_operand({:rst, target}), do: target
  defp source_operand({:bit, number}), do: number

  defp expected(%Insn{} = insn) do
    prefix = if insn.prefix == :cb, do: <<0xCB>>, else: <<>>
    immediates = insn.operands |> Enum.map(&expected_bytes/1) |> IO.iodata_to_binary()

    prefix <> <<insn.opcode>> <> immediates
  end

  defp expected_bytes({:imm, 8}), do: <<@d8>>
  defp expected_bytes(:a8_ind), do: <<@d8>>
  defp expected_bytes({:imm, 16}), do: <<@d16::16-little>>
  defp expected_bytes(:a16_ind), do: <<@d16::16-little>>
  defp expected_bytes(_encoded_in_the_opcode), do: <<>>

  # ── The execution harness ────────────────────────────────────────────────────

  defp padding(n), do: :binary.copy(<<0x00>>, n)

  # The assembled ROM, laid at its origin in a flat memory, executed step by step
  # by the oracle — the same `Atomboy.CPU.step/2` that the SingleStepTests
  # vectors validate.
  defp run(program, steps, origin \\ 0x0150) do
    bytes = Assembler.assemble(program, origin: origin)

    mem =
      Flat.new(
        for {byte, offset} <- Enum.with_index(:binary.bin_to_list(bytes)),
            do: {origin + offset, byte}
      )

    Enum.reduce(1..steps, {%State{pc: origin}, mem}, fn _, {state, mem} ->
      {state, mem, _cycles} = Atomboy.CPU.step(state, mem)
      {state, mem}
    end)
  end
end
