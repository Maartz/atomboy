defmodule Atomboy.Memory.Flat do
  @moduledoc """
  Espace d'adressage 64 Ko creux, porté par une map. Backend de la phase 1.

  Les adresses jamais écrites lisent 0. C'est exactement l'hypothèse des
  vecteurs SingleStepTests, qui énumèrent chaque adresse touchée.

  Ce backend n'est **pas** destiné à faire tourner une ROM : une map veut dire
  un hash par accès et de l'allocation à chaque écriture. Il existe pour que le
  harnais de test CPU n'ait aucune dépendance sur le modèle mémoire définitif,
  qui lui est segmenté (ROM en binary, régions mutables à part).
  """

  @behaviour Atomboy.Memory

  import Bitwise

  @type t :: %{Atomboy.Memory.addr() => Atomboy.Memory.value()}

  @doc """
  Construit une mémoire à partir d'une liste de paires `{adresse, octet}`.
  """
  @spec new(Enumerable.t()) :: t()
  def new(pairs \\ []), do: Map.new(pairs)

  @impl true
  def read8(mem, addr), do: Map.get(mem, addr, 0)

  @impl true
  def write8(mem, addr, value), do: Map.put(mem, addr, value)

  @impl true
  def read16(mem, addr) do
    lo = Map.get(mem, addr, 0)
    hi = Map.get(mem, addr + 1 &&& 0xFFFF, 0)
    bsl(hi, 8) ||| lo
  end

  @impl true
  def write16(mem, addr, value) do
    mem
    |> Map.put(addr, value &&& 0xFF)
    |> Map.put(addr + 1 &&& 0xFFFF, bsr(value, 8) &&& 0xFF)
  end
end
