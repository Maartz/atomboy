defmodule Atomboy.Blargg do
  @moduledoc """
  Runs a blargg test ROM and reads its verdict off the serial link.

  The ROMs of the `cpu_instrs` generation publish their results character by
  character on the serial link — one byte into 0xFF01, bit 7 of 0xFF02 to send
  it. `Atomboy.CPU.CartLoop` captures every send at write time into the
  `:serial` buffer of its map; here we do nothing but peer into that buffer
  between two slices of execution, looking for `Passed` or `Failed`.

  CartLoop's cartridge semantics are indispensable: blargg drives the MBC by
  writing below 0x8000, and `Loop`'s flat model would let those writes mask
  the ROM.

  The initial state is the one the DMG boot ROM leaves to the game: PC 0x100,
  SP 0xFFFE, AF 0x01B0, BC 0x0013, DE 0x00D8, HL 0x014D. The LY register
  (0xFF44) is pre-written to 0x90 — the vblank line — for screen waits;
  blargg is designed not to hang if LY never moves, but we may as well answer
  it something sensible.
  """

  alias Atomboy.CPU.State

  # One frame between two inspections of the serial buffer.
  @frame_cycles 70_224

  @type verdict :: {:passed, String.t()} | {:failed, String.t()} | {:timeout, String.t()}

  @doc """
  Runs the ROM until the verdict, or `max_cycles` at most.
  """
  @spec run(Path.t(), pos_integer()) :: verdict()
  def run(rom_path, max_cycles \\ 500_000_000) do
    rom = load(rom_path)

    state = %State{
      a: 0x01,
      f: 0xB0,
      b: 0x00,
      c: 0x13,
      d: 0x00,
      e: 0xD8,
      h: 0x01,
      l: 0x4D,
      sp: 0xFFFE,
      pc: 0x0100
    }

    execute(state, rom, %{0xFF44 => 0x90, rom_banks: div(byte_size(rom), 0x4000)}, max_cycles)
  end

  defp load(path) do
    rom = File.read!(path)

    if byte_size(rom) < 0x8000 do
      rom <> :binary.copy(<<0xFF>>, 0x8000 - byte_size(rom))
    else
      rom
    end
  end

  defp execute(_state, _rom, ram, budget_left) when budget_left <= 0 do
    {:timeout, serial(ram)}
  end

  # One frame of 154 scanlines per turn, through the shared building block —
  # LY lives, vblank rises, the timer beats: 02-interrupts measures all of it.
  defp execute(state, rom, ram, budget_left) do
    {state, ram} =
      Enum.reduce(0..153, {state, ram}, fn ly, {state, ram} ->
        Atomboy.Screen.step_line(state, rom, ram, ly)
      end)

    output = serial(ram)

    cond do
      String.contains?(output, "Passed") -> {:passed, output}
      String.contains?(output, "Failed") -> {:failed, output}
      true -> execute(state, rom, ram, budget_left - @frame_cycles)
    end
  end

  defp serial(ram) do
    ram |> Map.get(:serial, "") |> IO.iodata_to_binary()
  end
end
