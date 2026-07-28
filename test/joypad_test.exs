defmodule Atomboy.JoypadTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Atomboy.Joypad

  # bit 4 à 0 : nappe directions ; bit 5 à 0 : nappe boutons.
  @select_dpad 0x20
  @select_btns 0x10
  @select_none 0x30

  test "sans touche pressée, les lignes lisent tout relâché" do
    ram = Joypad.write(%{}, @select_dpad)
    assert Map.fetch!(ram, 0xFF00) == 0xEF

    ram = Joypad.write(%{}, @select_btns)
    assert Map.fetch!(ram, 0xFF00) == 0xDF
  end

  test "une direction pressée tire sa ligne quand la nappe est sélectionnée" do
    # Droite = bit 0 de :joy_dpad.
    ram = %{} |> Joypad.write(@select_dpad) |> Joypad.set(0x0E, 0x0F)
    assert (Map.fetch!(ram, 0xFF00) &&& 0x0F) == 0x0E
  end

  test "la nappe non sélectionnée reste muette" do
    # A pressé (boutons), mais le jeu lit les directions : rien.
    ram = %{} |> Joypad.write(@select_dpad) |> Joypad.set(0x0F, 0x0E)
    assert (Map.fetch!(ram, 0xFF00) &&& 0x0F) == 0x0F
  end

  test "changer la sélection relit les lignes déjà posées" do
    # Start pressé, sélection sur directions puis basculée sur boutons.
    ram = %{} |> Joypad.write(@select_dpad) |> Joypad.set(0x0F, 0x07)
    ram = Joypad.write(ram, @select_btns)
    assert (Map.fetch!(ram, 0xFF00) &&& 0x0F) == 0x07
  end

  test "les deux nappes sélectionnées se combinent en ET" do
    ram = %{} |> Joypad.write(0x00) |> Joypad.set(0x0E, 0x07)
    assert (Map.fetch!(ram, 0xFF00) &&& 0x0F) == 0x06
  end

  test "aucune nappe sélectionnée : tout relâché, quoi qu'on presse" do
    ram = %{} |> Joypad.write(@select_none) |> Joypad.set(0x00, 0x00)
    assert (Map.fetch!(ram, 0xFF00) &&& 0x0F) == 0x0F
  end

  test "une pression neuve lève l'interruption joypad" do
    ram = Joypad.set(%{}, 0x0F, 0x0E)
    assert (Map.fetch!(ram, 0xFF0F) &&& 0x10) == 0x10
  end

  test "maintenir ou relâcher ne lève rien" do
    ram = %{} |> Joypad.set(0x0F, 0x0E) |> Map.put(0xFF0F, 0)

    ram = Joypad.set(ram, 0x0F, 0x0E)
    assert Map.fetch!(ram, 0xFF0F) == 0

    ram = Joypad.set(ram, 0x0F, 0x0F)
    assert Map.fetch!(ram, 0xFF0F) == 0
  end

  test "les bits hauts lisent 1, comme le bus" do
    ram = Joypad.write(%{}, 0xFF)
    assert (Map.fetch!(ram, 0xFF00) &&& 0xC0) == 0xC0
  end
end
