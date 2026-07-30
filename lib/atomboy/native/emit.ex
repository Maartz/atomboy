defmodule Atomboy.Native.Emit do
  @moduledoc """
  Le troisième backend : un `%Insn{}` devient des instructions RISC-V.

  `Atomboy.CPU.Gen` en a deux — l'oracle à struct et la boucle rapide — qui
  produisent tous deux de l'AST Elixir. Celui-ci produit des octets. Les trois
  filtrent sur les mêmes motifs de `%Atomboy.CPU.Insn{}`, lus dans la même
  table, et c'est là que tient la propriété qui compte : une famille d'opérandes
  n'est décrite qu'une fois.

  ## Pourquoi ce module n'est pas une troisième famille dans `gen.ex`

  `gen.ex` fait déjà 1500 lignes pour deux émetteurs qui rendent de l'AST. Un
  troisième, dont les corps sont trois à cinq fois plus longs et rendent des
  binaires, en ferait un fichier que personne ne relit. Ce qui garantit qu'aucun
  backend ne rate une famille n'est de toute façon pas la proximité dans un
  fichier : c'est que les trois filtrent sur les mêmes têtes de clause, et que
  `couverture/0` dit lesquelles manquent encore ici.

  L'ordre des clauses de ce module recopie délibérément celui de `gen.ex`. Une
  divergence d'ordre est une divergence de sémantique quand deux motifs se
  chevauchent.

  ## Ce qui est couvert aujourd'hui

  239 des 500 instructions, en quatre vagues : les transferts entre registres et
  l'arithmétique 8 bits, puis tout ce qui touche le bus — la colonne `(HL)`, les
  indirections par paire, la page haute, l'adressage absolu — puis le 16 bits,
  la pile et `RST`, et enfin le contrôle de flux avec ses formes
  conditionnelles.

  Ce qui manque : le bloc `CB` tout entier, et les instructions qui parlent aux
  interruptions — `EI`, `DI`, `HALT`, et `RETI`, qui est un `RET` posant IME et
  attend donc que l'invité sache exécuter un état où IME est armé. Elles tombent
  dans `:non_supporté`, et le dispatch y envoie `opcode_inconnu` — un
  interpréteur partiel doit dire lequel, pas rendre un résultat faux.
  """

  import Bitwise

  alias Atomboy.CPU.Insn
  alias Atomboy.CPU.Table
  alias Atomboy.Native.ALU
  alias Atomboy.Native.Asm
  alias Atomboy.Native.Bus
  alias Atomboy.Native.RV32
  alias Atomboy.Native.Regs

  # Le mnémonique de la table n'est pas le nom de la primitive : `AND`, `OR` et
  # `XOR` sont des formes spéciales d'Elixir, donc `Atomboy.CPU.ALU` les nomme
  # `bit_and`, `bit_or`, `bit_xor`. La correspondance est celle de
  # `Atomboy.CPU.Gen.alu_call/4` (gen.ex:1490) — un test vérifie qu'elles ne
  # divergent pas.
  @routine %{
    add: :add,
    adc: :adc,
    sub: :sub,
    sbc: :sbc,
    and: :bit_and,
    xor: :bit_xor,
    or: :bit_or,
    cp: :cp
  }

  @alu Map.keys(@routine)
  @accumulateur [:rlca, :rrca, :rla, :rra, :daa, :cpl, :scf, :ccf]

  @ime Regs.controle().ime
  @halted Regs.controle().halted
  @pending Regs.controle().pending

  # Les jumelles CB des rotations de l'accumulateur. Elles posent Z normalement
  # là où `RLCA` et compagnie l'effacent toujours — deux encodages, deux
  # sémantiques de Z, et une source classique de bugs.
  @rotations [:rlc, :rrc, :rl, :rr, :sla, :sra, :swap, :srl]

  @doc "L'opcode qui introduit la table étendue."
  @spec prefixe_cb() :: 0xCB
  def prefixe_cb, do: 0xCB

  @doc "La primitive d'ALU que sert un mnémonique de la table."
  @spec routine(atom()) :: atom()
  def routine(mnemonic), do: Map.fetch!(@routine, mnemonic)

  @doc """
  Le corps d'un gestionnaire d'opcode, ou `:non_supporté`.

  Le corps se termine toujours par la comptabilisation des cycles et un saut
  vers `fetch` — l'équivalent natif de l'appel terminal de `Gen.loop_ret/3`.
  """
  @spec body(Insn.t()) :: [Asm.item()] | :non_supporté

  # NOP — l'instruction qui ne fait que passer du temps.
  def body(%Insn{mnemonic: :nop, cycles: cycles}), do: fin(cycles)

  # STOP — un octet et rien d'autre : l'arrêt effectif attend un contrôleur
  # d'horloge que l'émulateur n'a pas, et le corpus SingleStepTests le modélise
  # ainsi. C'est le choix de la table (table.ex:104), donc l'oracle le fait
  # aussi, donc l'équivalence tient.
  def body(%Insn{mnemonic: :stop, cycles: cycles}), do: fin(cycles)

  # LD r, r' — la moitié de la table, et la seule famille sans aucun effet de
  # bord. `LD B, B` s'émet comme les autres : élider serait une optimisation, et
  # les optimisations viennent après la mesure.
  def body(%Insn{mnemonic: :ld, operands: [{:reg, dst}, {:reg, src}], cycles: cycles}) do
    Regs.read8({:reg, src}, :t0) ++ Regs.write8({:reg, dst}, :t0) ++ fin(cycles)
  end

  # LD r, d8 — le premier opérande immédiat, donc le premier avancement de PC
  # au-delà du fetch d'opcode.
  def body(%Insn{mnemonic: :ld, operands: [{:reg, dst}, {:imm, 8}], cycles: cycles}) do
    lire_immediat(:t0) ++ Regs.write8({:reg, dst}, :t0) ++ fin(cycles)
  end

  # ALU A, r — les 56 cases du bloc x=2 hors colonne (HL). A et F voyagent dans
  # leurs registres dédiés, la routine les lit et les réécrit sur place ; seul
  # l'opérande a besoin d'être chargé.
  def body(%Insn{mnemonic: m, operands: [{:reg, :a}, {:reg, src}], cycles: cycles})
      when m in @alu do
    Regs.read8({:reg, src}, :a0) ++ [Asm.call(ALU.etiquette(@routine[m]))] ++ fin(cycles)
  end

  def body(%Insn{mnemonic: m, operands: [{:reg, :a}, {:imm, 8}], cycles: cycles})
      when m in @alu do
    lire_immediat(:a0) ++ [Asm.call(ALU.etiquette(@routine[m]))] ++ fin(cycles)
  end

  # INC r et DEC r — les seules opérations d'ALU qui écrivent ailleurs que dans
  # A, d'où l'aller-retour par a0.
  def body(%Insn{mnemonic: m, operands: [{:reg, cible}], cycles: cycles})
      when m in [:inc, :dec] do
    Regs.read8({:reg, cible}, :a0) ++
      [Asm.call(ALU.etiquette(m))] ++
      Regs.write8({:reg, cible}, :a0) ++ fin(cycles)
  end

  # La colonne z=7 : huit opérations sur le seul accumulateur, sans opérande.
  def body(%Insn{mnemonic: m, operands: [], cycles: cycles}) when m in @accumulateur do
    [Asm.call(ALU.etiquette(m))] ++ fin(cycles)
  end

  # ── Les opérandes mémoire ───────────────────────────────────────────────────
  #
  # `(HL)` est l'encodage `r = 6` : il traverse les mêmes familles que les sept
  # registres, d'où des clauses jumelles de celles ci-dessus, à l'accès près.

  def body(%Insn{mnemonic: :ld, operands: [{:reg, dst}, :hl_ind], cycles: cycles}) do
    Bus.lire(Regs.hl(), :t0) ++ Regs.write8({:reg, dst}, :t0) ++ fin(cycles)
  end

  def body(%Insn{mnemonic: :ld, operands: [:hl_ind, {:reg, src}], cycles: cycles}) do
    Regs.read8({:reg, src}, :t0) ++ Bus.ecrire(Regs.hl(), :t0) ++ fin(cycles)
  end

  def body(%Insn{mnemonic: :ld, operands: [:hl_ind, {:imm, 8}], cycles: cycles}) do
    lire_immediat(:t0) ++ Bus.ecrire(Regs.hl(), :t0) ++ fin(cycles)
  end

  def body(%Insn{mnemonic: m, operands: [{:reg, :a}, :hl_ind], cycles: cycles})
      when m in @alu do
    Bus.lire(Regs.hl(), :a0) ++ [Asm.call(ALU.etiquette(@routine[m]))] ++ fin(cycles)
  end

  # INC (HL) et DEC (HL) — le lu-modifié-écrit, la seule forme de la table qui
  # touche deux fois la même adresse.
  def body(%Insn{mnemonic: m, operands: [:hl_ind], cycles: cycles}) when m in [:inc, :dec] do
    Bus.lire(Regs.hl(), :a0) ++
      [Asm.call(ALU.etiquette(m))] ++
      Bus.ecrire(Regs.hl(), :a0) ++ fin(cycles)
  end

  # LD A, (BC/DE/HL+/HL-) et les écritures symétriques. L'ajustement de HL suit
  # l'accès : l'adresse est celle d'avant l'incrément.
  def body(%Insn{mnemonic: :ld, operands: [{:reg, :a}, {:ind, _} = source], cycles: cycles}) do
    Bus.adresse(source, :t0) ++
      Bus.lire(:t0, Regs.a()) ++
      Bus.ajuster(source) ++ fin(cycles)
  end

  def body(%Insn{mnemonic: :ld, operands: [{:ind, _} = cible, {:reg, :a}], cycles: cycles}) do
    Bus.adresse(cible, :t0) ++
      Bus.ecrire(:t0, Regs.a()) ++
      Bus.ajuster(cible) ++ fin(cycles)
  end

  # La page haute — les registres d'entrée-sortie, adressés sur un octet.
  def body(%Insn{mnemonic: :ldh, operands: [{:reg, :a}, :a8_ind], cycles: cycles}) do
    lire_immediat(:t0) ++
      Bus.page_haute(:t0, :t0) ++
      Bus.lire(:t0, Regs.a()) ++ fin(cycles)
  end

  def body(%Insn{mnemonic: :ldh, operands: [:a8_ind, {:reg, :a}], cycles: cycles}) do
    lire_immediat(:t0) ++
      Bus.page_haute(:t0, :t0) ++
      Bus.ecrire(:t0, Regs.a()) ++ fin(cycles)
  end

  def body(%Insn{mnemonic: :ldh, operands: [{:reg, :a}, :c_ind], cycles: cycles}) do
    Bus.page_haute(Regs.c(), :t0) ++ Bus.lire(:t0, Regs.a()) ++ fin(cycles)
  end

  def body(%Insn{mnemonic: :ldh, operands: [:c_ind, {:reg, :a}], cycles: cycles}) do
    Bus.page_haute(Regs.c(), :t0) ++ Bus.ecrire(:t0, Regs.a()) ++ fin(cycles)
  end

  # L'adressage absolu — le seul opérande de deux octets de cette étape.
  def body(%Insn{mnemonic: :ld, operands: [{:reg, :a}, :a16_ind], cycles: cycles}) do
    lire_immediat16(:t0) ++ Bus.lire(:t0, Regs.a()) ++ fin(cycles)
  end

  def body(%Insn{mnemonic: :ld, operands: [:a16_ind, {:reg, :a}], cycles: cycles}) do
    lire_immediat16(:t0) ++ Bus.ecrire(:t0, Regs.a()) ++ fin(cycles)
  end

  # ── Seize bits et pile ──────────────────────────────────────────────────────

  def body(%Insn{mnemonic: :ld, operands: [{:pair, _} = paire, {:imm, 16}], cycles: cycles}) do
    lire_immediat16(:t0) ++ Regs.write16(paire, :t0) ++ fin(cycles)
  end

  # LD SP, HL — la seule copie de paire à paire du jeu d'instructions.
  def body(%Insn{mnemonic: :ld, operands: [{:pair, _} = dst, {:pair, _} = src], cycles: cycles}) do
    Regs.read16(src, :t0) ++ Regs.write16(dst, :t0) ++ fin(cycles)
  end

  # INC rr et DEC rr — **aucun drapeau touché**, contrairement à leurs homonymes
  # 8 bits. C'est le matériel qui veut ça, et c'est pourquoi ils ne passent pas
  # par l'ALU.
  def body(%Insn{mnemonic: m, operands: [{:pair, _} = paire], cycles: cycles})
      when m in [:inc, :dec] do
    Regs.read16(paire, :t0) ++
      [
        RV32.addi(:t0, :t0, if(m == :inc, do: 1, else: -1)),
        RV32.and_(:t0, :t0, Regs.mask16())
      ] ++ Regs.write16(paire, :t0) ++ fin(cycles)
  end

  # ADD HL, rr — HL vit déjà dans le registre que la routine attend.
  def body(%Insn{mnemonic: :add, operands: [{:pair, :hl}, {:pair, _} = src], cycles: cycles}) do
    Regs.read16(src, :a0) ++ [Asm.call(ALU.etiquette(:add16))] ++ fin(cycles)
  end

  # ADD SP, r8 et LD HL, SP+r8 — même arithmétique, deux destinations.
  def body(%Insn{mnemonic: :add_sp, operands: [{:pair, dst}, {:imm, 8}], cycles: cycles}) do
    Regs.read16({:pair, :sp}, :a0) ++
      lire_immediat(:a1) ++
      [Asm.call(ALU.etiquette(:add_sp))] ++
      Regs.write16({:pair, dst}, :a0) ++ fin(cycles)
  end

  # LD (a16), SP — l'unique écriture 16 bits directe du jeu d'instructions.
  def body(%Insn{mnemonic: :ld, operands: [:a16_ind, {:pair, :sp}], cycles: cycles}) do
    lire_immediat16(:t0) ++ Bus.ecrire16(:t0, Regs.sp()) ++ fin(cycles)
  end

  # PUSH — SP recule de deux, puis le mot s'écrit à la nouvelle adresse.
  def body(%Insn{mnemonic: :push, operands: [{:pair, _} = paire], cycles: cycles}) do
    Regs.read16(paire, :t0) ++
      Bus.deplacer_pile(-2) ++
      Bus.ecrire16(Regs.sp(), :t0) ++ fin(cycles)
  end

  def body(%Insn{mnemonic: :pop, operands: [{:pair, _} = paire], cycles: cycles}) do
    Bus.lire16(Regs.sp(), :t0) ++
      Bus.deplacer_pile(2) ++
      Regs.write16(paire, :t0) ++ fin(cycles)
  end

  # RST — un appel dont la cible est cuite dans l'opcode. PC a déjà avancé
  # d'un cran au fetch, donc c'est bien l'adresse de retour qui part sur la pile.
  def body(%Insn{mnemonic: :rst, operands: [{:rst, cible}], cycles: cycles}) do
    Bus.deplacer_pile(-2) ++
      Bus.ecrire16(Regs.sp(), Regs.pc()) ++
      RV32.li(Regs.pc(), cible) ++ fin(cycles)
  end

  # ── Le contrôle de flux ─────────────────────────────────────────────────────
  #
  # Toutes ces familles partagent une forme : lire les opérandes — ce que le
  # processeur fait dans les deux cas —, puis, si la condition tient, agir sur
  # PC. Le coût en cycles diffère entre les deux branches, et c'est la table qui
  # le porte (`cycles` et `cycles_untaken`).

  # JR — offset signé d'un octet, relatif au PC qui suit l'opérande. Le calcul
  # du signe est sans branche : retrancher 256 quand le bit 7 est levé. C'est le
  # même geste que dans `Gen` (gen.ex:100), pour la même raison.
  def body(%Insn{mnemonic: :jr, operands: [{:imm, 8}]} = insn) do
    conditionnel(insn, lire_immediat(:t0), [
      RV32.srli(:t2, :t0, 7),
      RV32.slli(:t2, :t2, 8),
      RV32.sub(:t2, :t0, :t2),
      RV32.add(Regs.pc(), Regs.pc(), :t2),
      RV32.and_(Regs.pc(), Regs.pc(), Regs.mask16())
    ])
  end

  def body(%Insn{mnemonic: :jp, operands: [{:imm, 16}]} = insn) do
    conditionnel(insn, lire_immediat16(:t0), [RV32.mv(Regs.pc(), :t0)])
  end

  # JP HL — souvent écrit « JP (HL) », mais il n'y a aucun accès mémoire : PC
  # reçoit la paire, c'est tout. Une instruction, et le seul saut calculé du jeu.
  def body(%Insn{mnemonic: :jp, operands: [{:pair, :hl}], cycles: cycles}) do
    [RV32.mv(Regs.pc(), Regs.hl())] ++ fin(cycles)
  end

  # CALL — l'adresse empilée est celle qui suit les deux octets d'opérande, donc
  # PC est déjà à sa valeur finale quand il part sur la pile.
  def body(%Insn{mnemonic: :call, operands: [{:imm, 16}]} = insn) do
    conditionnel(
      insn,
      lire_immediat16(:t0),
      Bus.deplacer_pile(-2) ++
        Bus.ecrire16(Regs.sp(), Regs.pc()) ++
        [RV32.mv(Regs.pc(), :t0)]
    )
  end

  # RET, RET cc et RETI — la lecture de pile n'a lieu que si le retour se fait,
  # et RETI rallume IME dans le même souffle. Immédiatement, contrairement à
  # `EI` : l'instruction existe pour sortir d'un gestionnaire d'interruption,
  # et un délai d'une instruction y serait un piège.
  def body(%Insn{mnemonic: m} = insn) when m in [:ret, :reti] do
    reprise =
      if m == :reti, do: [RV32.ori(Regs.control(), Regs.control(), @ime)], else: []

    conditionnel(
      insn,
      [],
      Bus.lire16(Regs.sp(), :t0) ++
        Bus.deplacer_pile(2) ++
        [RV32.mv(Regs.pc(), :t0)] ++ reprise
    )
  end

  # ── Les interruptions ───────────────────────────────────────────────────────
  #
  # Trois instructions qui ne font que poser des bits dans le registre de
  # contrôle. Tout le travail est dans `fetch`, où ces bits se lisent — c'est
  # aussi ainsi que `Atomboy.CPU.Loop` est bâti.

  # DI éteint IME **et désarme un EI en attente** : sans cela, un `EI` suivi
  # d'un `DI` autoriserait quand même les interruptions un pas plus tard.
  def body(%Insn{mnemonic: :di, cycles: cycles}) do
    [RV32.andi(Regs.control(), Regs.control(), bnot(@ime ||| @pending))] ++ fin(cycles)
  end

  # EI n'autorise pas : il arme. La promotion se fait au pas suivant, dans le
  # `fetch` — même point que dans les deux backends Elixir.
  def body(%Insn{mnemonic: :ei, cycles: cycles}) do
    [RV32.ori(Regs.control(), Regs.control(), @pending)] ++ fin(cycles)
  end

  def body(%Insn{mnemonic: :halt, cycles: cycles}) do
    [RV32.ori(Regs.control(), Regs.control(), @halted)] ++ fin(cycles)
  end

  # ── Le bloc CB ──────────────────────────────────────────────────────────────
  #
  # 256 opcodes, et la partie la plus régulière de la table : huit rotations sur
  # huit cibles, puis BIT, RES et SET dont le numéro de bit est encodé dans
  # l'opcode. Trois clauses suffisent, parce que `(HL)` n'est ici qu'une cible
  # parmi huit — la même abstraction que l'encodage `r = 6` du matériel.

  def body(%Insn{prefix: :cb, mnemonic: m, operands: [cible], cycles: cycles})
      when m in @rotations do
    lire_cible(cible, :a0) ++
      [Asm.call(ALU.etiquette(m))] ++
      ecrire_cible(cible, :a0) ++ fin(cycles)
  end

  # BIT n — ne fait que peser un bit : la cible n'est pas réécrite, et c'est
  # pourquoi sa forme `(HL)` coûte 12 T là où RES et SET en coûtent 16.
  def body(%Insn{prefix: :cb, mnemonic: :bit, operands: [{:bit, n}, cible], cycles: cycles}) do
    lire_cible(cible, :a0) ++ [Asm.call(ALU.etiquette_bit(n))] ++ fin(cycles)
  end

  # RES et SET — un masque, et aucun drapeau. `Gen` les inline pour la même
  # raison : il n'y a aucune subtilité à centraliser.
  def body(%Insn{prefix: :cb, mnemonic: m, operands: [{:bit, n}, cible], cycles: cycles})
      when m in [:res, :set] do
    masque =
      case m do
        :res -> RV32.andi(:t0, :t0, bxor(1 <<< n, 0xFF))
        :set -> RV32.ori(:t0, :t0, 1 <<< n)
      end

    lire_cible(cible, :t0) ++ [masque] ++ ecrire_cible(cible, :t0) ++ fin(cycles)
  end

  def body(%Insn{}), do: :non_supporté

  # Une cible du bloc CB : sept registres et `(HL)`, indifféremment.
  defp lire_cible(:hl_ind, dest), do: Bus.lire(Regs.hl(), dest)
  defp lire_cible({:reg, _} = reg, dest), do: Regs.read8(reg, dest)

  defp ecrire_cible(:hl_ind, src), do: Bus.ecrire(Regs.hl(), src)
  defp ecrire_cible({:reg, _} = reg, src), do: Regs.write8(reg, src)

  # Le squelette commun : le prélude s'exécute toujours, l'action seulement si
  # la condition tient. La branche non prise saute vers `fetch` avant
  # l'étiquette, donc les deux chemins ne se croisent jamais.
  defp conditionnel(%Insn{condition: nil} = insn, prelude, action) do
    prelude ++ action ++ fin(insn.cycles)
  end

  defp conditionnel(%Insn{} = insn, prelude, action) do
    pris = :"pris_#{Integer.to_string(insn.opcode, 16)}"

    prelude ++
      saut_si(insn.condition, pris) ++
      fin(insn.cycles_untaken) ++
      [Asm.label(pris)] ++ action ++ fin(insn.cycles)
  end

  # Z est le bit 7, C le bit 4 ; `NZ` et `NC` branchent sur l'absence.
  @condition %{nz: {0x80, :absent}, z: {0x80, :present}, nc: {0x10, :absent}, c: {0x10, :present}}

  defp saut_si(condition, etiquette) do
    {masque, sens} = Map.fetch!(@condition, condition)
    branchement = if sens == :absent, do: &Asm.beqz/2, else: &Asm.bnez/2

    [RV32.andi(:t1, Regs.f(), masque), branchement.(:t1, etiquette)]
  end

  @doc """
  Charge l'octet immédiat qui suit l'opcode, et avance PC.

  `t1` sert d'adresse le temps de la lecture, pour que `dest` puisse être
  n'importe quel autre registre de travail — `t0` comme `a0`.
  """
  @spec lire_immediat(RV32.reg()) :: [Asm.item()]
  def lire_immediat(dest) do
    [
      RV32.add(:t1, Regs.mem(), Regs.pc()),
      RV32.lbu(dest, :t1, 0),
      RV32.addi(Regs.pc(), Regs.pc(), 1),
      RV32.and_(Regs.pc(), Regs.pc(), Regs.mask16())
    ]
  end

  @doc """
  Charge le mot immédiat de deux octets qui suit l'opcode, petit-boutien.

  Deux lectures d'un octet plutôt qu'une lecture de deux : le second octet est
  à `PC + 1` **replié sur 16 bits**, et un opcode posé à `0xFFFF` prend donc son
  opérande haut à l'adresse `0`. Un `lhu` à `mem + PC` lirait un octet hors des
  64 Ko.
  """
  @spec lire_immediat16(RV32.reg()) :: [Asm.item()]
  def lire_immediat16(dest) do
    lire_immediat(dest) ++
      lire_immediat(:t2) ++
      [
        RV32.slli(:t2, :t2, 8),
        RV32.or_(dest, dest, :t2)
      ]
  end

  @doc """
  La fin de tout gestionnaire : les cycles, puis le fetch suivant.

  Tous les coûts de la table valent 24 T ou moins, donc l'immédiat d'`addi` les
  accepte sans détour.
  """
  @spec fin(pos_integer()) :: [Asm.item()]
  def fin(cycles) do
    [RV32.addi(Regs.cycles(), Regs.cycles(), cycles), Asm.j(:fetch)]
  end

  @doc """
  Les instructions que ce backend sait émettre, par `{préfixe, opcode}`.

  Même forme que `Atomboy.CPU.implemented/0`, pour que les tests puissent
  restreindre un programme aléatoire à ce qui est couvert des deux côtés.
  """
  @spec couverture() :: [{nil | :cb, 0..0xFF}]
  def couverture do
    # `0xCB` n'est pas une instruction : c'est un préfixe, et il n'a donc pas
    # d'entrée dans la table. Il rejoint l'ensemble dispatchable dès que le bloc
    # étendu est entièrement émis — sauter dans une table à trous serait pire
    # que ne pas sauter du tout.
    if prefixe_couvert?() do
      [{nil, prefixe_cb()} | couverture_table()]
    else
      couverture_table()
    end
  end

  @doc """
  Les seules entrées de la table qui sont émises — sans le préfixe.

  C'est ce nombre-là qui se compare aux 500 instructions décrites, et le
  distinguer de `couverture/0` évite un tableau de bord qui compte 496 sur 500
  en ayant ajouté quelque chose qui n'est pas dans les 500.
  """
  @spec couverture_table() :: [{nil | :cb, 0..0xFF}]
  def couverture_table do
    for insn <- Table.all(), body(insn) != :non_supporté, do: {insn.prefix, insn.opcode}
  end

  @doc "Le bloc étendu est-il émis en entier ?"
  @spec prefixe_couvert?() :: boolean()
  def prefixe_couvert?, do: Enum.count(couverture_table(), &match?({:cb, _}, &1)) == 256

  @doc "Les instructions encore à faire — le tableau de bord du chantier."
  @spec restant() :: [{nil | :cb, 0..0xFF}]
  def restant do
    for insn <- Table.all(), body(insn) == :non_supporté, do: {insn.prefix, insn.opcode}
  end
end
