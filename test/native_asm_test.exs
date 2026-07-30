defmodule Atomboy.NativeAsmTest do
  use ExUnit.Case, async: true

  alias Atomboy.Native.Asm
  alias Atomboy.Native.RV32

  describe "les étiquettes" do
    test "un renvoi arrière vise la bonne distance" do
      %{code: code} =
        Asm.assemble([
          Asm.label(:boucle),
          RV32.nop(),
          Asm.j(:boucle)
        ])

      # Le saut est à l'offset 4, la cible à 0 : un déplacement de -4.
      assert code == RV32.nop() <> RV32.j(-4)
    end

    test "un renvoi avant est comblé à la seconde passe" do
      %{code: code} =
        Asm.assemble([
          Asm.j(:fin),
          RV32.nop(),
          RV32.nop(),
          Asm.label(:fin),
          RV32.ret()
        ])

      assert code == RV32.j(12) <> RV32.nop() <> RV32.nop() <> RV32.ret()
    end

    test "un branchement conditionnel vise une étiquette comme les autres" do
      %{code: code} = Asm.assemble([Asm.beqz(:a0, :suite), RV32.nop(), Asm.label(:suite)])
      assert code == RV32.beq(:a0, :zero, 8) <> RV32.nop()
    end

    test "une étiquette inconnue lève en nommant celles qui existent" do
      assert_raise ArgumentError, ~r/étiquette inconnue : :absente.*présente/s, fn ->
        Asm.assemble([Asm.label(:présente), Asm.j(:absente)])
      end
    end

    test "une étiquette définie deux fois lève" do
      assert_raise ArgumentError, ~r/deux fois/, fn ->
        Asm.assemble([Asm.label(:双), Asm.label(:双)])
      end
    end
  end

  describe "les adresses absolues" do
    test "un {:addr, _} contient l'adresse de chargement plus l'offset" do
      base = 0x8000_0000

      %{code: code} =
        Asm.assemble(
          [
            {:addr, :cible},
            RV32.nop(),
            Asm.label(:cible),
            RV32.ret()
          ],
          base
        )

      assert <<address::32-little, _::binary>> = code
      assert address == base + 8
    end

    test "address/3 rend la même adresse que la table de saut" do
      base = 0x8000_0000
      image = Asm.assemble([RV32.nop(), Asm.label(:ici), RV32.ret()], base)
      assert Asm.address(image, :ici, base) == base + 4
    end
  end

  describe "l'alignement et les réserves" do
    test "{:align, n} bourre jusqu'au multiple" do
      %{code: code, labels: labels} =
        Asm.assemble([<<1, 2, 3>>, {:align, 4}, Asm.label(:aligné), <<0xFF>>])

      assert byte_size(code) == 5
      assert labels[:aligné] == 4
      assert code == <<1, 2, 3, 0, 0xFF>>
    end

    test "{:align, n} sur une position déjà alignée ne coûte rien" do
      %{code: code} = Asm.assemble([RV32.nop(), {:align, 4}, RV32.ret()])
      assert byte_size(code) == 8
    end

    test "{:space, n} réserve des octets nuls" do
      %{code: code, labels: labels} = Asm.assemble([{:space, 6}, Asm.label(:après)])
      assert code == <<0, 0, 0, 0, 0, 0>>
      assert labels[:après] == 6
    end
  end

  describe "l'invariant des deux passes" do
    test "la taille annoncée est celle qui est émise" do
      # Un mélange de tous les types d'éléments, dont la taille est connue :
      # 4 + 4 + 4 + 3 + 1 (alignement) + 4 + 8 = 28.
      %{code: code, size: size} =
        Asm.assemble([
          RV32.nop(),
          Asm.j(:fin),
          {:addr, :fin},
          <<1, 2, 3>>,
          {:align, 4},
          Asm.label(:fin),
          RV32.ret(),
          {:space, 8}
        ])

      assert size == 28
      assert byte_size(code) == size
    end

    test "un élément inconnu lève plutôt que d'être ignoré" do
      assert_raise ArgumentError, ~r/élément d'assemblage inconnu/, fn ->
        Asm.assemble([RV32.nop(), :surprise])
      end
    end

    test "les listes imbriquées sont aplaties — li en produit" do
      %{size: size} = Asm.assemble([RV32.li(:a0, 0x1234_5678), RV32.ret()])
      assert size == 12
    end
  end
end
