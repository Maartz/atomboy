defmodule Atomboy.Timer do
  @moduledoc """
  Les compteurs matériels de la DMG : DIV et TIMA.

  Avancés par paquets de T-cycles entre deux tranches d'exécution — la
  granularité de la scanline (456 T), assez fine pour les tests de blargg,
  assez grosse pour ne rien coûter au chemin chaud. Les sous-compteurs de
  division vivent dans la map des écritures sous des clés hors adresse, comme
  l'état du MBC.

      0xFF04  DIV  — bat au 1/256e du cristal ; toute écriture le remet à
              zéro (l'interception est dans CartLoop)
      0xFF05  TIMA — compte à la cadence de TAC ; au débordement, recharge
              depuis TMA et lève le bit 2 d'IF
      0xFF06  TMA  — la valeur de recharge
      0xFF07  TAC  — bit 2 marche/arrêt, bits 0-1 la cadence

  Les quatre cadences, en T-cycles par incrément : 1024, 16, 64, 256.
  """

  import Bitwise

  @div 0xFF04
  @tima 0xFF05
  @tma 0xFF06
  @tac 0xFF07
  @irq_if 0xFF0F

  @periods {1024, 16, 64, 256}

  @doc """
  Avance les compteurs de `cycles` T-cycles.
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
        # Débordement : recharge depuis TMA, interruption timer demandée.
        ram
        |> Map.put(@tima, Map.get(ram, @tma, 0))
        |> Map.update(@irq_if, 0x04, &bor(&1, 0x04))
        |> tick_tima(increments - 1)

      value ->
        ram |> Map.put(@tima, value) |> tick_tima(increments - 1)
    end
  end
end
