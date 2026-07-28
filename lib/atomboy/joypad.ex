defmodule Atomboy.Joypad do
  @moduledoc """
  Le registre P1/JOYP (0xFF00), avec de vraies touches au bout des lignes.

  Le matériel croise deux nappes de quatre lignes — directions et boutons —
  sélectionnées par les bits 5-4 (actifs à zéro) que le jeu écrit. La lecture
  renvoie dans le quartet bas l'état des lignes sélectionnées, actives à
  zéro : bit à 0 = touche pressée. Les deux nappes sélectionnées à la fois se
  combinent en ET — deux touches sur la même ligne tirent le fil ensemble.

  L'état des touches vit dans la map des écritures sous deux clés hors
  adresse, un quartet par nappe, à 1 = relâché comme les lignes :

      :joy_dpad   bit 0 Droite   bit 1 Gauche   bit 2 Haut     bit 3 Bas
      :joy_btns   bit 0 A        bit 1 B        bit 2 Select   bit 3 Start

  Deux entrées : `write/2` quand le jeu écrit la sélection, `set/3` quand le
  monde extérieur (clavier, GPIO un jour) change les touches — chacune
  recompose l'octet lisible, et une pression neuve lève le bit 4 d'IF,
  l'interruption joypad.
  """

  import Bitwise

  @if_addr 0xFF0F
  @joyp 0xFF00

  @doc """
  Le jeu écrit 0xFF00 : la sélection (bits 5-4) est retenue, les lignes
  recomposées. Bits 7-6 à 1, comme le bus.
  """
  @spec write(map(), byte()) :: map()
  def write(ram, value) do
    Map.put(ram, @joyp, compose(ram, value &&& 0x30))
  end

  @doc """
  Le monde extérieur pose l'état des deux nappes — un quartet chacune,
  à 1 = relâché. L'octet lisible est recomposé avec la sélection en place,
  et toute touche nouvellement pressée lève l'interruption joypad (IF bit 4).
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

  # Les lignes sélectionnées, en ET — nappe non sélectionnée : tout relâché.
  defp compose(ram, select) do
    lines = 0x0F
    lines = if (select &&& 0x10) == 0, do: lines &&& Map.get(ram, :joy_dpad, 0x0F), else: lines
    lines = if (select &&& 0x20) == 0, do: lines &&& Map.get(ram, :joy_btns, 0x0F), else: lines
    0xC0 ||| select ||| lines
  end
end
