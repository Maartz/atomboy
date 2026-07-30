defmodule Atomboy.Timer do
  @moduledoc """
  The DMG's hardware counters: DIV and TIMA.

  Advanced in batches of T-cycles between two slices of execution — the
  granularity of the scanline (456 T), fine enough for blargg's tests, coarse
  enough to cost the hot path nothing. The division sub-counters live in the
  map of writes under non-address keys, just like the MBC state.

      0xFF04  DIV  — beats at 1/256th of the crystal; any write resets it to
              zero (the interception is in CartLoop)
      0xFF05  TIMA — counts at TAC's rate; on overflow, reloads from TMA and
              raises bit 2 of IF
      0xFF06  TMA  — the reload value
      0xFF07  TAC  — bit 2 on/off, bits 0-1 the rate

  The four rates, in T-cycles per increment: 1024, 16, 64, 256.
  """

  import Bitwise

  @div 0xFF04
  @tima 0xFF05
  @tma 0xFF06
  @tac 0xFF07
  @irq_if 0xFF0F

  @periods {1024, 16, 64, 256}

  @doc """
  Advances the counters by `cycles` T-cycles.
  """
  @spec advance(map(), non_neg_integer()) :: map()
  def advance(ram, cycles) do
    ram |> advance_div(cycles) |> advance_tima(cycles)
  end

  defp advance_div(ram, cycles) do
    total = Map.get(ram, :div_acc, 0) + cycles
    increments = bsr(total, 8)
    ram = Map.put(ram, :div_acc, total &&& 0xFF)

    if increments == 0 do
      ram
    else
      Map.update(ram, @div, increments &&& 0xFF, &(&1 + increments &&& 0xFF))
    end
  end

  defp advance_tima(ram, cycles) do
    tac = Map.get(ram, @tac, 0)

    if band(tac, 0x04) == 0 do
      ram
    else
      period = elem(@periods, band(tac, 0x03))
      total = Map.get(ram, :tima_acc, 0) + cycles
      increments = div(total, period)
      ram = Map.put(ram, :tima_acc, rem(total, period))
      tick_tima(ram, increments)
    end
  end

  defp tick_tima(ram, 0), do: ram

  defp tick_tima(ram, increments) do
    case Map.get(ram, @tima, 0) + 1 do
      0x100 ->
        # Overflow: reload from TMA, timer interrupt requested.
        ram
        |> Map.put(@tima, Map.get(ram, @tma, 0))
        |> Map.update(@irq_if, 0x04, &bor(&1, 0x04))
        |> tick_tima(increments - 1)

      value ->
        ram |> Map.put(@tima, value) |> tick_tima(increments - 1)
    end
  end
end
