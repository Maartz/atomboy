defmodule Atomboy.APUTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Atomboy.APU

  # Une frame de canal 2 (pas de sweep), registres posés puis déclenchés.
  defp pulse2(regs) do
    ram =
      Map.merge(
        %{0xFF26 => 0x80, 0xFF24 => 0x77, 0xFF25 => 0xFF, :apu_triggers => [2]},
        regs
      )

    APU.frame(ram, %APU{})
  end

  defp left_samples(bin), do: for(<<l::16-little-signed, _r::16-little-signed <- bin>>, do: l)

  # Le nombre de fronts d'une onde carrée — deux par période.
  defp edges(samples) do
    samples
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.count(fn [a, b] -> a != b end)
  end

  test "la fréquence des registres devient celle de l'onde" do
    # freq 11 bits x : f = 131072 / (2048 - x). x = 1792 → 512 Hz.
    {bin, _ram, _apu} =
      pulse2(%{0xFF16 => 0x80, 0xFF17 => 0xF0, 0xFF18 => 1792 &&& 0xFF, 0xFF19 => bsr(1792, 8)})

    samples = left_samples(bin)
    assert length(samples) in 548..550

    # 512 Hz sur 1/59,7 s : ~8,6 périodes, ~17 fronts.
    assert edges(samples) in 15..19
  end

  test "le rapport cyclique 12,5 % laisse l'onde haute un huitième du temps" do
    {bin, _ram, _apu} =
      pulse2(%{0xFF16 => 0x00, 0xFF17 => 0xF0, 0xFF18 => 0x00, 0xFF19 => 0x04})

    samples = left_samples(bin)
    high = Enum.count(samples, &(&1 > 0))
    ratio = high / length(samples)
    assert ratio > 0.05 and ratio < 0.20
  end

  test "l'enveloppe décroissante fait baisser le volume au fil des frames" do
    regs = %{0xFF16 => 0x80, 0xFF17 => 0xF1, 0xFF18 => 0x00, 0xFF19 => 0x07}
    {bin1, ram, apu} = pulse2(regs)

    {_bin, _ram, apu} =
      Enum.reduce(1..8, {bin1, Map.delete(ram, :apu_triggers), apu}, fn _, {_b, ram, apu} ->
        APU.frame(ram, apu)
      end)

    # Période 1 à 64 Hz : après ~9 frames, le volume initial 15 a fondu.
    assert apu.ch2.volume < 8
    assert Enum.max(left_samples(bin1)) > 0
  end

  test "le compteur de longueur éteint le canal" do
    # Longueur chargée à 63 → 1 pas restant, longueur armée (bit 6 de NR24).
    regs = %{0xFF16 => 0x3F, 0xFF17 => 0xF0, 0xFF18 => 0x00, 0xFF19 => 0x47}
    {_bin, ram, apu} = pulse2(regs)
    {bin2, _ram, apu} = APU.frame(Map.delete(ram, :apu_triggers), apu)

    refute apu.ch2.enabled
    assert Enum.all?(left_samples(bin2), &(&1 == 0))
  end

  test "le DAC éteint rend le canal muet, trigger ou pas" do
    {bin, _ram, _apu} =
      pulse2(%{0xFF16 => 0x80, 0xFF17 => 0x00, 0xFF18 => 0x00, 0xFF19 => 0x07})

    assert Enum.all?(left_samples(bin), &(&1 == 0))
  end

  test "NR51 aiguille le canal par oreille" do
    # Canal 2 à droite seulement (bit 1).
    {bin, _ram, _apu} =
      pulse2(%{
        0xFF16 => 0x80,
        0xFF17 => 0xF0,
        0xFF18 => 0x00,
        0xFF19 => 0x07,
        0xFF25 => 0x02
      })

    lefts = left_samples(bin)
    rights = for <<_l::16-little-signed, r::16-little-signed <- bin>>, do: r
    assert Enum.all?(lefts, &(&1 == 0))
    assert Enum.max(rights) > 0
  end

  test "l'APU hors tension produit du silence calibré" do
    {bin, _ram, _apu} = pulse2(%{0xFF26 => 0x00, 0xFF17 => 0xF0})
    assert div(byte_size(bin), 4) in 548..549
    assert bin == :binary.copy(<<0, 0, 0, 0>>, div(byte_size(bin), 4))
  end

  test "CartLoop capture le déclenchement à l'écriture de NRx4" do
    alias Atomboy.CPU.CartLoop
    # LD A, 0x87 ; LDH (0x19), A — déclenche le canal 2.
    rom = <<0x3E, 0x87, 0xE0, 0x19>> <> :binary.copy(<<0>>, 0x8000 - 4)
    state = %Atomboy.CPU.State{pc: 0}
    {_state, ram, _cycles} = CartLoop.run(state, rom, %{}, 24)

    assert Map.get(ram, :apu_triggers) == [2]
    assert Map.get(ram, 0xFF19) == 0x87
  end
end
