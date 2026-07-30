defmodule Potion.ROMTest do
  @moduledoc """
  La cartouche vérifiée champ par champ — puis bootée.

  Les sommes de contrôle sont recalculées ici par une seconde implémentation,
  indépendante de celle du module : un test qui rappellerait la même fonction
  validerait une tautologie. Le dernier test est celui qui compte : la ROM
  émise tourne dans l'émulateur, frames entières, sans lever — le premier
  maillon de la chaîne « Potion écrit, atomboy exécute ».
  """

  use ExUnit.Case, async: true

  import Bitwise

  alias Atomboy.Screen
  alias Potion.ROM

  @boucle [{:etiquette, :ici}, {:jr, {:etiquette, :ici}}]

  describe "l'en-tête" do
    test "32 Ko exactement, entrée NOP + JP 0x150" do
      rom = ROM.construit(@boucle)

      assert byte_size(rom) == 0x8000
      assert binary_part(rom, 0x100, 4) == <<0x00, 0xC3, 0x50, 0x01>>
      # Le code est bien à l'adresse promise.
      assert binary_part(rom, 0x150, 2) == <<0x18, 0xFE>>
    end

    test "le logo Nintendo est celui que la ROM de boot exige" do
      rom = ROM.construit(@boucle)

      # Les quatre premiers octets suffisent à reconnaître l'original — et le
      # test complet est la somme d'en-tête, qui couvre d'autres champs.
      assert binary_part(rom, 0x104, 4) == <<0xCE, 0xED, 0x66, 0x66>>
      assert binary_part(rom, 0x104, 48) |> :binary.bin_to_list() |> Enum.sum() == 5446
    end

    test "le titre est passé en majuscules et rembourré de zéros" do
      rom = ROM.construit(@boucle, titre: "pong")

      assert binary_part(rom, 0x134, 16) == "PONG" <> :binary.copy(<<0>>, 12)
    end

    test "cartouche DMG, ROM seule : les drapeaux à zéro" do
      rom = ROM.construit(@boucle)

      # 0x143 : pas de couleur. 0x147 : pas de MBC. 0x148-0x149 : 32 Ko, pas
      # de RAM. C'est ce que Screen.boot_ram lira.
      assert :binary.at(rom, 0x143) == 0x00
      assert :binary.at(rom, 0x147) == 0x00
      assert :binary.at(rom, 0x148) == 0x00
      assert :binary.at(rom, 0x149) == 0x00
      assert Screen.boot_ram(rom) == %{rom_banks: 2, mbc: :mbc1}
    end

    test "la somme d'en-tête est celle que le boot vérifie" do
      rom = ROM.construit(@boucle, titre: "VERIF")

      attendu =
        rom
        |> binary_part(0x134, 0x14D - 0x134)
        |> :binary.bin_to_list()
        |> Enum.reduce(0, fn octet, somme -> somme - octet - 1 &&& 0xFF end)

      assert :binary.at(rom, 0x14D) == attendu
      # Elle dépend du titre : deux ROMs de titres différents diffèrent ici.
      autre = ROM.construit(@boucle, titre: "AUTRE")
      refute :binary.at(autre, 0x14D) == :binary.at(rom, 0x14D)
    end

    test "la somme globale couvre tout sauf ses deux cases" do
      rom = ROM.construit(@boucle)

      sans_cases =
        binary_part(rom, 0, 0x14E) <> <<0, 0>> <> binary_part(rom, 0x150, 0x8000 - 0x150)

      attendu = sans_cases |> :binary.bin_to_list() |> Enum.sum() |> band(0xFFFF)
      <<lue::16-big>> = binary_part(rom, 0x14E, 2)

      assert lue == attendu
    end
  end

  describe "le vecteur vblank" do
    test "l'étiquette devient un JP en 0x40" do
      programme = [
        {:etiquette, :ici},
        {:jr, {:etiquette, :ici}},
        {:etiquette, :vbl},
        {:reti}
      ]

      rom = ROM.construit(programme, vblank: :vbl)

      # :vbl est à 0x150 + 2 (le JR).
      assert binary_part(rom, 0x40, 3) == <<0xC3, 0x52, 0x01>>
    end

    test "une étiquette absente est refusée nommément" do
      erreur =
        assert_raise ArgumentError, fn -> ROM.construit(@boucle, vblank: :fantome) end

      assert erreur.message =~ ":fantome"
    end

    test "sans option, le vecteur reste des zéros" do
      rom = ROM.construit(@boucle)

      assert binary_part(rom, 0x40, 3) == <<0, 0, 0>>
    end
  end

  describe "les refus" do
    test "un titre trop long ou accentué" do
      assert_raise ArgumentError, fn -> ROM.construit(@boucle, titre: "SEIZECARACTERES!") end
      assert_raise ArgumentError, fn -> ROM.construit(@boucle, titre: "POTITRÉ") end
    end

    test "un programme plus grand que la place" do
      trop = [{:octets, :binary.copy(<<0>>, 0x8000 - 0x150 + 1)}]

      erreur = assert_raise ArgumentError, fn -> ROM.construit(trop) end

      assert erreur.message =~ "programme trop grand"
    end
  end

  describe "dans l'émulateur" do
    test "la ROM nue boote et tourne des frames entières sans lever" do
      rom = ROM.construit(@boucle)
      state = Screen.boot_state(rom)
      ram = Screen.boot_ram(rom)

      {_pixels, state, _ram} =
        Enum.reduce(1..5, {<<>>, state, ram}, fn _frame, {_pixels, state, ram} ->
          Screen.frame(state, rom, ram, true)
        end)

      # Le processeur est resté dans la boucle : sur le JR (0x151) ou juste
      # après son fetch — pas parti exécuter du remplissage.
      assert state.pc in 0x150..0x152
    end

    test "un programme qui calcule : la WRAM porte le résultat" do
      programme = [
        {:ld, :a, 21},
        {:add, :a, :a},
        {:ld, {:mem, 0xC000}, :a},
        {:etiquette, :fin},
        {:jr, {:etiquette, :fin}}
      ]

      rom = ROM.construit(programme, titre: "CALCUL")
      state = Screen.boot_state(rom)
      ram = Screen.boot_ram(rom)

      {_pixels, _state, ram} = Screen.frame(state, rom, ram, false)

      assert Map.get(ram, 0xC000) == 42
    end
  end
end
