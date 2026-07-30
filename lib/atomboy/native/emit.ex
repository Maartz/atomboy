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

  Les étapes 1 et 3 : `NOP`, les 49 `LD r, r'`, les 56 `ALU A, r` sur registre,
  les 8 formes immédiates, `INC r`/`DEC r`, la colonne z=7 de l'accumulateur, et
  `LD r, d8`. Tout ce qui touche `(HL)` ou la mémoire au-delà du fetch attend
  l'étape 4. Le reste de la table tombe dans `:non_supporté` et le dispatch y
  envoie `opcode_inconnu`.
  """

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

  def body(%Insn{}), do: :non_supporté

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
    for insn <- Table.all(), body(insn) != :non_supporté, do: {insn.prefix, insn.opcode}
  end

  @doc "Les instructions encore à faire — le tableau de bord du chantier."
  @spec restant() :: [{nil | :cb, 0..0xFF}]
  def restant do
    for insn <- Table.all(), body(insn) == :non_supporté, do: {insn.prefix, insn.opcode}
  end
end
