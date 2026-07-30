defmodule Atomboy.Joypad do
  @moduledoc """
  The P1/JOYP register (0xFF00), with real keys at the end of the lines.

  The hardware crosses two rows of four lines — directions and buttons —
  selected by bits 5-4 (active low) that the game writes. A read returns, in
  the low nibble, the state of the selected lines, active low: bit at 0 = key
  pressed. Both rows selected at once combine with an AND — two keys on the
  same line pull the wire together.

  The key state lives in the map of writes under two non-address keys, one
  nibble per row, 1 = released as on the lines:

      :joy_dpad   bit 0 Right   bit 1 Left   bit 2 Up       bit 3 Down
      :joy_btns   bit 0 A       bit 1 B      bit 2 Select   bit 3 Start

  Two entry points: `write/2` when the game writes the selection, `set/3`
  when the outside world (keyboard, GPIO one day) changes the keys — each one
  recomposes the readable byte, and a freshly pressed key raises bit 4 of IF,
  the joypad interrupt.
  """

  import Bitwise

  @if_addr 0xFF0F
  @joyp 0xFF00

  @doc """
  The game writes 0xFF00: the selection (bits 5-4) is kept, the lines
  recomposed. Bits 7-6 at 1, as on the bus.
  """
  @spec write(map(), byte()) :: map()
  def write(ram, value) do
    Map.put(ram, @joyp, compose(ram, value &&& 0x30))
  end

  @doc """
  The outside world sets the state of both rows — one nibble each, 1 =
  released. The readable byte is recomposed with the selection in place, and
  any freshly pressed key raises the joypad interrupt (IF bit 4).
  """
  @spec set(map(), 0..15, 0..15) :: map()
  def set(ram, dpad, btns) do
    pressed? =
      (Map.get(ram, :joy_dpad, 0x0F) &&& bxor(dpad, 0x0F)) != 0 or
        (Map.get(ram, :joy_btns, 0x0F) &&& bxor(btns, 0x0F)) != 0

    ram = ram |> Map.put(:joy_dpad, dpad) |> Map.put(:joy_btns, btns)
    ram = Map.put(ram, @joyp, compose(ram, Map.get(ram, @joyp, 0xFF) &&& 0x30))

    if pressed? do
      Map.update(ram, @if_addr, 0x10, &(&1 ||| 0x10))
    else
      ram
    end
  end

  # The selected lines, ANDed — an unselected row reads all released.
  defp compose(ram, select) do
    lines = 0x0F
    lines = if (select &&& 0x10) == 0, do: lines &&& Map.get(ram, :joy_dpad, 0x0F), else: lines
    lines = if (select &&& 0x20) == 0, do: lines &&& Map.get(ram, :joy_btns, 0x0F), else: lines
    0xC0 ||| select ||| lines
  end
end
