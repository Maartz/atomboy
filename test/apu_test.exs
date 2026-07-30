defmodule Atomboy.APUTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Atomboy.APU

  # One frame of channel 2 (no sweep), registers laid down then triggered.
  defp pulse2(regs) do
    ram =
      Map.merge(
        %{0xFF26 => 0x80, 0xFF24 => 0x77, 0xFF25 => 0xFF, :apu_triggers => [2]},
        regs
      )

    APU.frame(ram, %APU{})
  end

  defp left_samples(bin), do: for(<<l::16-little-signed, _r::16-little-signed <- bin>>, do: l)

  # The number of edges in a square wave — two per period.
  defp edges(samples) do
    samples
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.count(fn [a, b] -> a != b end)
  end

  test "the frequency in the registers becomes the wave's" do
    # 11-bit freq x: f = 131072 / (2048 - x). x = 1792 → 512 Hz.
    {bin, _ram, _apu} =
      pulse2(%{0xFF16 => 0x80, 0xFF17 => 0xF0, 0xFF18 => 1792 &&& 0xFF, 0xFF19 => bsr(1792, 8)})

    samples = left_samples(bin)
    assert length(samples) in 548..550

    # 512 Hz over 1/59.7 s: ~8.6 periods, ~17 edges.
    assert edges(samples) in 15..19
  end

  test "a 12.5% duty cycle leaves the wave high one eighth of the time" do
    {bin, _ram, _apu} =
      pulse2(%{0xFF16 => 0x00, 0xFF17 => 0xF0, 0xFF18 => 0x00, 0xFF19 => 0x04})

    samples = left_samples(bin)
    high = Enum.count(samples, &(&1 > 0))
    ratio = high / length(samples)
    assert ratio > 0.05 and ratio < 0.20
  end

  test "a decreasing envelope brings the volume down frame after frame" do
    regs = %{0xFF16 => 0x80, 0xFF17 => 0xF1, 0xFF18 => 0x00, 0xFF19 => 0x07}
    {bin1, ram, apu} = pulse2(regs)

    {_bin, _ram, apu} =
      Enum.reduce(1..8, {bin1, Map.delete(ram, :apu_triggers), apu}, fn _, {_b, ram, apu} ->
        APU.frame(ram, apu)
      end)

    # Period 1 at 64 Hz: after ~9 frames, the initial volume of 15 has melted.
    assert apu.ch2.volume < 8
    assert Enum.max(left_samples(bin1)) > 0
  end

  test "the length counter switches the channel off" do
    # Length loaded at 63 → 1 step left, length armed (bit 6 of NR24).
    regs = %{0xFF16 => 0x3F, 0xFF17 => 0xF0, 0xFF18 => 0x00, 0xFF19 => 0x47}
    {_bin, ram, apu} = pulse2(regs)
    {bin2, _ram, apu} = APU.frame(Map.delete(ram, :apu_triggers), apu)

    refute apu.ch2.enabled
    assert Enum.all?(left_samples(bin2), &(&1 == 0))
  end

  test "a DAC that is off makes the channel mute, trigger or not" do
    {bin, _ram, _apu} =
      pulse2(%{0xFF16 => 0x80, 0xFF17 => 0x00, 0xFF18 => 0x00, 0xFF19 => 0x07})

    assert Enum.all?(left_samples(bin), &(&1 == 0))
  end

  test "NR51 routes the channel per ear" do
    # Channel 2 on the right only (bit 1).
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

  test "an APU with the power off produces calibrated silence" do
    {bin, _ram, _apu} = pulse2(%{0xFF26 => 0x00, 0xFF17 => 0xF0})
    assert div(byte_size(bin), 4) in 548..549
    assert bin == :binary.copy(<<0, 0, 0, 0>>, div(byte_size(bin), 4))
  end

  # One frame of channel 3 (wave): square table E/0 — an even nibble, so that
  # 50% volume (an integer shift) divides exactly — DAC on.
  defp wave3(regs) do
    table = for addr <- 0xFF30..0xFF37, into: %{}, do: {addr, 0xEE}
    table = for addr <- 0xFF38..0xFF3F, into: table, do: {addr, 0x00}

    ram =
      %{0xFF26 => 0x80, 0xFF24 => 0x77, 0xFF25 => 0xFF, 0xFF1A => 0x80, :apu_triggers => [3]}
      |> Map.merge(table)
      |> Map.merge(regs)

    APU.frame(ram, %APU{})
  end

  test "the wave channel replays its table at the registers' frequency" do
    # One table cycle = (2048-f)×64 cycles: f = 1792 → 256 Hz.
    {bin, _ram, _apu} =
      wave3(%{0xFF1C => 0x20, 0xFF1D => 1792 &&& 0xFF, 0xFF1E => bsr(1792, 8)})

    samples = left_samples(bin)
    assert Enum.max(samples) > 0
    # 256 Hz over one frame: ~4.3 periods, ~9 edges.
    assert edges(samples) in 7..11
  end

  test "wave volume at 50% halves the amplitude" do
    regs = %{0xFF1D => 0x00, 0xFF1E => 0x04}
    {full, _, _} = wave3(Map.put(regs, 0xFF1C, 0x20))
    {half, _, _} = wave3(Map.put(regs, 0xFF1C, 0x40))

    assert Enum.max(left_samples(half)) * 2 == Enum.max(left_samples(full))
  end

  test "a wave DAC that is off makes the channel mute" do
    {bin, _ram, _apu} = wave3(%{0xFF1A => 0x00, 0xFF1C => 0x20, 0xFF1E => 0x04})
    assert Enum.all?(left_samples(bin), &(&1 == 0))
  end

  test "the noise channel spits out pseudo-randomness" do
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
    # Noise: plenty of edges, with no clear period.
    assert edges(samples) > 50
  end

  test "the noise envelope fades out like the pulses' one" do
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

  test "CartLoop captures the trigger when NRx4 is written" do
    alias Atomboy.CPU.CartLoop
    # LD A, 0x87 ; LDH (0x19), A — triggers channel 2.
    rom = <<0x3E, 0x87, 0xE0, 0x19>> <> :binary.copy(<<0>>, 0x8000 - 4)
    state = %Atomboy.CPU.State{pc: 0}
    {_state, ram, _cycles} = CartLoop.run(state, rom, %{}, 24)

    assert Map.get(ram, :apu_triggers) == [2]
    assert Map.get(ram, 0xFF19) == 0x87
  end

  # ── The emulator's mixer (ram[:mixer], set by the menu) ─────────────────────

  @audible %{0xFF16 => 0x80, 0xFF17 => 0xF0, 0xFF18 => 0x00, 0xFF19 => 0x04}

  test "the master volume scales the amplitude — 0 makes silence" do
    {full, _, _} = pulse2(@audible)

    {half, _, _} =
      pulse2(Map.put(@audible, :mixer, %{volume: 50, voices: {true, true, true, true}}))

    {mute, _, _} =
      pulse2(Map.put(@audible, :mixer, %{volume: 0, voices: {true, true, true, true}}))

    max_full = Enum.max(left_samples(full))
    max_half = Enum.max(left_samples(half))

    assert max_full > 0
    assert_in_delta max_half / max_full, 0.5, 0.05
    assert Enum.all?(left_samples(mute), &(&1 == 0))
  end

  test "muting a voice takes it out of the mix, the others stay" do
    {mute, _, _} =
      pulse2(Map.put(@audible, :mixer, %{volume: 100, voices: {true, false, true, true}}))

    {intact, _, _} =
      pulse2(Map.put(@audible, :mixer, %{volume: 100, voices: {false, true, false, false}}))

    assert Enum.all?(left_samples(mute), &(&1 == 0))
    assert Enum.max(left_samples(intact)) > 0
  end
end
