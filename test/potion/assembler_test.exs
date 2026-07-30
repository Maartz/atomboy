defmodule Potion.AssemblerTest do
  @moduledoc """
  L'assembleur contre la table dont il est tiré.

  Le premier test est le seul qui compte vraiment : il reconstruit une
  instruction source pour **chacune** des instructions de
  `Atomboy.CPU.Table.all/0`, l'assemble, et compare les octets à ce que la table
  annonce — préfixe, opcode, immédiats en petit-boutien. Il n'énumère rien à la
  main et n'a rien à mettre à jour : une famille ajoutée à la table est
  immédiatement couverte, et une forme d'opérande que l'assembleur ne saurait pas
  écrire échoue ici plutôt que dans une ROM.

  C'est la même mécanique que `Atomboy.CPU.LoopTest` applique aux deux backends
  d'exécution : plutôt que de vérifier un échantillon choisi, on vérifie
  l'ensemble et on rapporte toutes les divergences d'un coup. Un échec liste les
  instructions fautives, pas la première.

  Le reste vérifie ce que la table ne dit pas : la résolution des étiquettes,
  les plages des immédiats, et — dernier maillon — qu'un programme assemblé
  s'exécute bien sur l'oracle CPU et calcule ce qui est écrit.
  """

  use ExUnit.Case, async: true

  alias Atomboy.CPU.Insn
  alias Atomboy.CPU.State
  alias Atomboy.CPU.Table
  alias Atomboy.Memory.Flat
  alias Potion.Assembler

  doctest Potion.Assembler

  # Des valeurs factices reconnaissables : un octet qui n'est pas un opcode
  # intéressant, un mot dont les deux moitiés diffèrent — de quoi voir un
  # petit-boutien inversé.
  @d8 0x12
  @d16 0x1234

  describe "aller-retour avec la table" do
    test "les #{length(Table.all())} instructions de la table s'assemblent comme elles se décodent" do
      divergences =
        for %Insn{} = insn <- Table.all(),
            emis = Assembler.assemble([source(insn)]),
            attendu = attendu(insn),
            emis != attendu,
            do: {Insn.label(insn), insn.prefix, insn.opcode, attendu, emis}

      assert divergences == []
    end

    test "chaque instruction occupe exactement les octets qu'elle annonce" do
      # L'assemblage de deux instructions bout à bout est la concaténation des
      # deux : rien ne se chevauche, rien ne se perd. C'est l'invariant de taille
      # vu de l'extérieur.
      for %Insn{} = insn <- Table.all() do
        seule = Assembler.assemble([source(insn)])
        doublee = Assembler.assemble([source(insn), source(insn)])

        assert doublee == seule <> seule, "chaînage incorrect pour #{Insn.label(insn)}"
      end
    end
  end

  describe "les opérandes ambigus" do
    test ":c se lit registre ou condition selon l'instruction" do
      # Aucune règle syntaxique ne les distingue — seule la table sait laquelle
      # des deux lectures désigne une instruction existante.
      assert Assembler.assemble([{:inc, :c}]) == <<0x0C>>
      assert Assembler.assemble([{:ret, :c}]) == <<0xD8>>
      assert Assembler.assemble([{:ret}]) == <<0xC9>>
      assert Assembler.assemble([{:jr, :c, 2}]) == <<0x38, 0x02>>
      assert Assembler.assemble([{:add, :a, :c}]) == <<0x81>>
      assert Assembler.assemble([{:ldh, :a, {:high, :c}}]) == <<0xF2>>
    end

    test "la largeur d'un immédiat est déduite de la table" do
      assert Assembler.assemble([{:ld, :a, 0x42}]) == <<0x3E, 0x42>>
      assert Assembler.assemble([{:ld, :hl, 0xC000}]) == <<0x21, 0x00, 0xC0>>
      assert Assembler.assemble([{:jp, 0xC000}]) == <<0xC3, 0x00, 0xC0>>
      assert Assembler.assemble([{:jr, 0x10}]) == <<0x18, 0x10>>
    end

    test "un entier vaut aussi cible de RST ou numéro de bit" do
      assert Assembler.assemble([{:rst, 0x00}]) == <<0xC7>>
      assert Assembler.assemble([{:rst, 0x38}]) == <<0xFF>>
      assert Assembler.assemble([{:bit, 7, {:mem, :hl}}]) == <<0xCB, 0x7E>>
      assert Assembler.assemble([{:res, 0, :a}]) == <<0xCB, 0x87>>
      assert Assembler.assemble([{:set, 3, :b}]) == <<0xCB, 0xD8>>
    end

    test "les immédiats signés de JR et ADD SP passent en complément à deux" do
      assert Assembler.assemble([{:jr, -2}]) == <<0x18, 0xFE>>
      assert Assembler.assemble([{:add_sp, :sp, -2}]) == <<0xE8, 0xFE>>
      assert Assembler.assemble([{:add_sp, :hl, 8}]) == <<0xF8, 0x08>>
      assert Assembler.assemble([{:add_sp, :sp, -128}]) == <<0xE8, 0x80>>
      assert Assembler.assemble([{:add_sp, :sp, 127}]) == <<0xE8, 0x7F>>
    end
  end

  describe "les étiquettes" do
    test "un JR arrière compte un écart négatif" do
      # NOP en 0x0150, JR en 0x0151 : PC vaut 0x0153 quand l'écart s'applique,
      # la cible est 0x0150, donc -3.
      programme = [{:label, :main_loop}, {:nop}, {:jr, {:label, :main_loop}}]

      assert Assembler.assemble(programme) == <<0x00, 0x18, 0xFD>>
    end

    test "un JR avant compte un écart positif" do
      programme = [{:jr, {:label, :fin}}, {:nop}, {:nop}, {:label, :fin}, {:halt}]

      assert Assembler.assemble(programme) == <<0x18, 0x02, 0x00, 0x00, 0x76>>
    end

    test "un JR conditionnel vise la même adresse" do
      programme = [{:label, :main_loop}, {:jr, :nz, {:label, :main_loop}}]

      assert Assembler.assemble(programme) == <<0x20, 0xFE>>
    end

    test "les deux bornes exactes de la portée d'un JR" do
      # +127 : l'étiquette est à 127 octets de l'adresse suivant le JR.
      avant = [{:jr, {:label, :loin}}, {:bytes, remplissage(127)}, {:label, :loin}]
      assert <<0x18, 0x7F, _::binary>> = Assembler.assemble(avant)

      # -128 : le JR est à 126 octets de l'étiquette, plus ses deux propres.
      arriere = [{:label, :loin}, {:bytes, remplissage(126)}, {:jr, {:label, :loin}}]
      assert <<_::binary-size(126), 0x18, 0x80>> = Assembler.assemble(arriere)
    end

    test "un JR hors de portée nomme l'écart et les deux adresses" do
      programme = [{:jr, {:label, :loin}}, {:bytes, remplissage(128)}, {:label, :loin}]

      erreur = assert_raise ArgumentError, fn -> Assembler.assemble(programme) end

      assert erreur.message =~ "saut relatif hors de portée"
      assert erreur.message =~ "L'écart est de 128 octets"
      assert erreur.message =~ "0x0152"
      assert erreur.message =~ "0x01D2"
      assert erreur.message =~ ":loin"
    end

    test "JP et CALL prennent l'adresse absolue" do
      programme = [
        {:label, :debut},
        {:jp, {:label, :debut}},
        {:call, {:label, :debut}},
        {:call, :nz, {:label, :debut}}
      ]

      assert Assembler.assemble(programme) ==
               <<0xC3, 0x50, 0x01, 0xCD, 0x50, 0x01, 0xC4, 0x50, 0x01>>
    end

    test "une étiquette sert aussi d'adresse mémoire" do
      programme = [
        {:ld, :a, {:mem, {:label, :donnee}}},
        {:label, :donnee},
        {:bytes, <<0x42>>}
      ]

      assert Assembler.assemble(programme) == <<0xFA, 0x53, 0x01, 0x42>>
    end

    test "une étiquette dans la page haute s'écrit en LDH" do
      programme = [
        {:ldh, {:high, {:label, :bgp}}, :a},
        {:bytes, remplissage(0xFF47 - 0x0152)},
        {:label, :bgp}
      ]

      assert <<0xE0, 0x47, _::binary>> = Assembler.assemble(programme)
    end

    test "une étiquette hors de la page haute refuse le LDH" do
      programme = [{:ldh, {:high, {:label, :ici}}, :a}, {:label, :ici}]

      erreur = assert_raise ArgumentError, fn -> Assembler.assemble(programme) end

      assert erreur.message =~ "hors de la page haute"
      assert erreur.message =~ "0x0152"
    end

    test "une étiquette inconnue liste celles qui existent" do
      programme = [{:label, :ici}, {:jp, {:label, :ailleurs}}]

      erreur = assert_raise ArgumentError, fn -> Assembler.assemble(programme) end

      assert erreur.message =~ "étiquette inconnue : :ailleurs"
      assert erreur.message =~ "définies : :ici"
    end

    test "une étiquette dupliquée donne les deux adresses" do
      programme = [{:label, :ici}, {:nop}, {:label, :ici}]

      erreur = assert_raise ArgumentError, fn -> Assembler.assemble(programme) end

      assert erreur.message =~ "étiquette dupliquée : :ici"
      assert erreur.message =~ "0x0150"
      assert erreur.message =~ "0x0151"
    end

    test "adresses/2 rend la carte sans émettre les octets" do
      programme = [{:bytes, <<1, 2, 3>>}, {:label, :ici}, {:nop}, {:label, :apres}]

      assert Assembler.addresses(programme, origin: 0x4000) == %{ici: 0x4003, apres: 0x4004}
    end
  end

  describe "octets bruts et origine" do
    test "les octets bruts s'intercalent tels quels" do
      programme = [{:nop}, {:bytes, <<0xDE, 0xAD>>}, {:nop}, {:bytes, <<>>}]

      assert Assembler.assemble(programme) == <<0x00, 0xDE, 0xAD, 0x00>>
    end

    test "l'origine décale toutes les adresses résolues" do
      programme = [{:label, :ici}, {:jp, {:label, :ici}}]

      assert Assembler.assemble(programme, origin: 0x0000) == <<0xC3, 0x00, 0x00>>
      assert Assembler.assemble(programme, origin: 0x0150) == <<0xC3, 0x50, 0x01>>
      assert Assembler.assemble(programme, origin: 0x4000) == <<0xC3, 0x00, 0x40>>
    end

    test "l'origine ne change pas un écart relatif" do
      programme = [{:label, :main_loop}, {:jr, {:label, :main_loop}}]

      assert Assembler.assemble(programme, origin: 0x0000) ==
               Assembler.assemble(programme, origin: 0x7FF0)
    end

    test "un programme vide donne un binaire vide" do
      assert Assembler.assemble([]) == <<>>
      assert Assembler.assemble([{:label, :seule}]) == <<>>
    end
  end

  describe "les refus" do
    test "un immédiat hors plage nomme la valeur et la plage attendue" do
      erreur = assert_raise ArgumentError, fn -> Assembler.assemble([{:ld, :a, 0x100}]) end

      assert erreur.message =~ "immédiat hors plage"
      assert erreur.message =~ "256 ne tient pas dans un octet"
      assert erreur.message =~ "0..255"
    end

    test "les bornes des immédiats non signés" do
      assert Assembler.assemble([{:ld, :a, 0xFF}]) == <<0x3E, 0xFF>>
      assert Assembler.assemble([{:ld, :bc, 0xFFFF}]) == <<0x01, 0xFF, 0xFF>>
      assert_raise ArgumentError, fn -> Assembler.assemble([{:ld, :a, -1}]) end
      assert_raise ArgumentError, fn -> Assembler.assemble([{:ld, :bc, 0x10000}]) end
      assert_raise ArgumentError, fn -> Assembler.assemble([{:ld, {:mem, 0x10000}, :a}]) end
    end

    test "un déplacement signé hors de -128..127" do
      assert_raise ArgumentError, fn -> Assembler.assemble([{:add_sp, :sp, -129}]) end
      assert_raise ArgumentError, fn -> Assembler.assemble([{:jr, -129}]) end
    end

    test "une instruction inconnue montre les formes qui existent" do
      erreur = assert_raise ArgumentError, fn -> Assembler.assemble([{:ld, :a, :bc}]) end

      assert erreur.message =~ "instruction inconnue"
      assert erreur.message =~ "{:ld, :a, :bc}"
      assert erreur.message =~ "élément #0"
      # Les formes suggérées viennent d'`Insn.label/1` — le même nom que le
      # tableau de bord affiche.
      assert erreur.message =~ "LD A, (BC)"
    end

    test "un mnémonique voisin est suggéré" do
      erreur = assert_raise ArgumentError, fn -> Assembler.assemble([{:lb, :a, 1}]) end

      assert erreur.message =~ "mnémonique inconnu"
      assert erreur.message =~ "Vouliez-vous dire :ld"
    end

    test "un opérande sans forme est désigné nommément" do
      erreur = assert_raise ArgumentError, fn -> Assembler.assemble([{:ld, :a, {:mem, :sp}}]) end

      assert erreur.message =~ "opérande de forme inconnue"
      assert erreur.message =~ "{:mem, :sp}"
    end

    test "une étiquette ne se glisse pas dans un immédiat 8 bits" do
      programme = [{:ld, :a, {:label, :ici}}, {:label, :ici}]

      erreur = assert_raise ArgumentError, fn -> Assembler.assemble(programme) end

      assert erreur.message =~ "étiquette là où LD attend un octet"
    end

    test "l'élément fautif est situé par son indice et son adresse" do
      programme = [{:nop}, {:nop}, {:ld, :a, 0x100}]

      erreur = assert_raise ArgumentError, fn -> Assembler.assemble(programme) end

      assert erreur.message =~ "élément #2 (0x0152)"
    end

    test "un élément qui n'est ni étiquette, ni octets, ni instruction" do
      assert_raise ArgumentError, fn -> Assembler.assemble([:nop]) end
      assert_raise ArgumentError, fn -> Assembler.assemble([{:bytes, ~c"abc"}]) end
      assert_raise ArgumentError, fn -> Assembler.assemble([{:label, "ici"}]) end
    end
  end

  describe "exécution sur l'oracle" do
    test "une addition et un rangement en mémoire" do
      programme = [
        {:ld, :a, 5},
        {:ld, :b, 3},
        {:add, :a, :b},
        {:ld, {:mem, 0xC000}, :a},
        {:label, :fin},
        {:jr, {:label, :fin}}
      ]

      {etat, mem} = executer(programme, 20)

      assert etat.a == 8
      assert Flat.read8(mem, 0xC000) == 8
      # Le JR sur lui-même : PC est revenu sur l'instruction, la ROM ne déborde
      # pas dans ce qui suit.
      assert etat.pc == 0x0150 + 8
    end

    test "une boucle conditionnelle multiplie par additions" do
      # 3 × 5, en décrémentant C jusqu'à ce que Z tombe. Le JR NZ saute en
      # arrière vers une étiquette : c'est le premier programme dont le sens
      # dépend d'une adresse que seul l'assembleur connaît.
      programme = [
        {:ld, :a, 0},
        {:ld, :b, 3},
        {:ld, :c, 5},
        {:label, :main_loop},
        {:add, :a, :b},
        {:dec, :c},
        {:jr, :nz, {:label, :main_loop}},
        {:ld, {:mem, 0xC000}, :a},
        {:label, :fin},
        {:jr, {:label, :fin}}
      ]

      {etat, mem} = executer(programme, 200)

      assert etat.a == 15
      assert etat.c == 0
      assert Flat.read8(mem, 0xC000) == 15
    end

    test "un CALL, un RET, et des données lues par étiquette" do
      programme = [
        {:ld, :sp, 0xDFFF},
        {:call, {:label, :charger}},
        {:ld, {:mem, 0xC000}, :a},
        {:label, :fin},
        {:jr, {:label, :fin}},
        {:label, :charger},
        {:ld, :a, {:mem, {:label, :donnee}}},
        {:ret},
        {:label, :donnee},
        {:bytes, <<0x5A>>}
      ]

      {etat, mem} = executer(programme, 50)

      assert etat.a == 0x5A
      assert Flat.read8(mem, 0xC000) == 0x5A
      # SP est revenu à sa valeur d'avant l'appel : le RET a bien dépilé.
      assert etat.sp == 0xDFFF
    end
  end

  # ── Reconstruction d'une source depuis la table ──────────────────────────────

  defp source(%Insn{} = insn) do
    operandes = Enum.map(insn.operands, &source_operande/1)
    arguments = if insn.condition, do: [insn.condition | operandes], else: operandes

    List.to_tuple([insn.mnemonic | arguments])
  end

  defp source_operande({:reg, registre}), do: registre
  defp source_operande({:pair, paire}), do: paire
  defp source_operande(:hl_ind), do: {:mem, :hl}
  defp source_operande({:ind, cible}), do: {:mem, cible}
  defp source_operande(:a16_ind), do: {:mem, @d16}
  defp source_operande(:a8_ind), do: {:high, @d8}
  defp source_operande(:c_ind), do: {:high, :c}
  defp source_operande({:imm, 8}), do: @d8
  defp source_operande({:imm, 16}), do: @d16
  defp source_operande({:rst, cible}), do: cible
  defp source_operande({:bit, numero}), do: numero

  defp attendu(%Insn{} = insn) do
    prefixe = if insn.prefix == :cb, do: <<0xCB>>, else: <<>>
    immediats = insn.operands |> Enum.map(&octets_attendus/1) |> IO.iodata_to_binary()

    prefixe <> <<insn.opcode>> <> immediats
  end

  defp octets_attendus({:imm, 8}), do: <<@d8>>
  defp octets_attendus(:a8_ind), do: <<@d8>>
  defp octets_attendus({:imm, 16}), do: <<@d16::16-little>>
  defp octets_attendus(:a16_ind), do: <<@d16::16-little>>
  defp octets_attendus(_encode_dans_l_opcode), do: <<>>

  # ── Le harnais d'exécution ───────────────────────────────────────────────────

  defp remplissage(n), do: :binary.copy(<<0x00>>, n)

  # La ROM assemblée, posée à son origine dans une mémoire plate, exécutée pas à
  # pas par l'oracle — le même `Atomboy.CPU.step/2` que les vecteurs
  # SingleStepTests valident.
  defp executer(programme, pas, origine \\ 0x0150) do
    octets = Assembler.assemble(programme, origin: origine)

    mem =
      Flat.new(
        for {octet, decalage} <- Enum.with_index(:binary.bin_to_list(octets)),
            do: {origine + decalage, octet}
      )

    Enum.reduce(1..pas, {%State{pc: origine}, mem}, fn _, {etat, mem} ->
      {etat, mem, _cycles} = Atomboy.CPU.step(etat, mem)
      {etat, mem}
    end)
  end
end
