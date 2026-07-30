defmodule Atomboy.NativeAsmTest do
  use ExUnit.Case, async: true

  alias Atomboy.Native.Asm
  alias Atomboy.Native.RV32

  describe "labels" do
    test "a backward reference targets the right distance" do
      %{code: code} =
        Asm.assemble([
          Asm.label(:loop),
          RV32.nop(),
          Asm.j(:loop)
        ])

      # The jump is at offset 4, the target at 0: a displacement of -4.
      assert code == RV32.nop() <> RV32.j(-4)
    end

    test "a forward reference is filled on the second pass" do
      %{code: code} =
        Asm.assemble([
          Asm.j(:done),
          RV32.nop(),
          RV32.nop(),
          Asm.label(:done),
          RV32.ret()
        ])

      assert code == RV32.j(12) <> RV32.nop() <> RV32.nop() <> RV32.ret()
    end

    test "a conditional branch targets a label like the rest" do
      %{code: code} = Asm.assemble([Asm.beqz(:a0, :next), RV32.nop(), Asm.label(:next)])
      assert code == RV32.beq(:a0, :zero, 8) <> RV32.nop()
    end

    test "an unknown label raises, naming the ones that exist" do
      assert_raise ArgumentError, ~r/unknown label: :absent.*present/s, fn ->
        Asm.assemble([Asm.label(:present), Asm.j(:absent)])
      end
    end

    test "a label defined twice raises" do
      assert_raise ArgumentError, ~r/twice/, fn ->
        Asm.assemble([Asm.label(:twice_over), Asm.label(:twice_over)])
      end
    end
  end

  describe "absolute addresses" do
    test "an {:addr, _} holds the load address plus the offset" do
      base = 0x8000_0000

      %{code: code} =
        Asm.assemble(
          [
            {:addr, :target},
            RV32.nop(),
            Asm.label(:target),
            RV32.ret()
          ],
          base
        )

      assert <<address::32-little, _::binary>> = code
      assert address == base + 8
    end

    test "address/3 returns the same address as the jump table" do
      base = 0x8000_0000
      image = Asm.assemble([RV32.nop(), Asm.label(:here), RV32.ret()], base)
      assert Asm.address(image, :here, base) == base + 4
    end
  end

  describe "alignment and reservations" do
    test "{:align, n} pads up to the multiple" do
      %{code: code, labels: labels} =
        Asm.assemble([<<1, 2, 3>>, {:align, 4}, Asm.label(:aligned), <<0xFF>>])

      assert byte_size(code) == 5
      assert labels[:aligned] == 4
      assert code == <<1, 2, 3, 0, 0xFF>>
    end

    test "{:align, n} on an already-aligned position costs nothing" do
      %{code: code} = Asm.assemble([RV32.nop(), {:align, 4}, RV32.ret()])
      assert byte_size(code) == 8
    end

    test "{:space, n} reserves zero bytes" do
      %{code: code, labels: labels} = Asm.assemble([{:space, 6}, Asm.label(:after)])
      assert code == <<0, 0, 0, 0, 0, 0>>
      assert labels[:after] == 6
    end
  end

  describe "the two-pass invariant" do
    test "the announced size is the one emitted" do
      # A mix of every item kind, whose total size is known:
      # 4 + 4 + 4 + 3 + 1 (alignement) + 4 + 8 = 28.
      %{code: code, size: size} =
        Asm.assemble([
          RV32.nop(),
          Asm.j(:done),
          {:addr, :done},
          <<1, 2, 3>>,
          {:align, 4},
          Asm.label(:done),
          RV32.ret(),
          {:space, 8}
        ])

      assert size == 28
      assert byte_size(code) == size
    end

    test "an unknown item raises rather than being ignored" do
      assert_raise ArgumentError, ~r/unknown assembly item/, fn ->
        Asm.assemble([RV32.nop(), :surprise])
      end
    end

    test "nested lists are flattened -- li produces them" do
      %{size: size} = Asm.assemble([RV32.li(:a0, 0x1234_5678), RV32.ret()])
      assert size == 12
    end
  end
end
