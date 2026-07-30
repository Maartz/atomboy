defmodule Atomboy.JoypadTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Atomboy.Joypad

  # bit 4 at 0: directions row; bit 5 at 0: buttons row.
  @select_dpad 0x20
  @select_btns 0x10
  @select_none 0x30

  test "with no key pressed, the lines read all released" do
    ram = Joypad.write(%{}, @select_dpad)
    assert Map.fetch!(ram, 0xFF00) == 0xEF

    ram = Joypad.write(%{}, @select_btns)
    assert Map.fetch!(ram, 0xFF00) == 0xDF
  end

  test "a pressed direction pulls its line when the row is selected" do
    # Right = bit 0 of :joy_dpad.
    ram = %{} |> Joypad.write(@select_dpad) |> Joypad.set(0x0E, 0x0F)
    assert (Map.fetch!(ram, 0xFF00) &&& 0x0F) == 0x0E
  end

  test "the unselected row stays silent" do
    # A pressed (buttons), but the game reads the directions: nothing.
    ram = %{} |> Joypad.write(@select_dpad) |> Joypad.set(0x0F, 0x0E)
    assert (Map.fetch!(ram, 0xFF00) &&& 0x0F) == 0x0F
  end

  test "changing the selection re-reads the lines already laid down" do
    # Start pressed, selection on directions then flipped to buttons.
    ram = %{} |> Joypad.write(@select_dpad) |> Joypad.set(0x0F, 0x07)
    ram = Joypad.write(ram, @select_btns)
    assert (Map.fetch!(ram, 0xFF00) &&& 0x0F) == 0x07
  end

  test "both rows selected combine with an AND" do
    ram = %{} |> Joypad.write(0x00) |> Joypad.set(0x0E, 0x07)
    assert (Map.fetch!(ram, 0xFF00) &&& 0x0F) == 0x06
  end

  test "no row selected: all released, whatever is pressed" do
    ram = %{} |> Joypad.write(@select_none) |> Joypad.set(0x00, 0x00)
    assert (Map.fetch!(ram, 0xFF00) &&& 0x0F) == 0x0F
  end

  test "a freshly pressed key raises the joypad interrupt" do
    ram = Joypad.set(%{}, 0x0F, 0x0E)
    assert (Map.fetch!(ram, 0xFF0F) &&& 0x10) == 0x10
  end

  test "holding or releasing raises nothing" do
    ram = %{} |> Joypad.set(0x0F, 0x0E) |> Map.put(0xFF0F, 0)

    ram = Joypad.set(ram, 0x0F, 0x0E)
    assert Map.fetch!(ram, 0xFF0F) == 0

    ram = Joypad.set(ram, 0x0F, 0x0F)
    assert Map.fetch!(ram, 0xFF0F) == 0
  end

  test "the high bits read 1, as on the bus" do
    ram = Joypad.write(%{}, 0xFF)
    assert (Map.fetch!(ram, 0xFF00) &&& 0xC0) == 0xC0
  end
end
