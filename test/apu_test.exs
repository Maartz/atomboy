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

  # Une frame de canal 3 (wave) : table carrée E/0 — quartet pair, pour que
  # le volume 50 % (décalage entier) divise exactement — DAC allumé.
  defp wave3(regs) do
    table = for addr <- 0xFF30..0xFF37, into: %{}, do: {addr, 0xEE}
    table = for addr <- 0xFF38..0xFF3F, into: table, do: {addr, 0x00}

    ram =
      %{0xFF26 => 0x80, 0xFF24 => 0x77, 0xFF25 => 0xFF, 0xFF1A => 0x80, :apu_triggers => [3]}
      |> Map.merge(table)
      |> Map.merge(regs)

    APU.frame(ram, %APU{})
  end

  test "le canal wave rejoue sa table à la fréquence des registres" do
    # Un cycle de table = (2048-f)×64 cycles : f = 1792 → 256 Hz.
    {bin, _ram, _apu} =
      wave3(%{0xFF1C => 0x20, 0xFF1D => 1792 &&& 0xFF, 0xFF1E => bsr(1792, 8)})

    samples = left_samples(bin)
    assert Enum.max(samples) > 0
    # 256 Hz sur une frame : ~4,3 périodes, ~9 fronts.
    assert edges(samples) in 7..11
  end

  test "le volume wave à 50 % divise l'amplitude par deux" do
    regs = %{0xFF1D => 0x00, 0xFF1E => 0x04}
    {plein, _, _} = wave3(Map.put(regs, 0xFF1C, 0x20))
    {moitie, _, _} = wave3(Map.put(regs, 0xFF1C, 0x40))

    assert Enum.max(left_samples(moitie)) * 2 == Enum.max(left_samples(plein))
  end

  test "le DAC wave éteint rend le canal muet" do
    {bin, _ram, _apu} = wave3(%{0xFF1A => 0x00, 0xFF1C => 0x20, 0xFF1E => 0x04})
    assert Enum.all?(left_samples(bin), &(&1 == 0))
  end

  test "le canal bruit crache du pseudo-aléatoire" do
    ram = %{
      0xFF26 => 0x80,
      0xFF24 => 0x77,
      0xFF25 => 0xFF,
      0xFF20 => 0x00,
      0xFF21 => 0xF0,
      0xFF22 => 0x23,
      :apu_triggers => [4]
    }

    {bin, _ram, _apu} = APU.frame(ram, %APU{})
    samples = left_samples(bin)

    assert Enum.max(samples) > 0
    # Du bruit : beaucoup de fronts, sans période nette.
    assert edges(samples) > 50
  end

  test "l'enveloppe du bruit s'éteint comme celle des pulses" do
    ram = %{
      0xFF26 => 0x80,
      0xFF24 => 0x77,
      0xFF25 => 0xFF,
      0xFF21 => 0x11,
      0xFF22 => 0x23,
      :apu_triggers => [4]
    }

    {_bin, ram, apu} = APU.frame(ram, %APU{})
    {_bin, _ram, apu} = APU.frame(Map.delete(ram, :apu_triggers), apu)
    assert apu.ch4.volume == 0
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

  # ── Le mixer de l'émulateur (ram[:mixer], posé par le menu) ────────────────

  @audible %{0xFF16 => 0x80, 0xFF17 => 0xF0, 0xFF18 => 0x00, 0xFF19 => 0x04}

  test "le volume maître module l'amplitude — 0 fait silence" do
    {plein, _, _} = pulse2(@audible)
    {moitié, _, _} = pulse2(Map.put(@audible, :mixer, %{volume: 50, voices: {true, true, true, true}}))
    {muet, _, _} = pulse2(Map.put(@audible, :mixer, %{volume: 0, voices: {true, true, true, true}}))

    max_plein = Enum.max(left_samples(plein))
    max_moitié = Enum.max(left_samples(moitié))

    assert max_plein > 0
    assert_in_delta max_moitié / max_plein, 0.5, 0.05
    assert Enum.all?(left_samples(muet), &(&1 == 0))
  end

  test "couper une voix la retire du mélange, les autres restent" do
    {muet, _, _} = pulse2(Map.put(@audible, :mixer, %{volume: 100, voices: {true, false, true, true}}))
    {intact, _, _} = pulse2(Map.put(@audible, :mixer, %{volume: 100, voices: {false, true, false, false}}))

    assert Enum.all?(left_samples(muet), &(&1 == 0))
    assert Enum.max(left_samples(intact)) > 0
  end
end
