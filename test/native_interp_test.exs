defmodule Atomboy.NativeInterpTest do
  @moduledoc """
  L'interpréteur natif contre l'oracle — la même méthode que `loop_test.exs`.

  `Atomboy.CPU.Loop` n'est pas validé par les vecteurs SM83 mais par héritage :
  l'oracle passe les vecteurs, et l'équivalence croisée sur programmes
  aléatoires prouve que la boucle rapide en est indiscernable. L'interpréteur
  RV32 est un troisième backend et se valide exactement pareil, à ceci près que
  l'écart à combler est plus large — un encodage d'instruction, un jeu de
  registres, un assembleur et un émulateur de processeur séparent les deux
  états qu'on compare.

  Les graines sont fixes : un échec est reproductible tel quel.
  """

  use ExUnit.Case, async: true

  alias Atomboy.CPU.Insn
  alias Atomboy.CPU.State
  alias Atomboy.CPU.Table
  alias Atomboy.Memory.Flat
  alias Atomboy.Native.Emit
  alias Atomboy.Native.Interp
  alias Atomboy.Native.Run

  @moduletag :qemu
  # Le harnais paie un lancement de qemu et un vidage de 64 Ko par exécution.
  @moduletag timeout: 120_000

  @steps 5_000
  @seeds 1..8

  describe "la couverture" do
    test "les étapes 1 et 3 à 7 ne laissent que les interruptions" do
      couverts = MapSet.new(Emit.couverture())

      assert {nil, 0x00} in couverts, "NOP"
      assert {nil, 0x41} in couverts, "LD B, C"
      assert {nil, 0x7F} in couverts, "LD A, A"
      assert {nil, 0x80} in couverts, "ADD A, B"
      assert {nil, 0xBF} in couverts, "CP A"
      assert {nil, 0xC6} in couverts, "ADD A, d8"
      assert {nil, 0x3C} in couverts, "INC A"
      assert {nil, 0x05} in couverts, "DEC B"
      assert {nil, 0x27} in couverts, "DAA"
      assert {nil, 0x3F} in couverts, "CCF"
      assert {nil, 0x3E} in couverts, "LD A, d8"
      assert {nil, 0x46} in couverts, "LD B, (HL)"
      assert {nil, 0x70} in couverts, "LD (HL), B"
      assert {nil, 0x86} in couverts, "ADD A, (HL)"
      assert {nil, 0x34} in couverts, "INC (HL)"
      assert {nil, 0x36} in couverts, "LD (HL), d8"
      assert {nil, 0x22} in couverts, "LD (HL+), A"
      assert {nil, 0x1A} in couverts, "LD A, (DE)"
      assert {nil, 0xE0} in couverts, "LDH (a8), A"
      assert {nil, 0xF2} in couverts, "LDH A, (C)"
      assert {nil, 0xEA} in couverts, "LD (a16), A"

      assert {nil, 0x01} in couverts, "LD BC, d16"
      assert {nil, 0x03} in couverts, "INC BC"
      assert {nil, 0x09} in couverts, "ADD HL, BC"
      assert {nil, 0xC5} in couverts, "PUSH BC"
      assert {nil, 0xF1} in couverts, "POP AF"
      assert {nil, 0xE8} in couverts, "ADD SP, r8"
      assert {nil, 0xF8} in couverts, "LD HL, SP+r8"
      assert {nil, 0xF9} in couverts, "LD SP, HL"
      assert {nil, 0x08} in couverts, "LD (a16), SP"
      assert {nil, 0xFF} in couverts, "RST 38H"

      assert {nil, 0x18} in couverts, "JR e8"
      assert {nil, 0x20} in couverts, "JR NZ, e8"
      assert {nil, 0xC3} in couverts, "JP a16"
      assert {nil, 0xE9} in couverts, "JP HL"
      assert {nil, 0xCA} in couverts, "JP Z, a16"
      assert {nil, 0xCD} in couverts, "CALL a16"
      assert {nil, 0xD4} in couverts, "CALL NC, a16"
      assert {nil, 0xC9} in couverts, "RET"
      assert {nil, 0xD8} in couverts, "RET C"

      assert {nil, 0xCB} in couverts, "le préfixe CB"
      assert {:cb, 0x00} in couverts, "RLC B"
      assert {:cb, 0x36} in couverts, "SWAP (HL)"
      assert {:cb, 0x7E} in couverts, "BIT 7, (HL)"
      assert {:cb, 0x86} in couverts, "RES 0, (HL)"
      assert {:cb, 0xFF} in couverts, "SET 7, A"

      # Il ne reste que ce qui parle aux interruptions — étape 8. RETI compris :
      # il pose IME, et l'invité refuse encore tout état où IME est armé.
      refute {nil, 0x76} in couverts, "HALT"
      refute {nil, 0xD9} in couverts, "RETI"
      refute {nil, 0xF3} in couverts, "DI"
      refute {nil, 0xFB} in couverts, "EI"

      # 239 (étapes 1 et 3 à 6) + STOP + les 256 du bloc étendu.
      assert length(Emit.couverture_table()) == 496
      assert length(Table.all()) - length(Emit.couverture_table()) == 4, "HALT, DI, EI, RETI"

      # Le préfixe s'ajoute au dispatchable sans être une entrée de table.
      assert MapSet.size(couverts) == 497
      assert Emit.prefixe_couvert?()
    end

    test "la correspondance mnémonique → primitive suit celle de Gen" do
      # `gen.ex:1490` fait la même traduction pour les deux backends Elixir.
      # Qu'elles divergent produirait du code natif qui appelle une routine
      # inexistante — ou pire, la mauvaise.
      exportees = MapSet.new(Enum.map(Atomboy.CPU.ALU.__info__(:functions), &elem(&1, 0)))

      for mnemonic <- [:add, :adc, :sub, :sbc, :and, :xor, :or, :cp] do
        routine = Emit.routine(mnemonic)

        assert routine in exportees,
               "#{mnemonic} vise #{routine}, que Atomboy.CPU.ALU n'exporte pas"
      end

      assert Emit.routine(:and) == :bit_and
      assert Emit.routine(:add) == :add
    end

    test "tout ce que le natif couvre, l'oracle le couvre aussi" do
      assert MapSet.subset?(MapSet.new(Emit.couverture()), MapSet.new(Atomboy.CPU.implemented()))
    end
  end

  describe "l'exécution" do
    test "une mémoire de NOP avance PC d'un cran par instruction" do
      memoire = :binary.copy(<<0x00>>, 0x10000)

      resultat = Run.run!(memoire, %State{}, 100)

      assert resultat.statut == :ok
      assert resultat.cycles == 100
      assert resultat.state.pc == 25
      assert resultat.memoire == memoire
    end

    test "un opcode hors couverture s'arrête net et se nomme" do
      # 0x76 : HALT, présent dans la table mais pas encore émis.
      memoire = :binary.copy(<<0x76>>, 0x10000)

      resultat = Run.run!(memoire, %State{}, 100)

      assert resultat.statut == :opcode_inconnu
      assert resultat.opcode == 0x76
    end

    test "un état avec IME armé est refusé plutôt que mal exécuté" do
      memoire = :binary.copy(<<0x00>>, 0x10000)

      resultat = Run.run!(memoire, %State{ime: 1}, 100)

      assert resultat.statut == :etat_non_supporte,
             "les interruptions arrivent à l'étape 8 — d'ici là, l'invité doit refuser"
    end

    test "POP AF jette les quatre bits bas du registre de drapeaux" do
      # Le seul endroit d'où une valeur arbitraire peut entrer dans F. Les
      # quatre bits bas n'existent pas sur le matériel, et `POP AF` doit les
      # perdre.
      #
      # Ce test est ici parce que l'équivalence croisée ne l'attrape pas : dans
      # un programme aléatoire, la première opération d'ALU venue réécrit F
      # entièrement, donc la pollution s'efface avant d'être observée. Vérifié
      # par mutation — retirer le masque laisse les huit graines vertes.
      memoire = programme(%{0x100 => 0xF1, 0x200 => 0xFF, 0x201 => 0x12})

      resultat = Run.run!(memoire, %State{pc: 0x100, sp: 0x200}, 12)

      assert resultat.statut == :ok
      assert resultat.state.a == 0x12
      assert resultat.state.f == 0xF0, "F vaut #{resultat.state.f}, les bits bas ont survécu"
      assert resultat.state.sp == 0x202
    end

    test "PUSH puis POP rendent la paire intacte, octet bas en premier" do
      # PUSH BC puis POP DE : DE doit valoir BC, et la pile porter l'octet bas
      # à l'adresse basse — l'ordre qu'attend le matériel.
      memoire = programme(%{0x100 => 0xC5, 0x101 => 0xD1})

      resultat = Run.run!(memoire, %State{pc: 0x100, sp: 0x200, b: 0xBE, c: 0xEF}, 28)

      assert resultat.statut == :ok
      assert {resultat.state.d, resultat.state.e} == {0xBE, 0xEF}
      assert resultat.state.sp == 0x200
      assert :binary.at(resultat.memoire, 0x1FE) == 0xEF, "octet bas à l'adresse basse"
      assert :binary.at(resultat.memoire, 0x1FF) == 0xBE
    end

    test "RST empile l'adresse de retour et saute à sa cible" do
      # RST 28H : l'opcode fait un octet, donc l'adresse empilée est celle qui
      # le suit.
      memoire = programme(%{0x100 => 0xEF})

      resultat = Run.run!(memoire, %State{pc: 0x100, sp: 0x200}, 16)

      assert resultat.statut == :ok
      assert resultat.state.pc == 0x28
      assert resultat.state.sp == 0x1FE
      assert :binary.at(resultat.memoire, 0x1FE) == 0x01
      assert :binary.at(resultat.memoire, 0x1FF) == 0x01
    end

    test "un branchement non pris consomme son opérande et coûte moins cher" do
      # JR NZ, +4 avec Z posé : l'offset est lu — donc PC avance de deux — mais
      # le saut n'a pas lieu, et l'instruction coûte 8 T au lieu de 12.
      memoire = programme(%{0x100 => 0x20, 0x101 => 0x04})

      resultat = Run.run!(memoire, %State{pc: 0x100, f: 0x80}, 8)

      assert resultat.statut == :ok
      assert resultat.state.pc == 0x102, "l'opérande doit être consommé même sans saut"
      assert resultat.cycles == 8
    end

    test "le même branchement, pris, saute et coûte plus cher" do
      memoire = programme(%{0x100 => 0x20, 0x101 => 0x04})

      resultat = Run.run!(memoire, %State{pc: 0x100, f: 0x00}, 12)

      assert resultat.statut == :ok
      assert resultat.state.pc == 0x106, "la cible est relative au PC qui suit l'opérande"
      assert resultat.cycles == 12
    end

    test "un offset de JR négatif recule" do
      # 0xFE vaut -2 : le saut revient sur l'opcode lui-même.
      memoire = programme(%{0x100 => 0x18, 0x101 => 0xFE})

      resultat = Run.run!(memoire, %State{pc: 0x100}, 12)

      assert resultat.state.pc == 0x100
    end

    test "CALL puis RET reviennent exactement où il faut" do
      # CALL 0x300, et à 0x300 un RET. L'adresse de retour est celle qui suit
      # les deux octets d'opérande.
      memoire = programme(%{0x100 => 0xCD, 0x101 => 0x00, 0x102 => 0x03, 0x300 => 0xC9})

      resultat = Run.run!(memoire, %State{pc: 0x100, sp: 0x200}, 40)

      assert resultat.statut == :ok
      assert resultat.state.pc == 0x103
      assert resultat.state.sp == 0x200, "la pile doit être rendue"
      assert resultat.cycles == 40, "24 pour le CALL, 16 pour le RET"
    end

    test "JP HL ne touche pas la mémoire" do
      memoire = programme(%{0x100 => 0xE9})

      resultat = Run.run!(memoire, %State{pc: 0x100, h: 0x12, l: 0x34}, 4)

      assert resultat.state.pc == 0x1234
      assert resultat.memoire == memoire
    end

    test "BIT n pèse bien le bit n, et lui seul" do
      # Même angle mort que `POP AF` : `BIT` n'écrit que F, donc la première
      # opération d'ALU venue efface son résultat avant qu'on l'observe. Vérifié
      # par mutation — décaler le numéro de bit d'un cran laisse l'équivalence
      # croisée entièrement verte, dans les deux familles.
      #
      # 0xAA vaut 10101010 : Z ne doit se lever que sur les bits pairs. C entre
      # à 1 et doit ressortir intact, H doit se poser.
      for n <- 0..7 do
        memoire = programme(%{0x100 => 0xCB, 0x101 => 0x40 + n * 8})

        resultat = Run.run!(memoire, %State{pc: 0x100, b: 0xAA, f: 0x10}, 8)

        zero = if rem(n, 2) == 0, do: 0x80, else: 0x00

        assert resultat.state.f == zero + 0x20 + 0x10,
               "BIT #{n}, B sur 0xAA : F vaut #{Atomboy.CPU.State.flag_string(resultat.state)}"

        assert resultat.state.b == 0xAA, "BIT ne doit pas écrire sa cible"
      end
    end

    test "PC reboucle à 0xFFFF sans déborder" do
      memoire = :binary.copy(<<0x00>>, 0x10000)

      resultat = Run.run!(memoire, %State{pc: 0xFFFE}, 12)

      assert resultat.statut == :ok
      assert resultat.state.pc == 1
    end
  end

  # Deux familles, parce qu'elles ne prouvent pas la même chose.
  #
  # Les programmes **linéaires** excluent tout ce qui détourne PC : l'exécution
  # balaie alors l'espace d'adressage de bout en bout et chaque opcode émis
  # passe des dizaines de fois. C'est la famille qui donne la *largeur*.
  #
  # Les programmes **avec sauts** prennent toute la table. Mesuré : ils ne
  # visitent que 37 à 290 adresses distinctes sur 65 536, parce qu'un `JR -2`
  # suffit à enfermer PC dans une boucle. Ils ne prouvent donc presque rien sur
  # la largeur — mais ils sont les seuls à exercer les branchements, la pile en
  # usage réel et l'auto-modification. C'est la famille qui donne la
  # *profondeur*.
  #
  # Croire que la seconde suffisait était une erreur : « 40 000 instructions »
  # se lit comme une couverture, et n'en est pas une.
  describe "l'équivalence croisée — programmes linéaires" do
    for seed <- @seeds do
      test "programme linéaire, graine #{seed}" do
        :rand.seed(:exsss, {unquote(seed), 0, 0})

        memoire = programme_aleatoire(opcodes_lineaires())
        state = etat_aleatoire()

        {attendu, memoire_oracle, budget, fautif} = oracle(memoire, state, @steps)

        resultat = Run.run!(memoire, state, budget)

        assert resultat.statut == :ok
        assert resultat.cycles == budget
        assert resultat.state == attendu

        divergences =
          for addr <- 0..0xFFFF,
              octet_oracle = Flat.read8(memoire_oracle, addr),
              octet_natif = :binary.at(resultat.memoire, addr),
              octet_oracle != octet_natif,
              do: {addr, octet_oracle, octet_natif}

        assert divergences == []

        # Les programmes s'auto-modifient — `LD (HL), r` écrit parfois sur le
        # chemin de PC — et fabriquent alors des opcodes que le natif ne sait
        # pas encore émettre. L'équivalence porte sur le préfixe sain ; un
        # cycle de plus doit faire échouer le natif sur *cet* opcode-là.
        if fautif do
          suite = Run.run!(memoire, state, budget + 1)

          assert suite.statut == :opcode_inconnu
          assert suite.opcode == fautif
        end
      end
    end

    test "un programme linéaire traverse effectivement toute la table" do
      # Sans cette mesure, la famille linéaire pourrait se rétrécir sans qu'on
      # le voie — c'est exactement ce qui était arrivé à l'autre.
      :rand.seed(:exsss, {1, 0, 0})
      memoire = programme_aleatoire(opcodes_lineaires())
      {_, _, _, _, vus} = trace(memoire, etat_aleatoire(), @steps)

      assert MapSet.size(vus) > 200,
             "seulement #{MapSet.size(vus)} opcodes distincts exécutés sur #{length(opcodes_lineaires())}"
    end
  end

  describe "l'équivalence croisée — programmes avec sauts" do
    for seed <- @seeds do
      test "programme avec sauts, graine #{seed}" do
        :rand.seed(:exsss, {unquote(seed), 0, 0})

        memoire = programme_aleatoire(opcodes_complets())
        state = etat_aleatoire()

        {attendu, memoire_oracle, budget, fautif} = oracle(memoire, state, @steps)

        resultat = Run.run!(memoire, state, budget)

        assert resultat.statut == :ok
        assert resultat.cycles == budget
        assert resultat.state == attendu

        divergences =
          for addr <- 0..0xFFFF,
              octet_oracle = Flat.read8(memoire_oracle, addr),
              octet_natif = :binary.at(resultat.memoire, addr),
              octet_oracle != octet_natif,
              do: {addr, octet_oracle, octet_natif}

        assert divergences == []

        if fautif do
          suite = Run.run!(memoire, state, budget + 1)

          assert suite.statut == :opcode_inconnu
          assert suite.opcode == fautif
        end
      end
    end
  end

  describe "la taille du code" do
    test "l'interpréteur reste très en deçà de l'icache du C6" do
      memoire = :binary.copy(<<0x00>>, 0x10000)
      image = Interp.image(memoire, %State{}, 1)

      # `table_base` ouvre la section de données : tout ce qui précède est du
      # code. C'est ce chiffre-là qui devra tenir dans 32 Ko une fois les 501
      # opcodes émis.
      code = image.labels[:table_base]

      assert code < 32 * 1024,
             "le code fait #{code} octets — l'icache du C6 en fait 32 768"
    end
  end

  # ══ Génération ═══════════════════════════════════════════════════════════════

  # Une mémoire de 64 Ko remplie de HALT — un opcode que le natif n'émet pas —
  # avec quelques octets posés là où on les veut. Le remplissage sert de garde :
  # si l'exécution déborde du programme voulu, elle s'arrête et le dit, au lieu
  # de courir dans du bruit.
  defp programme(octets) do
    for addr <- 0..0xFFFF, into: <<>>, do: <<Map.get(octets, addr, 0x76)>>
  end

  # Un octet par adresse, tiré du vivier donné — chaque tirage est donc un
  # programme valide de bout en bout, qui s'auto-modifie, empile et dépile.
  defp programme_aleatoire(opcodes) do
    0..0xFFFF
    |> Enum.map(fn _addr -> Enum.random(opcodes) end)
    |> :binary.list_to_bin()
  end

  # Tout ce que le natif dispatche depuis un octet d'opcode, préfixe CB compris.
  defp opcodes_complets, do: for({nil, op} <- Emit.couverture(), do: op)

  # Le même vivier privé de tout ce qui détourne PC. L'exécution avance alors
  # d'une instruction à la suivante et fait le tour des 64 Ko, ce qui est la
  # seule façon d'exercer chaque opcode émis un grand nombre de fois.
  defp opcodes_lineaires do
    sauts =
      for %Insn{prefix: nil, mnemonic: m, opcode: op} <- Table.base(),
          m in [:jr, :jp, :call, :ret, :rst],
          do: op

    opcodes_complets() -- sauts
  end

  defp etat_aleatoire do
    %State{
      a: :rand.uniform(256) - 1,
      # F : quatre bits hauts seulement, comme le matériel.
      f: (:rand.uniform(16) - 1) * 16,
      b: :rand.uniform(256) - 1,
      c: :rand.uniform(256) - 1,
      d: :rand.uniform(256) - 1,
      e: :rand.uniform(256) - 1,
      h: :rand.uniform(256) - 1,
      l: :rand.uniform(256) - 1,
      sp: :rand.uniform(0x10000) - 1,
      pc: :rand.uniform(0x10000) - 1
    }
  end

  # N pas d'oracle sur une mémoire plate initialisée depuis le programme. Rend
  # `{état, mémoire, budget_en_cycles, opcode_fautif | nil}`.
  #
  # Le budget est la somme exacte des cycles de ces pas : si le natif comptait
  # autrement, il exécuterait un nombre différent d'instructions et les états
  # divergeraient. L'oracle s'arrête de lui-même dès que PC désigne un opcode
  # hors de ce que le natif sait émettre — sinon il continuerait seul, et la
  # divergence dirait « le natif s'est arrêté » plutôt que « le natif s'est
  # trompé », ce qui est une tout autre information.
  defp oracle(memoire, state, steps) do
    {st, mem, cycles, fautif, _vus} = trace(memoire, state, steps)
    {st, mem, cycles, fautif}
  end

  # La même chose, plus l'ensemble des opcodes réellement exécutés — ce qui
  # permet de mesurer la largeur d'une famille de programmes au lieu de la
  # supposer.
  defp trace(memoire, state, steps) do
    plate =
      Flat.new(
        for {byte, addr} <- Enum.with_index(:binary.bin_to_list(memoire)), do: {addr, byte}
      )

    boucle(state, plate, 0, steps, MapSet.new(opcodes_complets()), MapSet.new())
  end

  defp boucle(st, mem, cycles, 0, _couverts, vus), do: {st, mem, cycles, nil, vus}

  defp boucle(st, mem, cycles, steps, couverts, vus) do
    opcode = Flat.read8(mem, st.pc)

    if MapSet.member?(couverts, opcode) do
      {suite, mem, pas} = Atomboy.CPU.tick(st, mem)
      boucle(suite, mem, cycles + pas, steps - 1, couverts, MapSet.put(vus, opcode))
    else
      {st, mem, cycles, opcode, vus}
    end
  end
end
