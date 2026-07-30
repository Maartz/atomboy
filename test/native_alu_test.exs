defmodule Atomboy.NativeALUTest do
  @moduledoc """
  Flag arithmetic, on both sides, over the whole input space.

  One test carries the essential: it runs the bench and demands zero
  divergence. This is not an example test in disguise -- 892,928 cases, nearly
  1.8 million values compared: all of `ADD`, `SUB`, `CP`, `AND`, `XOR`, `OR`
  over their 65536 pairs, `ADC` and `SBC` over the same pairs in both carry
  states, and the whole of `DAA`, the rotations and the `BIT n`.

  The rest of the file checks the bench itself is not hollow: that it covers
  what `Atomboy.CPU.ALU` exposes, and that it sweeps the number of cases it
  claims.
  """

  use ExUnit.Case, async: true

  alias Atomboy.Native.ALU
  alias Atomboy.Native.Bench

  @moduletag :qemu
  @moduletag timeout: 300_000

  describe "the differential bench" do
    test "no divergence between the native ALU and the Elixir oracle" do
      assert {:ok, divergences} = Bench.run()

      assert divergences == [], """
      #{length(divergences)} divergence(s) entre Atomboy.Native.ALU et Atomboy.CPU.ALU :

      #{Enum.map_join(Enum.take(divergences, 8), "\n", &format/1)}
      """
    end
  end

  describe "the bench itself" do
    test "it sweeps the announced space, with no sweep trimmed" do
      total = Enum.sum(Enum.map(Bench.sweeps(), & &1.cases))

      assert total == 892_928,
             "the bench covers #{total} cases instead of 892928 -- a sweep changed size"
    end

    test "il couvre toutes les fonctions publiques de l'ALU de l'oracle" do
      # `bit_test` is covered by the eight `bit_n` sweeps, whose bit
      # bit est cuit dans la routine native.
      exported =
        Atomboy.CPU.ALU.__info__(:functions)
        |> Enum.map(&elem(&1, 0))
        |> MapSet.new()
        |> MapSet.delete(:bit_test)

      swept = MapSet.new(Bench.sweeps(), & &1.name)

      missing = MapSet.difference(exported, swept)

      assert MapSet.size(missing) == 0,
             "not swept: #{inspect(MapSet.to_list(missing))}"

      assert Enum.any?(Bench.sweeps(), &(&1[:bit] == 3)), "the BIT n are swept"
    end

    test "ADC and SBC are swept in both carry states" do
      for name <- [:adc, :sbc] do
        flags = for b <- Bench.sweeps(), b.name == name, do: b.f
        assert Enum.sort(flags) == [0x00, 0xF0], "#{name}: #{inspect(flags)}"
      end
    end

    test "the mixes producing the 16-bit operands stay in range" do
      for i <- [0, 1, 0x1234, 0xFFFF] do
        assert Bench.mix16(i) in 0..0xFFFF
        assert Bench.mix8(i) in 0..0xFF
      end

      # A constant mix would cover nothing: we demand spread.
      values = for i <- 0..999, do: Bench.mix16(i)
      assert length(Enum.uniq(values)) > 900
    end
  end

  describe "labels" do
    test "every sweep targets a routine that is actually emitted" do
      image = Bench.image()

      for sweep <- Bench.sweeps() do
        label = Bench.label(sweep)

        assert Map.has_key?(image.labels, label),
               "sweep #{sweep.name} targets #{label}, which is not emitted"
      end
    end

    test "the naming follows the oracle's" do
      assert ALU.label(:add) == :alu_add
      assert ALU.label(:bit_and) == :alu_bit_and
      assert ALU.bit_label(7) == :alu_bit_7
    end
  end

  defp format(%{sweep: name, case_index: index, inputs: inputs, got: got, expected: expected}) do
    "  #{name} case #{index} #{inspect(inputs)}: got #{flag_string(got)}, expected #{flag_string(expected)}"
  end

  # Flags spelled out: `f: 176` teaches nothing, `Z-HC` reads.
  defp flag_string({value, f}) do
    "#{value}/#{Atomboy.CPU.State.flag_string(%Atomboy.CPU.State{f: f})}"
  end
end
