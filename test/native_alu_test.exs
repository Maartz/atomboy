defmodule Atomboy.NativeALUTest do
  @moduledoc """
  L'arithmétique de drapeaux, des deux côtés, sur tout l'espace d'entrée.

  Un seul test porte l'essentiel : il lance le banc et exige zéro écart. Ce
  n'est pas un test d'exemples déguisé — 892 928 cas, soit près de 1,8 million
  de valeurs comparées : la totalité de `ADD`, `SUB`, `CP`, `AND`, `XOR`, `OR`
  sur leurs 65 536 couples, `ADC` et `SBC` sur les mêmes couples dans les deux
  états de la retenue, et l'intégralité de `DAA`, des rotations et des `BIT n`.

  Le reste du fichier vérifie que le banc lui-même n'est pas creux : qu'il
  couvre bien ce que `Atomboy.CPU.ALU` expose, et qu'il balaie le nombre de cas
  annoncé.
  """

  use ExUnit.Case, async: true

  alias Atomboy.Native.ALU
  alias Atomboy.Native.Banc

  @moduletag :qemu
  @moduletag timeout: 300_000

  describe "le banc différentiel" do
    test "aucun écart entre l'ALU native et l'oracle Elixir" do
      assert {:ok, ecarts} = Banc.executer()

      assert ecarts == [], """
      #{length(ecarts)} divergence(s) entre Atomboy.Native.ALU et Atomboy.CPU.ALU :

      #{Enum.map_join(Enum.take(ecarts, 8), "\n", &format/1)}
      """
    end
  end

  describe "le banc lui-même" do
    test "il balaie l'espace annoncé, sans qu'un balayage se soit fait rogner" do
      total = Enum.sum(Enum.map(Banc.balayages(), & &1.cas))

      assert total == 892_928,
             "le banc couvre #{total} cas au lieu de 892 928 — un balayage a changé de taille"
    end

    test "il couvre toutes les fonctions publiques de l'ALU de l'oracle" do
      # `bit_test` est couvert par les huit balayages `bit_n`, dont le numéro de
      # bit est cuit dans la routine native.
      exportees =
        Atomboy.CPU.ALU.__info__(:functions)
        |> Enum.map(&elem(&1, 0))
        |> MapSet.new()
        |> MapSet.delete(:bit_test)

      balayees = MapSet.new(Banc.balayages(), & &1.nom)

      manquantes = MapSet.difference(exportees, balayees)

      assert MapSet.size(manquantes) == 0,
             "non balayées : #{inspect(MapSet.to_list(manquantes))}"

      assert Enum.any?(Banc.balayages(), &(&1[:bit] == 3)), "les BIT n sont balayés"
    end

    test "ADC et SBC sont balayés dans les deux états de la retenue" do
      for nom <- [:adc, :sbc] do
        drapeaux = for b <- Banc.balayages(), b.nom == nom, do: b.f
        assert Enum.sort(drapeaux) == [0x00, 0xF0], "#{nom} : #{inspect(drapeaux)}"
      end
    end

    test "les mélanges qui fabriquent les opérandes 16 bits restent dans leur plage" do
      for i <- [0, 1, 0x1234, 0xFFFF] do
        assert Banc.melange16(i) in 0..0xFFFF
        assert Banc.melange8(i) in 0..0xFF
      end

      # Un mélange constant ne couvrirait rien : on exige de la dispersion.
      valeurs = for i <- 0..999, do: Banc.melange16(i)
      assert length(Enum.uniq(valeurs)) > 900
    end
  end

  describe "les étiquettes" do
    test "chaque balayage vise une routine réellement émise" do
      image = Banc.image()

      for balayage <- Banc.balayages() do
        etiquette = Banc.etiquette(balayage)

        assert Map.has_key?(image.labels, etiquette),
               "le balayage #{balayage.nom} vise #{etiquette}, qui n'est pas émise"
      end
    end

    test "le nommage suit celui de l'oracle" do
      assert ALU.etiquette(:add) == :alu_add
      assert ALU.etiquette(:bit_and) == :alu_bit_and
      assert ALU.etiquette_bit(7) == :alu_bit_7
    end
  end

  defp format(%{balayage: nom, cas: cas, entrees: entrees, obtenu: obtenu, attendu: attendu}) do
    "  #{nom} cas #{cas} #{inspect(entrees)} : obtenu #{drapeaux(obtenu)}, attendu #{drapeaux(attendu)}"
  end

  # Les drapeaux épelés : `f: 176` n'apprend rien, `Z-HC` se lit.
  defp drapeaux({valeur, f}) do
    "#{valeur}/#{Atomboy.CPU.State.flag_string(%Atomboy.CPU.State{f: f})}"
  end
end
