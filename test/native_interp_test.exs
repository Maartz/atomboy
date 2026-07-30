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

  alias Atomboy.CPU.State
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
    test "les étapes 1, 3 et 4 couvrent les familles émises" do
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

      # 0x76 est HALT, pas un LD : le trou dans le bloc x=1.
      refute {nil, 0x76} in couverts, "HALT n'est pas un LD"
      # Le 16 bits, la pile et les sauts attendent les étapes 5 et 6.
      refute {nil, 0x01} in couverts, "LD BC, d16"
      refute {nil, 0x03} in couverts, "INC BC"
      refute {nil, 0xC5} in couverts, "PUSH BC"
      refute {nil, 0x18} in couverts, "JR e8"
      refute {nil, 0x08} in couverts, "LD (a16), SP"

      # 143 (étapes 1 et 3) + 7 LD r,(HL) + 7 LD (HL),r + 1 LD (HL),d8
      # + 8 ALU A,(HL) + 2 INC/DEC (HL) + 8 indirections par paire
      # + 4 page haute + 2 adressage absolu.
      assert MapSet.size(couverts) == 182
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

    test "PC reboucle à 0xFFFF sans déborder" do
      memoire = :binary.copy(<<0x00>>, 0x10000)

      resultat = Run.run!(memoire, %State{pc: 0xFFFE}, 12)

      assert resultat.statut == :ok
      assert resultat.state.pc == 1
    end
  end

  describe "l'équivalence croisée avec l'oracle" do
    for seed <- @seeds do
      test "programme aléatoire, graine #{seed}" do
        :rand.seed(:exsss, {unquote(seed), 0, 0})

        memoire = programme_aleatoire()
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

  # Un octet par adresse, tiré de ce que le natif sait émettre. Aucun n'étant un
  # saut, PC parcourt l'espace linéairement et reboucle — chaque tirage est un
  # programme valide de bout en bout.
  #
  # Depuis que les écritures mémoire existent, ces programmes s'auto-modifient :
  # sur les huit graines, six finissent par fabriquer un opcode hors couverture
  # devant PC et deux vont au bout des 5 000 pas. C'est le cas le plus dur que
  # le harnais puisse produire, et c'est gratuit.
  defp programme_aleatoire do
    opcodes = for {nil, op} <- Emit.couverture(), do: op

    0..0xFFFF
    |> Enum.map(fn _addr -> Enum.random(opcodes) end)
    |> :binary.list_to_bin()
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
    plate =
      Flat.new(
        for {byte, addr} <- Enum.with_index(:binary.bin_to_list(memoire)), do: {addr, byte}
      )

    boucle(state, plate, 0, steps, MapSet.new(for {nil, op} <- Emit.couverture(), do: op))
  end

  defp boucle(st, mem, cycles, 0, _couverts), do: {st, mem, cycles, nil}

  defp boucle(st, mem, cycles, steps, couverts) do
    opcode = Flat.read8(mem, st.pc)

    if MapSet.member?(couverts, opcode) do
      {st, mem, pas} = Atomboy.CPU.tick(st, mem)
      boucle(st, mem, cycles + pas, steps - 1, couverts)
    else
      {st, mem, cycles, opcode}
    end
  end
end
