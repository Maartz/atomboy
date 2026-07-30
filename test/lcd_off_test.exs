defmodule Atomboy.LcdOffTest do
  @moduledoc """
  Screen off: the PPU stops, not just the display.

  This rule cost a long hunt — an illegal opcode in Pokémon, seconds away
  from its cause. Games turn the LCD off to reload VRAM (Pokémon on every
  map change) and keep calling their sound engine from the main loop, with
  interrupts open. A phantom vblank re-enters that engine on top of itself,
  and the corruption travels all the way to a jump into dialogue text.
  """

  use ExUnit.Case, async: true

  import Bitwise

  alias Atomboy.CPU.State
  alias Atomboy.Screen

  # A ROM that only spins in place: the simulated hardware alone acts.
  defp rom do
    code = <<0x18, 0xFE>>
    :binary.copy(<<0>>, 0x100) <> code <> :binary.copy(<<0>>, 0x8000 - 0x100 - byte_size(code))
  end

  defp run_lines(ram) do
    Enum.reduce(0..153, {%State{pc: 0x100}, ram}, fn ly, {state, ram} ->
      Screen.step_line(state, rom(), ram, ly)
    end)
  end

  test "screen on: vblank rises at line 144" do
    {_state, ram} = run_lines(%{0xFF40 => 0x91})
    assert (Map.get(ram, 0xFF0F, 0) &&& 0x01) == 0x01
  end

  test "screen off: no vblank, LY stays at zero" do
    {_state, ram} = run_lines(%{0xFF40 => 0x11})

    assert (Map.get(ram, 0xFF0F, 0) &&& 0x01) == 0
    assert Map.get(ram, 0xFF44) == 0
  end

  test "screen off: the LY=LYC coincidence fires nothing" do
    # STAT bit 6 armed, LYC = 0 — with the screen on the coincidence would fire.
    ram = %{0xFF40 => 0x11, 0xFF41 => 0x40, 0xFF45 => 0x00}
    {_state, ram} = run_lines(ram)

    assert (Map.get(ram, 0xFF0F, 0) &&& 0x02) == 0
    assert (Map.get(ram, 0xFF41, 0) &&& 0x04) == 0
  end

  test "screen turned back on: vblank resumes" do
    {_state, ram} = run_lines(%{0xFF40 => 0x11})
    {_state, ram} = run_lines(Map.put(ram, 0xFF40, 0x91))

    assert (Map.get(ram, 0xFF0F, 0) &&& 0x01) == 0x01
  end
end
