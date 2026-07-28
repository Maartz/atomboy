defmodule Atomboy.ScreenTest do
  @moduledoc """
  Le test en or du rendu : la frame exacte que blargg affiche.

  Après 900 frames de `06-ld r,r`, l'écran montre « 06-ld r,r » puis
  « Passed » en tuiles de fond — du texte lisible, rendu pixel par pixel.
  Le CRC fige cette frame : toute dérive du PPU (palette, défilement,
  adressage de tuiles, ordre des bits) casse ici avec un point de départ
  net pour le diff.

  Un changement *délibéré* du rendu met le CRC à jour en re-générant :

      MIX_ENV=dev mix run -e '{f, _, _} = Atomboy.Screen.run(rom, 900); ...crc32...'

  et en relisant l'écran à l'œil via `mix atomboy.screen` — le texte doit
  rester lisible, c'est toute la valeur de cette ROM comme référence.
  """

  use ExUnit.Case, async: true

  @moduletag :blargg
  @moduletag timeout: 300_000

  @rom "test/fixtures/gb-test-roms/cpu_instrs/individual/06-ld r,r.gb"
  @golden_crc 0xF8C8FA9B

  test "l'écran de 06-ld r,r affiche son verdict, au pixel près" do
    {frame, _state, _ram} = Atomboy.Screen.run(@rom, 900)

    assert byte_size(frame) == 160 * 144
    assert :erlang.crc32(frame) == @golden_crc
  end

  @acid2 "test/fixtures/dmg-acid2.gb"
  @acid2_crc 0x9F51DD25

  test "dmg-acid2 dessine son visage, au pixel près" do
    # Le test d'acceptance des PPU : chaque trait du visage nomme la feature
    # qui le casse — sprites 8×16, miroirs, priorités, fenêtre et son
    # compteur de ligne interne. Un CRC pour tout le rendu.
    {frame, _state, _ram} = Atomboy.Screen.run(@acid2, 120)
    assert :erlang.crc32(frame) == @acid2_crc
  end

  test "une frame rendue ne contient que des teintes DMG" do
    {frame, _state, _ram} = Atomboy.Screen.run(@rom, 60)
    assert for(<<shade <- frame>>, shade > 3, do: shade) == []
  end
end
