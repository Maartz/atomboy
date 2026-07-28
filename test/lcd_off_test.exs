defmodule Atomboy.LcdOffTest do
  @moduledoc """
  Écran éteint : le PPU s'arrête, pas seulement l'affichage.

  La règle a coûté une longue traque — un opcode illégal dans Pokémon, à des
  secondes de sa cause. Les jeux éteignent le LCD pour recharger la VRAM
  (Pokémon à chaque changement de carte) et continuent d'appeler leur moteur
  sonore depuis la boucle principale, interruptions ouvertes. Un vblank
  fantôme rappelle ce moteur par-dessus lui-même, et la corruption chemine
  jusqu'à un saut dans du texte de dialogue.
  """

  use ExUnit.Case, async: true

  import Bitwise

  alias Atomboy.CPU.State
  alias Atomboy.Screen

  # Une ROM qui ne fait que boucler sur place : seul le matériel simulé agit.
  defp rom do
    code = <<0x18, 0xFE>>
    :binary.copy(<<0>>, 0x100) <> code <> :binary.copy(<<0>>, 0x8000 - 0x100 - byte_size(code))
  end

  defp run_lines(ram) do
    Enum.reduce(0..153, {%State{pc: 0x100}, ram}, fn ly, {state, ram} ->
      Screen.step_line(state, rom(), ram, ly)
    end)
  end

  test "écran allumé : le vblank se lève à la ligne 144" do
    {_state, ram} = run_lines(%{0xFF40 => 0x91})
    assert (Map.get(ram, 0xFF0F, 0) &&& 0x01) == 0x01
  end

  test "écran éteint : aucun vblank, LY reste à zéro" do
    {_state, ram} = run_lines(%{0xFF40 => 0x11})

    assert (Map.get(ram, 0xFF0F, 0) &&& 0x01) == 0
    assert Map.get(ram, 0xFF44) == 0
  end

  test "écran éteint : la coïncidence LY=LYC ne déclenche rien" do
    # STAT bit 6 armé, LYC = 0 — allumé, la coïncidence lèverait l'interruption.
    ram = %{0xFF40 => 0x11, 0xFF41 => 0x40, 0xFF45 => 0x00}
    {_state, ram} = run_lines(ram)

    assert (Map.get(ram, 0xFF0F, 0) &&& 0x02) == 0
    assert (Map.get(ram, 0xFF41, 0) &&& 0x04) == 0
  end

  test "écran rallumé : le vblank repart" do
    {_state, ram} = run_lines(%{0xFF40 => 0x11})
    {_state, ram} = run_lines(Map.put(ram, 0xFF40, 0x91))

    assert (Map.get(ram, 0xFF0F, 0) &&& 0x01) == 0x01
  end
end
