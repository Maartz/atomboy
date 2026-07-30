defmodule Atomboy.Native.Interp do
  @moduledoc """
  L'interpréteur SM83, assemblé — pilote, fetch, table de saut, gestionnaires.

  ## Le dispatch, enfin en temps constant

  `Atomboy.CPU.Gen` dispatche par un arbre binaire de comparaisons entières.
  Ce n'est pas un choix : le JIT d'AtomVM compile un `select_val` en balayage
  linéaire, et le coût mesuré grimpait d'un facteur 10,6 entre le premier opcode
  de la table et le cent-quatre-vingtième. Sur du RISC-V nu la contrainte
  disparaît, et le dispatch redevient ce qu'il aurait toujours dû être : un
  décalage, une addition, un chargement, un saut. Neuf instructions du budget
  jusqu'au gestionnaire, quel que soit l'opcode.

  ## L'ordre du fetch est observable

  Budget, puis promotion d'un EI armé, puis HALT, puis service d'interruption,
  puis dispatch — c'est l'ordre de `Atomboy.CPU.Loop.fetch/17`, et le recopier
  n'est pas une politesse. Toute permutation diverge de l'oracle sur les
  programmes qui arment un EI juste avant une interruption, et c'est le test
  d'équivalence qui le dira, plusieurs semaines après la faute.

  À l'étape 1, seuls le budget et le dispatch sont écrits. Un état où IME,
  HALT ou un EI armé sont posés n'est pas exécuté du tout : l'invité s'arrête et
  rapporte `:etat_non_supporte`, plutôt que de rendre un résultat faux. C'est la
  seule façon honnête de livrer un interpréteur partiel.

  ## Le protocole

  L'image porte l'état initial, le budget et les 64 Ko de mémoire ; elle rend un
  enregistrement de 20 octets suivi des 64 Ko finaux, par le port série. Rien ne
  transite pendant l'exécution : tout est cuit dans l'image, tout ressort à la
  fin. Un harnais sans dialogue est un harnais qui ne peut pas se désynchroniser.
  """

  alias Atomboy.CPU.Insn
  alias Atomboy.CPU.State
  alias Atomboy.CPU.Table
  alias Atomboy.Native.ALU
  alias Atomboy.Native.Asm
  alias Atomboy.Native.Emit
  alias Atomboy.Native.Image
  alias Atomboy.Native.Regs
  alias Atomboy.Native.RV32

  @magic 0xA5
  @taille_enregistrement 20
  @memoire 0x10000

  @statuts %{ok: 0, opcode_inconnu: 1, etat_non_supporte: 2}

  @doc "Les codes de statut que l'invité peut rapporter."
  @spec statuts() :: %{atom() => 0..255}
  def statuts, do: @statuts

  @doc "La taille de l'enregistrement de résultat, avant le vidage mémoire."
  @spec taille_enregistrement() :: pos_integer()
  def taille_enregistrement, do: @taille_enregistrement

  @doc "L'octet qui ouvre un enregistrement de résultat."
  @spec magic() :: 0..255
  def magic, do: @magic

  @doc """
  Assemble une image qui exécute `budget` T-cycles depuis `state` sur `memoire`.

  `memoire` fait 64 Ko : c'est l'espace d'adressage complet, à plat. C'est le
  contrat de `Atomboy.CPU.Loop`, pas celui de `CartLoop` — ni MBC, ni MMIO, ni
  banque. Précisément le contrat que les vecteurs SM83 valident déjà.
  """
  @spec image(binary(), State.t(), pos_integer()) :: Asm.assembled()
  def image(memoire, %State{} = state, budget) when byte_size(memoire) == @memoire do
    Image.build(
      [pilote(), fetch(), sorties(), gestionnaires(), ALU.routines()],
      donnees(memoire, state, budget)
    )
  end

  # ══ Le pilote ════════════════════════════════════════════════════════════════

  defp pilote do
    [
      Asm.label(:pilote),
      Asm.la(Regs.dispatch(), :table_base),
      Asm.la(Regs.mem(), :memoire_gb),
      RV32.li(Regs.mask16(), 0xFFFF),
      RV32.li(Regs.cycles(), 0),
      Asm.la(:t2, :etat_initial),
      RV32.lbu(Regs.a(), :t2, 0),
      RV32.lbu(Regs.f(), :t2, 1),
      RV32.lbu(Regs.b(), :t2, 2),
      RV32.lbu(Regs.c(), :t2, 3),
      RV32.lbu(Regs.d(), :t2, 4),
      RV32.lbu(Regs.e(), :t2, 5),
      # H et L arrivent séparés dans l'en-tête et se rejoignent ici : c'est le
      # seul endroit du natif où la paire se fabrique.
      RV32.lbu(:t0, :t2, 6),
      RV32.lbu(:t1, :t2, 7),
      RV32.slli(:t0, :t0, 8),
      RV32.or_(Regs.hl(), :t0, :t1),
      RV32.lhu(Regs.sp(), :t2, 8),
      RV32.lhu(Regs.pc(), :t2, 10),
      RV32.lbu(Regs.control(), :t2, 12),
      RV32.lw(Regs.budget(), :t2, 16),
      Asm.j(:fetch)
    ]
  end

  # ══ Le fetch ═════════════════════════════════════════════════════════════════

  defp fetch do
    [
      Asm.label(:fetch),
      Asm.bgeu(Regs.cycles(), Regs.budget(), :vers_materialise),
      Asm.bnez(Regs.control(), :vers_non_supporte),
      RV32.add(:t0, Regs.mem(), Regs.pc()),
      RV32.lbu(Regs.opcode(), :t0, 0),
      RV32.addi(Regs.pc(), Regs.pc(), 1),
      RV32.and_(Regs.pc(), Regs.pc(), Regs.mask16()),
      RV32.slli(:t0, Regs.opcode(), 2),
      RV32.add(:t0, Regs.dispatch(), :t0),
      RV32.lw(:t0, :t0, 0),
      RV32.jr(:t0),

      # Les deux tremplins vivent juste derrière le `jr`, qui ne retombe jamais
      # dedans. Leur place n'est pas indifférente : un branchement conditionnel
      # ne porte qu'à ±4 Ko, et les gestionnaires finiront par occuper bien plus
      # que cela. Sauter d'abord tout près, puis loin, met la portée hors de
      # cause définitivement.
      Asm.label(:vers_materialise),
      Asm.j(:materialise),
      Asm.label(:vers_non_supporte),
      Asm.j(:etat_non_supporte)
    ]
  end

  # ══ Les sorties ══════════════════════════════════════════════════════════════

  defp sorties do
    [
      Asm.label(:materialise),
      RV32.li(:t2, @statuts.ok),
      Asm.j(:rapport),
      Asm.label(:opcode_inconnu),
      RV32.li(:t2, @statuts.opcode_inconnu),
      Asm.j(:rapport),
      Asm.label(:etat_non_supporte),
      RV32.li(:t2, @statuts.etat_non_supporte),
      rapport(),
      vidage()
    ]
  end

  # `putc` n'écrase que t0 et t1 : t2 porte le statut d'un bout à l'autre, a1
  # l'opcode, et tous les registres d'état survivent.
  defp rapport do
    [
      Asm.label(:rapport),
      octet(RV32.li(:a0, @magic)),
      octet(RV32.mv(:a0, Regs.a())),
      octet(RV32.mv(:a0, Regs.f())),
      octet(RV32.mv(:a0, Regs.b())),
      octet(RV32.mv(:a0, Regs.c())),
      octet(RV32.mv(:a0, Regs.d())),
      octet(RV32.mv(:a0, Regs.e())),
      octet(RV32.srli(:a0, Regs.hl(), 8)),
      octet(RV32.andi(:a0, Regs.hl(), 0xFF)),
      octet(RV32.mv(:a0, Regs.sp())),
      octet(RV32.srli(:a0, Regs.sp(), 8)),
      octet(RV32.mv(:a0, Regs.pc())),
      octet(RV32.srli(:a0, Regs.pc(), 8)),
      octet(RV32.mv(:a0, Regs.control())),
      octet(RV32.mv(:a0, Regs.cycles())),
      octet(RV32.srli(:a0, Regs.cycles(), 8)),
      octet(RV32.srli(:a0, Regs.cycles(), 16)),
      octet(RV32.srli(:a0, Regs.cycles(), 24)),
      octet(RV32.mv(:a0, :t2)),
      octet(RV32.mv(:a0, Regs.opcode()))
    ]
  end

  # `sb` ne pose que les huit bits bas : rien à masquer avant d'émettre.
  defp octet(charge), do: [charge, Asm.call(:putc)]

  defp vidage do
    [
      Asm.label(:vidage),
      RV32.mv(:t3, Regs.mem()),
      RV32.li(:t4, @memoire),
      Asm.label(:vidage_boucle),
      Asm.beqz(:t4, :vidage_fin),
      RV32.lbu(:a0, :t3, 0),
      Asm.call(:putc),
      RV32.addi(:t3, :t3, 1),
      RV32.addi(:t4, :t4, -1),
      Asm.j(:vidage_boucle),
      Asm.label(:vidage_fin),
      Asm.j(:poweroff)
    ]
  end

  # ══ Les gestionnaires ════════════════════════════════════════════════════════

  defp gestionnaires do
    base =
      for %Insn{prefix: nil} = insn <- Table.base(),
          (corps = Emit.body(insn)) != :non_supporté do
        [Asm.label(etiquette(insn.opcode)), corps]
      end

    etendus =
      for %Insn{prefix: :cb} = insn <- Table.extended(),
          (corps = Emit.body(insn)) != :non_supporté do
        [Asm.label(etiquette_cb(insn.opcode)), corps]
      end

    [prefixe(), base, etendus]
  end

  # Le préfixe 0xCB n'est pas une instruction : il relit un octet et saute dans
  # la seconde table. Les deux tables étant contiguës, la seconde s'atteint par
  # un déplacement constant de 1024 dans le `lw` — la table de base fait 256
  # entrées de quatre octets, et 1024 tient dans l'immédiat d'un chargement.
  #
  # Aucun cycle n'est compté ici : la table donne pour chaque instruction
  # étendue un coût qui inclut déjà le fetch du préfixe.
  defp prefixe do
    [
      Asm.label(:h_cb),
      RV32.add(:t0, Regs.mem(), Regs.pc()),
      RV32.lbu(:t0, :t0, 0),
      RV32.addi(Regs.pc(), Regs.pc(), 1),
      RV32.and_(Regs.pc(), Regs.pc(), Regs.mask16()),
      RV32.slli(:t0, :t0, 2),
      RV32.add(:t0, Regs.dispatch(), :t0),
      RV32.lw(:t0, :t0, 4 * 256),
      RV32.jr(:t0)
    ]
  end

  # ══ Les données ══════════════════════════════════════════════════════════════

  defp donnees(memoire, state, budget) do
    [
      {:align, 4},
      Asm.label(:table_base),
      table_base(),
      # Contiguë, sans alignement intercalaire : le préfixe compte sur un
      # déplacement de 1024 exactement.
      Asm.label(:table_cb),
      table_cb(),
      {:align, 4},
      Asm.label(:etat_initial),
      entete(state, budget),
      {:align, 4},
      Asm.label(:memoire_gb),
      memoire
    ]
  end

  # Les 256 entrées existent toujours, même pour un opcode que l'étape en cours
  # ne sait pas émettre : c'est ce qui permet au dispatch d'être inconditionnel.
  # Un opcode absent atterrit sur un gestionnaire qui le rapporte, jamais dans
  # du code qui ne lui était pas destiné.
  defp table_base do
    couverts = couverts(nil)

    for opcode <- 0..0xFF do
      cond do
        opcode == Emit.prefixe_cb() and Emit.prefixe_couvert?() -> {:addr, :h_cb}
        MapSet.member?(couverts, opcode) -> {:addr, etiquette(opcode)}
        true -> {:addr, :opcode_inconnu}
      end
    end
  end

  defp table_cb do
    couverts = couverts(:cb)

    for opcode <- 0..0xFF do
      if MapSet.member?(couverts, opcode) do
        {:addr, etiquette_cb(opcode)}
      else
        {:addr, :opcode_inconnu}
      end
    end
  end

  defp couverts(prefixe) do
    MapSet.new(for {^prefixe, opcode} <- Emit.couverture(), do: opcode)
  end

  defp etiquette(opcode), do: :"h_#{Integer.to_string(opcode, 16)}"
  defp etiquette_cb(opcode), do: :"cb_#{Integer.to_string(opcode, 16)}"

  defp entete(%State{} = state, budget) do
    control =
      state.ime + if(state.halted, do: 2, else: 0) + state.ime_pending * 4

    <<state.a, state.f, state.b, state.c, state.d, state.e, state.h, state.l, state.sp::16-little,
      state.pc::16-little, control, 0, 0, 0, budget::32-little>>
  end
end
