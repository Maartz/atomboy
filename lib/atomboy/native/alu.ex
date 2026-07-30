defmodule Atomboy.Native.ALU do
  @moduledoc """
  L'arithmétique de drapeaux, en RISC-V — le miroir de `Atomboy.CPU.ALU`.

  Une routine par fonction, mêmes noms, même contrat. Ce n'est pas de la
  coquetterie : c'est ce qui rend possible le test différentiel de
  `Atomboy.Native.Banc`, qui compare les deux implémentations sur l'espace
  d'entrée entier plutôt que sur des exemples. La demi-retenue de `ADC` a un cas
  fautif sur 4 096 ; un jeu d'exemples ne le trouve pas, une comparaison
  exhaustive ne peut pas le rater.

  ## Des routines appelées, pas de l'inlining

  Les 64 opcodes `ALU A, r` plus leurs 8 formes immédiates partageraient sinon
  une quinzaine d'instructions de calcul de drapeaux recopiées soixante-douze
  fois — environ 4 Ko, sur un budget d'icache de 32 Ko qui est *toute la raison
  d'être du chantier*. Le prix est un `jal` et un `ret` par instruction ALU. À
  remesurer une fois la table pleine, pas avant.

  ## La convention d'appel

      a0    premier argument, et résultat 8 ou 16 bits
      a1    second argument, quand il en faut un
      s0    A — lu et réécrit par les opérations sur l'accumulateur
      s1    F — lu et réécrit par presque tout
      a2    HL — pour `add16` seulement
      ra    le retour

  Une routine peut écraser `t0` à `t4`, `a0`, `a1`, et les registres de son
  contrat. Tout le reste survit : c'est ce qui permet à un gestionnaire d'opcode
  de garder son état de travail à travers un appel.

  Aucune routine n'en appelle une autre — ce sont des feuilles, `ra` n'est
  jamais sauvegardé.

  ## Ce qui reste en dur ailleurs

  Ce que `Atomboy.CPU.Gen` inline, le natif l'inline aussi : `RES`/`SET`, les
  INC/DEC 16 bits, le masque `0xF0` de `POP AF`, l'extension de signe de `JR`,
  les tests de condition. La frontière est donc la même des trois côtés, et elle
  se relit dans un seul endroit — `alu.ex` — plutôt que de se deviner.
  """

  import Bitwise

  alias Atomboy.Native.Asm
  alias Atomboy.Native.RV32

  @z 0x80
  @n 0x40
  @h 0x20
  @c 0x10

  @doc """
  Toutes les routines, à placer une fois dans une image.

  Elles ne coûtent que leur taille : rien ne s'exécute sans être appelé.
  """
  @spec routines() :: [Asm.item()]
  def routines do
    [
      add(),
      adc(),
      sub(),
      sbc(),
      cp(),
      bit_and(),
      bit_xor(),
      bit_or(),
      inc(),
      dec(),
      add16(),
      add_sp(),
      rlca(),
      rrca(),
      rla(),
      rra(),
      daa(),
      cpl(),
      scf(),
      ccf(),
      rotations_cb(),
      bits()
    ]
  end

  @doc """
  Le nom de l'étiquette d'une routine — le pont entre les deux mondes.

  `Atomboy.CPU.Gen.alu_call/4` associe déjà un mnémonique à un nom de fonction
  d'ALU pour les deux backends Elixir ; ceci en est l'équivalent natif.
  """
  @spec etiquette(atom()) :: atom()
  def etiquette(nom), do: :"alu_#{nom}"

  @doc "Le nom de l'étiquette d'un `BIT n`, dont le numéro de bit est cuit dans la routine."
  @spec etiquette_bit(0..7) :: atom()
  def etiquette_bit(n), do: :"alu_bit_#{n}"

  # ══ Additions ════════════════════════════════════════════════════════════════

  # ADD A, v — la retenue entrante est nulle, tout le reste est partagé.
  defp add do
    [
      Asm.label(etiquette(:add)),
      RV32.li(:t4, 0),
      add_corps(),
      RV32.ret()
    ]
  end

  # ADC A, v — la retenue entrante sort de F et **compte dans la demi-retenue**.
  # C'est le piège documenté dans `Atomboy.CPU.ALU` : l'oublier laisse passer la
  # grande majorité des cas et ne casse que DAA, beaucoup plus tard.
  defp adc do
    [
      Asm.label(etiquette(:adc)),
      carry_in(:t4),
      add_corps(),
      RV32.ret()
    ]
  end

  # A en s0, valeur en a0, retenue entrante en t4. Écrit s0 et s1.
  defp add_corps do
    [
      # somme complète, jusqu'à 0x1FF
      RV32.add(:t3, :s0, :a0),
      RV32.add(:t3, :t3, :t4),
      # demi-retenue : les quartets bas plus la retenue dépassent-ils 0xF
      RV32.andi(:t0, :s0, 0x0F),
      RV32.andi(:t1, :a0, 0x0F),
      RV32.add(:t0, :t0, :t1),
      RV32.add(:t0, :t0, :t4),
      RV32.srli(:t0, :t0, 4),
      RV32.slli(:t0, :t0, 5),
      # retenue sortante : le bit 8 de la somme
      RV32.srli(:t1, :t3, 8),
      RV32.slli(:t1, :t1, 4),
      RV32.or_(:t0, :t0, :t1),
      RV32.andi(:s0, :t3, 0xFF),
      zero(:s0, :t2),
      RV32.or_(:s1, :t0, :t2)
    ]
  end

  # ══ Soustractions ════════════════════════════════════════════════════════════

  defp sub do
    [
      Asm.label(etiquette(:sub)),
      RV32.li(:t4, 0),
      sub_corps(true),
      RV32.ret()
    ]
  end

  defp sbc do
    [
      Asm.label(etiquette(:sbc)),
      carry_in(:t4),
      sub_corps(true),
      RV32.ret()
    ]
  end

  # CP v — une soustraction dont le résultat est jeté. Le même corps, sans
  # l'écriture de A : dupliquer le calcul reviendrait à entretenir deux fois la
  # même subtilité d'emprunt.
  defp cp do
    [
      Asm.label(etiquette(:cp)),
      RV32.li(:t4, 0),
      sub_corps(false),
      RV32.ret()
    ]
  end

  defp sub_corps(ecrit_a?) do
    [
      # emprunt de demi-octet : le quartet bas de A passe-t-il sous celui de v
      RV32.andi(:t0, :s0, 0x0F),
      RV32.andi(:t1, :a0, 0x0F),
      RV32.add(:t1, :t1, :t4),
      RV32.sltu(:t0, :t0, :t1),
      RV32.slli(:t0, :t0, 5),
      # emprunt d'octet
      RV32.add(:t1, :a0, :t4),
      RV32.sltu(:t1, :s0, :t1),
      RV32.slli(:t1, :t1, 4),
      RV32.or_(:t0, :t0, :t1),
      RV32.ori(:t0, :t0, @n),
      # le résultat, écrit ou seulement pesé
      RV32.sub(:t3, :s0, :a0),
      RV32.sub(:t3, :t3, :t4),
      RV32.andi(:t3, :t3, 0xFF),
      zero(:t3, :t2),
      RV32.or_(:s1, :t0, :t2),
      if(ecrit_a?, do: [RV32.mv(:s0, :t3)], else: [])
    ]
  end

  # ══ Logiques ═════════════════════════════════════════════════════════════════

  # AND pose H. Ce n'est pas une régularité oubliée, c'est ainsi sur le matériel.
  defp bit_and do
    [
      Asm.label(etiquette(:bit_and)),
      RV32.and_(:s0, :s0, :a0),
      zero(:s0, :t0),
      RV32.ori(:s1, :t0, @h),
      RV32.ret()
    ]
  end

  defp bit_xor do
    [
      Asm.label(etiquette(:bit_xor)),
      RV32.xor_(:s0, :s0, :a0),
      zero(:s0, :s1),
      RV32.ret()
    ]
  end

  defp bit_or do
    [
      Asm.label(etiquette(:bit_or)),
      RV32.or_(:s0, :s0, :a0),
      zero(:s0, :s1),
      RV32.ret()
    ]
  end

  # ══ Incréments ═══════════════════════════════════════════════════════════════

  # INC et DEC **préservent C**. Second piège classique après la demi-retenue :
  # poser les quatre drapeaux par réflexe. Le motif `OR A / INC / JR C` des jeux
  # dépend de cette préservation.
  defp inc do
    [
      Asm.label(etiquette(:inc)),
      # H quand le quartet bas valait 0xF
      RV32.andi(:t0, :a0, 0x0F),
      RV32.xori(:t0, :t0, 0x0F),
      RV32.sltiu(:t0, :t0, 1),
      RV32.slli(:t0, :t0, 5),
      RV32.andi(:t1, :s1, @c),
      RV32.or_(:t0, :t0, :t1),
      RV32.addi(:a0, :a0, 1),
      RV32.andi(:a0, :a0, 0xFF),
      zero(:a0, :t2),
      RV32.or_(:s1, :t0, :t2),
      RV32.ret()
    ]
  end

  defp dec do
    [
      Asm.label(etiquette(:dec)),
      # H quand le quartet bas valait 0 — l'emprunt traverse
      RV32.andi(:t0, :a0, 0x0F),
      RV32.sltiu(:t0, :t0, 1),
      RV32.slli(:t0, :t0, 5),
      RV32.andi(:t1, :s1, @c),
      RV32.or_(:t0, :t0, :t1),
      RV32.ori(:t0, :t0, @n),
      RV32.addi(:a0, :a0, -1),
      RV32.andi(:a0, :a0, 0xFF),
      zero(:a0, :t2),
      RV32.or_(:s1, :t0, :t2),
      RV32.ret()
    ]
  end

  # ══ Seize bits ═══════════════════════════════════════════════════════════════

  # ADD HL, rr — le miroir inversé d'INC : ici c'est Z qui est préservé et C qui
  # bouge. H se calcule au bit 11, C au bit 15.
  defp add16 do
    [
      Asm.label(etiquette(:add16)),
      # 0x0FFF ne tient pas dans l'immédiat de andi (12 bits signés) : le
      # masque des douze bits bas se fait au décalage.
      RV32.slli(:t0, :a2, 20),
      RV32.srli(:t0, :t0, 20),
      RV32.slli(:t1, :a0, 20),
      RV32.srli(:t1, :t1, 20),
      RV32.add(:t0, :t0, :t1),
      RV32.srli(:t0, :t0, 12),
      RV32.slli(:t0, :t0, 5),
      RV32.add(:t3, :a2, :a0),
      RV32.srli(:t1, :t3, 16),
      RV32.slli(:t1, :t1, 4),
      RV32.or_(:t0, :t0, :t1),
      RV32.andi(:t1, :s1, @z),
      RV32.or_(:s1, :t0, :t1),
      RV32.and_(:a2, :t3, :s8),
      RV32.ret()
    ]
  end

  # ADD SP, r8 — les drapeaux les plus contre-intuitifs du processeur :
  # opération 16 bits, drapeaux calculés sur l'octet bas comme une addition
  # 8 bits non signée, et Z toujours effacé même quand le résultat est nul.
  # L'offset est signé pour le résultat, non signé pour les drapeaux.
  defp add_sp do
    [
      Asm.label(etiquette(:add_sp)),
      RV32.andi(:t0, :a0, 0x0F),
      RV32.andi(:t1, :a1, 0x0F),
      RV32.add(:t0, :t0, :t1),
      RV32.srli(:t0, :t0, 4),
      RV32.slli(:t0, :t0, 5),
      RV32.andi(:t1, :a0, 0xFF),
      RV32.add(:t1, :t1, :a1),
      RV32.srli(:t1, :t1, 8),
      RV32.slli(:t1, :t1, 4),
      RV32.or_(:s1, :t0, :t1),
      # extension de signe sans branche : retrancher 256 quand le bit 7 est levé
      RV32.srli(:t2, :a1, 7),
      RV32.slli(:t2, :t2, 8),
      RV32.sub(:t2, :a1, :t2),
      RV32.add(:a0, :a0, :t2),
      RV32.and_(:a0, :a0, :s8),
      RV32.ret()
    ]
  end

  # ══ L'accumulateur seul ══════════════════════════════════════════════════════

  # Les rotations de A effacent **toujours** Z, contrairement à leurs jumelles
  # de la table CB qui le posent normalement. Deux instructions, deux encodages,
  # deux sémantiques de Z : source classique de confusion.
  defp rlca do
    [
      Asm.label(etiquette(:rlca)),
      RV32.srli(:t0, :s0, 7),
      RV32.slli(:s0, :s0, 1),
      RV32.or_(:s0, :s0, :t0),
      RV32.andi(:s0, :s0, 0xFF),
      RV32.slli(:s1, :t0, 4),
      RV32.ret()
    ]
  end

  defp rrca do
    [
      Asm.label(etiquette(:rrca)),
      RV32.andi(:t0, :s0, 1),
      RV32.srli(:s0, :s0, 1),
      RV32.slli(:t1, :t0, 7),
      RV32.or_(:s0, :s0, :t1),
      RV32.slli(:s1, :t0, 4),
      RV32.ret()
    ]
  end

  defp rla do
    [
      Asm.label(etiquette(:rla)),
      carry_in(:t1),
      RV32.srli(:t0, :s0, 7),
      RV32.slli(:s0, :s0, 1),
      RV32.or_(:s0, :s0, :t1),
      RV32.andi(:s0, :s0, 0xFF),
      RV32.slli(:s1, :t0, 4),
      RV32.ret()
    ]
  end

  defp rra do
    [
      Asm.label(etiquette(:rra)),
      carry_in(:t1),
      RV32.andi(:t0, :s0, 1),
      RV32.srli(:s0, :s0, 1),
      RV32.slli(:t1, :t1, 7),
      RV32.or_(:s0, :s0, :t1),
      RV32.slli(:s1, :t0, 4),
      RV32.ret()
    ]
  end

  # DAA — l'instruction la plus tordue du processeur, et la raison d'être des
  # drapeaux N et H posés soigneusement partout ailleurs : elle est leur seul
  # lecteur. C est **posé, jamais effacé**.
  defp daa do
    [
      Asm.label(etiquette(:daa)),
      RV32.andi(:t0, :s1, @n),
      Asm.bnez(:t0, :daa_soustraction),

      # Après une addition : l'ajustement dépend de H, de C, et de la valeur.
      RV32.li(:t1, 0),
      RV32.andi(:t2, :s1, @h),
      Asm.bnez(:t2, :daa_bas),
      RV32.andi(:t2, :s0, 0x0F),
      RV32.sltiu(:t2, :t2, 10),
      Asm.bnez(:t2, :daa_haut),
      Asm.label(:daa_bas),
      RV32.addi(:t1, :t1, 0x06),
      Asm.label(:daa_haut),
      RV32.andi(:t2, :s1, @c),
      Asm.bnez(:t2, :daa_haut_oui),
      RV32.li(:t2, 0x99),
      RV32.sltu(:t2, :t2, :s0),
      Asm.beqz(:t2, :daa_addition_fin),
      Asm.label(:daa_haut_oui),
      RV32.addi(:t1, :t1, 0x60),
      RV32.ori(:s1, :s1, @c),
      Asm.label(:daa_addition_fin),
      RV32.add(:s0, :s0, :t1),
      Asm.j(:daa_fin),

      # Après une soustraction : H et C seuls décident, la valeur de A n'entre
      # pas en compte. C'est ainsi.
      Asm.label(:daa_soustraction),
      RV32.li(:t1, 0),
      RV32.andi(:t2, :s1, @h),
      Asm.beqz(:t2, :daa_soustraction_haut),
      RV32.addi(:t1, :t1, 0x06),
      Asm.label(:daa_soustraction_haut),
      RV32.andi(:t2, :s1, @c),
      Asm.beqz(:t2, :daa_soustraction_fin),
      RV32.addi(:t1, :t1, 0x60),
      Asm.label(:daa_soustraction_fin),
      RV32.sub(:s0, :s0, :t1),

      # N et C survivent, H tombe, Z se recalcule.
      Asm.label(:daa_fin),
      RV32.andi(:s0, :s0, 0xFF),
      RV32.andi(:t0, :s1, @n ||| @c),
      zero(:s0, :t1),
      RV32.or_(:s1, :t0, :t1),
      RV32.ret()
    ]
  end

  defp cpl do
    [
      Asm.label(etiquette(:cpl)),
      RV32.xori(:s0, :s0, 0xFF),
      RV32.andi(:t0, :s1, @z ||| @c),
      RV32.ori(:s1, :t0, @n ||| @h),
      RV32.ret()
    ]
  end

  defp scf do
    [
      Asm.label(etiquette(:scf)),
      RV32.andi(:t0, :s1, @z),
      RV32.ori(:s1, :t0, @c),
      RV32.ret()
    ]
  end

  defp ccf do
    [
      Asm.label(etiquette(:ccf)),
      RV32.andi(:t0, :s1, @z),
      RV32.andi(:t1, :s1, @c),
      RV32.xori(:t1, :t1, @c),
      RV32.or_(:s1, :t0, :t1),
      RV32.ret()
    ]
  end

  # ══ Les rotations de la table CB ═════════════════════════════════════════════
  #
  # Même forme que leurs jumelles sur A, à ceci près qu'elles posent Z
  # normalement, et qu'elles travaillent sur a0 plutôt que sur l'accumulateur.

  defp rotations_cb do
    [
      rlc(),
      rrc(),
      rl(),
      rr(),
      sla(),
      sra(),
      swap(),
      srl()
    ]
  end

  defp rlc do
    [
      Asm.label(etiquette(:rlc)),
      RV32.srli(:t0, :a0, 7),
      RV32.slli(:a0, :a0, 1),
      RV32.or_(:a0, :a0, :t0),
      RV32.andi(:a0, :a0, 0xFF),
      RV32.slli(:t0, :t0, 4),
      zero(:a0, :t1),
      RV32.or_(:s1, :t0, :t1),
      RV32.ret()
    ]
  end

  defp rrc do
    [
      Asm.label(etiquette(:rrc)),
      RV32.andi(:t0, :a0, 1),
      RV32.srli(:a0, :a0, 1),
      RV32.slli(:t1, :t0, 7),
      RV32.or_(:a0, :a0, :t1),
      RV32.slli(:t0, :t0, 4),
      zero(:a0, :t1),
      RV32.or_(:s1, :t0, :t1),
      RV32.ret()
    ]
  end

  defp rl do
    [
      Asm.label(etiquette(:rl)),
      carry_in(:t1),
      RV32.srli(:t0, :a0, 7),
      RV32.slli(:a0, :a0, 1),
      RV32.or_(:a0, :a0, :t1),
      RV32.andi(:a0, :a0, 0xFF),
      RV32.slli(:t0, :t0, 4),
      zero(:a0, :t1),
      RV32.or_(:s1, :t0, :t1),
      RV32.ret()
    ]
  end

  defp rr do
    [
      Asm.label(etiquette(:rr)),
      carry_in(:t1),
      RV32.andi(:t0, :a0, 1),
      RV32.srli(:a0, :a0, 1),
      RV32.slli(:t1, :t1, 7),
      RV32.or_(:a0, :a0, :t1),
      RV32.slli(:t0, :t0, 4),
      zero(:a0, :t1),
      RV32.or_(:s1, :t0, :t1),
      RV32.ret()
    ]
  end

  defp sla do
    [
      Asm.label(etiquette(:sla)),
      RV32.srli(:t0, :a0, 7),
      RV32.slli(:a0, :a0, 1),
      RV32.andi(:a0, :a0, 0xFF),
      RV32.slli(:t0, :t0, 4),
      zero(:a0, :t1),
      RV32.or_(:s1, :t0, :t1),
      RV32.ret()
    ]
  end

  # SRA réplique le bit 7 : le signe survit au décalage.
  defp sra do
    [
      Asm.label(etiquette(:sra)),
      RV32.andi(:t0, :a0, 1),
      RV32.andi(:t1, :a0, 0x80),
      RV32.srli(:a0, :a0, 1),
      RV32.or_(:a0, :a0, :t1),
      RV32.slli(:t0, :t0, 4),
      zero(:a0, :t1),
      RV32.or_(:s1, :t0, :t1),
      RV32.ret()
    ]
  end

  defp swap do
    [
      Asm.label(etiquette(:swap)),
      RV32.andi(:t0, :a0, 0x0F),
      RV32.slli(:t0, :t0, 4),
      RV32.srli(:a0, :a0, 4),
      RV32.or_(:a0, :a0, :t0),
      zero(:a0, :s1),
      RV32.ret()
    ]
  end

  defp srl do
    [
      Asm.label(etiquette(:srl)),
      RV32.andi(:t0, :a0, 1),
      RV32.srli(:a0, :a0, 1),
      RV32.slli(:t0, :t0, 4),
      zero(:a0, :t1),
      RV32.or_(:s1, :t0, :t1),
      RV32.ret()
    ]
  end

  # ══ BIT n ════════════════════════════════════════════════════════════════════
  #
  # Huit routines plutôt qu'une seule paramétrée : le numéro de bit est une
  # constante de compilation dans les 64 opcodes qui l'utilisent, donc le masque
  # se cuit dans le code et aucun registre n'a besoin de le porter. Z reçoit
  # l'inverse du bit, H se pose, C est préservé, la valeur n'est pas écrite.

  defp bits do
    for n <- 0..7 do
      [
        Asm.label(etiquette_bit(n)),
        RV32.andi(:t0, :a0, 1 <<< n),
        RV32.sltiu(:t0, :t0, 1),
        RV32.slli(:t0, :t0, 7),
        RV32.ori(:t0, :t0, @h),
        RV32.andi(:t1, :s1, @c),
        RV32.or_(:s1, :t0, :t1),
        RV32.ret()
      ]
    end
  end

  # ══ Les briques partagées ════════════════════════════════════════════════════

  # La retenue entrante, ramenée à 0 ou 1.
  defp carry_in(dest) do
    [RV32.andi(dest, :s1, @c), RV32.srli(dest, dest, 4)]
  end

  # Z, posé quand les huit bits bas de `source` sont nuls.
  defp zero(source, dest) do
    [
      RV32.andi(dest, source, 0xFF),
      RV32.sltiu(dest, dest, 1),
      RV32.slli(dest, dest, 7)
    ]
  end
end
