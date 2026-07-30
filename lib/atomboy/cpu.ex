defmodule Atomboy.CPU do
  @moduledoc """
  Le CPU SM83 (Sharp LR35902) de la Game Boy DMG.

  Ce n'est **pas** un Z80 : pas d'IX/IY, pas de registres fantômes, pas de
  préfixes DD/ED/FD, drapeaux différents, et des opcodes qui n'existent nulle
  part ailleurs (`LDH`, `LD (HL+)`, `SWAP`, `STOP`). Toute table Z80 récupérée
  telle quelle sera fausse.

  ## État

  Tout l'état du processeur tient dans un `Atomboy.CPU.State` — registres,
  drapeaux et état d'interruption. La mémoire est threadée à part, en second
  terme : sa forme dépend du backend (voir `Atomboy.Memory`).

  ## Coût connu, et où il part

  `exec/3` renvoie `{state, mem, t_cycles}`, soit une allocation de tuple par
  instruction, plus la copie de la structure quand un registre change. C'est
  assumé pour la phase 1, où le critère est la justesse et où le harnais
  SingleStepTests a besoin d'observer l'état après chaque instruction.

  La suppression de ce coût est déjà cadrée : au lieu de renvoyer, `exec/3` fera
  un appel terminal vers le fetch suivant et ne matérialisera le résultat qu'en
  fin de budget de cycles — une fois par scanline au lieu d'une fois par
  instruction. Le passage se fait dans le générateur, pas dans 500 clauses :
  c'est tout l'intérêt de `Atomboy.CPU.Gen`.

  ## Cycles

  Comptés en **T-cycles** (4 194 304 par seconde), pas en M-cycles. Le PPU
  raisonne en T-cycles — 456 par scanline — et c'est la granularité à laquelle
  la boucle de frame synchronisera. Les vecteurs SingleStepTests, eux, listent
  un accès bus par M-cycle : la conversion est `length(cycles) * 4`.
  """

  import Bitwise

  alias Atomboy.CPU.Gen
  alias Atomboy.CPU.Insn
  alias Atomboy.CPU.State
  alias Atomboy.CPU.Table

  require Gen

  @typedoc "Préfixe d'opcode : `nil` pour la table de base, `:cb` pour la table étendue."
  @type prefix :: nil | :cb

  # Résolu à la compilation : aucun dispatch dynamique sur le chemin chaud.
  # La phase 3 bascule vers le backend NIF par configuration, sans toucher au CPU.
  @mem Application.compile_env(:atomboy, :memory, Atomboy.Memory.Flat)

  @doc "Le module `Atomboy.Memory` compilé dans ce CPU."
  @spec memory_backend() :: module()
  def memory_backend, do: @mem

  Module.register_attribute(__MODULE__, :implemented, accumulate: true)

  @doc """
  Exécute une instruction : fetch à `pc`, décodage, exécution.

  Renvoie `{state, mem, t_cycles}`. **Aucun matériel** : ni service
  d'interruption, ni réveil de HALT — c'est le contrat des vecteurs
  SingleStepTests, qui ne modélisent que l'instruction. Le pas complet, avec
  le contrôleur d'interruptions, est `tick/2`.
  """
  @spec step(State.t(), Atomboy.Memory.t()) ::
          {State.t(), Atomboy.Memory.t(), pos_integer()}
  def step(%State{pc: pc} = st, mem) do
    # L'armement d'un EI antérieur se promeut à l'entrée du pas suivant — même
    # point que le fetch de la boucle rapide, pour que les deux backends
    # restent indiscernables.
    st = if st.ime_pending == 1, do: %{st | ime: 1, ime_pending: 0}, else: st

    opcode = @mem.read8(mem, pc)
    # PC est avancé avant l'exécution : les clauses générées n'ont donc à s'en
    # occuper que si elles sautent, ce qui est le cas minoritaire.
    exec(opcode, %{st | pc: pc + 1 &&& 0xFFFF}, mem)
  end

  # Les cinq sources, dans l'ordre de priorité du matériel : vblank, STAT,
  # timer, série, joypad. Vecteurs 0x40, 0x48, 0x50, 0x58, 0x60.
  @irq_if 0xFF0F
  @irq_ie 0xFFFF

  @doc """
  Un pas complet de machine : promotion d'EI, sommeil de HALT, service
  d'interruption, puis instruction.

  C'est le miroir exact du fetch des boucles rapides — même ordre, mêmes
  cycles — et c'est lui que le test d'équivalence croisée pilote. Un pas rend
  l'un de :

    * un cycle de sommeil (4 T) — HALT sans interruption en attente ;
    * un service (20 T) — IME actif et une source en attente : IME retombe,
      le bit d'IF s'efface, PC part sur la pile, le vecteur prend la main ;
    * une instruction, via `step/2`.

  IF et IE sont lus **en mémoire** (0xFF0F / 0xFFFF), pas dans le champ `ie`
  du struct — c'est là que les programmes les écrivent.
  """
  @spec tick(State.t(), Atomboy.Memory.t()) ::
          {State.t(), Atomboy.Memory.t(), pos_integer()}
  def tick(%State{} = st, mem) do
    st = if st.ime_pending == 1, do: %{st | ime: 1, ime_pending: 0}, else: st
    irq = @mem.read8(mem, @irq_if) &&& @mem.read8(mem, @irq_ie) &&& 0x1F

    cond do
      st.halted and irq == 0 ->
        {st, mem, 4}

      st.halted ->
        # Le réveil est gratuit ; le service éventuel se joue au pas suivant,
        # comme dans les boucles.
        tick(%{st | halted: false}, mem)

      st.ime == 1 and irq != 0 ->
        service(st, mem, irq)

      true ->
        step(st, mem)
    end
  end

  defp service(%State{sp: sp, pc: pc} = st, mem, irq) do
    # Le bit de poids faible en attente gagne.
    bit = irq &&& -irq
    index = index_of(bit)
    new_sp = sp - 2 &&& 0xFFFF
    mem = @mem.write16(mem, new_sp, pc)
    mem = @mem.write8(mem, @irq_if, @mem.read8(mem, @irq_if) &&& bxor(bit, 0xFF))
    {%{st | ime: 0, sp: new_sp, pc: 0x40 + index * 8}, mem, 20}
  end

  defp index_of(0x01), do: 0
  defp index_of(0x02), do: 1
  defp index_of(0x04), do: 2
  defp index_of(0x08), do: 3
  defp index_of(0x10), do: 4

  # ── Le dispatch ─────────────────────────────────────────────────────────────
  #
  # Rien à lire ici : la description des instructions est dans
  # `Atomboy.CPU.Table`, leur traduction en code dans `Atomboy.CPU.Gen`. Le
  # dispatch est un arbre à deux étages, pas des clauses plates — voir le
  # commentaire de Gen sur le select_val linéaire du JIT d'AtomVM. 0xCB y est
  # une entrée comme une autre, qui fetch le second octet et redispatche.

  for %Insn{prefix: nil} = insn <- Table.base(), do: @implemented({nil, insn.opcode})
  @implemented {nil, 0xCB}
  for %Insn{prefix: :cb} = insn <- Table.extended(), do: @implemented({:cb, insn.opcode})

  @doc false
  def exec(unquote_splicing(Gen.head_args(:struct))) do
    unquote(
      Gen.struct_dispatch(
        Table.base(),
        [Gen.struct_cb_entry()],
        Gen.unimplemented(:unimplemented_base)
      )
    )
  end

  defp exec_cb(unquote_splicing(Gen.head_args(:struct))) do
    unquote(Gen.struct_dispatch(Table.extended(), [], Gen.unimplemented(:unimplemented_cb)))
  end

  @doc """
  Les opcodes implémentés, sous forme `{prefixe, opcode}`.

  Accumulé à la compilation par les clauses elles-mêmes : impossible que cette
  liste et le décodeur divergent. C'est ce que le harnais SM83 énumère pour
  savoir quels fichiers du corpus rejouer, et c'est la mesure d'avancement de la
  phase 1.
  """
  @spec implemented() :: [{prefix(), 0..0xFF}]
  def implemented, do: Enum.sort(@implemented)

  defp unimplemented_base(opcode) do
    raise Atomboy.CPU.Unimplemented, opcode: opcode, prefix: nil
  end

  defp unimplemented_cb(opcode) do
    raise Atomboy.CPU.Unimplemented, opcode: opcode, prefix: :cb
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  @compile {:inline,
            mem_read: 2,
            mem_read_at: 2,
            mem_read16_at: 2,
            mem_read_pc: 2,
            mem_read_pc16: 2,
            mem_write: 3,
            mem_write_at: 3,
            mem_write16_at: 3}

  defp mem_read(mem, %State{h: h, l: l}), do: @mem.read8(mem, bsl(h, 8) ||| l)

  # Accès à adresse calculée — les indirects (BC), (DE), (HL±), (a16), la pile.
  defp mem_read_at(mem, addr), do: @mem.read8(mem, addr)
  defp mem_read16_at(mem, addr), do: @mem.read16(mem, addr)
  defp mem_write_at(mem, addr, value), do: @mem.write8(mem, addr, value)
  defp mem_write16_at(mem, addr, value), do: @mem.write16(mem, addr, value)

  # L'octet à PC — les opérandes immédiats. `step/2` a déjà avancé PC au-delà
  # de l'opcode, donc PC pointe précisément sur l'immédiat.
  defp mem_read_pc(mem, %State{pc: pc}), do: @mem.read8(mem, pc)

  # Le mot à PC, little-endian — l'accesseur en bloc du comportement mémoire,
  # précisément le genre d'accès que le brief demandait de grouper.
  defp mem_read_pc16(mem, %State{pc: pc}), do: @mem.read16(mem, pc)

  defp mem_write(mem, %State{h: h, l: l}, value), do: @mem.write8(mem, bsl(h, 8) ||| l, value)
end

defmodule Atomboy.CPU.Unimplemented do
  @moduledoc """
  Opcode non encore couvert par le décodeur.

  Distinguée d'un `FunctionClauseError` : sur un corpus de 500 opcodes construit
  par incréments, « pas encore écrit » et « écrit mais faux » sont deux
  situations différentes et le harnais de test doit pouvoir les séparer.
  """

  defexception [:opcode, :prefix, :pc, :bank]

  @impl true
  def message(%{opcode: opcode, prefix: prefix} = e) do
    label = if prefix == :cb, do: "CB #{hex(opcode)}", else: hex(opcode)

    where =
      case {e.pc, e.bank} do
        {nil, _} -> ""
        {pc, nil} -> " à PC 0x#{hex4(pc)}"
        {pc, bank} -> " à PC 0x#{hex4(pc)}, banque ROM #{bank}"
      end

    "opcode #{label} non implémenté#{where}"
  end

  defp hex(opcode), do: opcode |> Integer.to_string(16) |> String.pad_leading(2, "0")
  defp hex4(v), do: v |> Integer.to_string(16) |> String.pad_leading(4, "0")
end

defmodule Atomboy.CPU.Derailed do
  @moduledoc """
  Le PC est entré en VRAM — aucun jeu ne fait ça volontairement.

  Le contrôle a déraillé en amont : table de sauts indexée hors bornes,
  pile écrasée, `jp hl` sur un pointeur de tuiles… L'opcode invalide qui
  finirait par surgir des décombres arrive trop tard pour comprendre ;
  ici le rapport photographie l'instant de l'entrée : registres, banque,
  et le haut de la pile — les adresses de retour y désignent le coupable.
  """

  defexception [:pc, :sp, :bank, :regs, :stack]

  @impl true
  def message(%{pc: pc, sp: sp, bank: bank, regs: regs, stack: stack}) do
    {a, f, b, c, d, e, h, l} = regs

    pile =
      stack
      |> Enum.map(&("0x" <> hex4(&1)))
      |> Enum.join(" ")

    "le processeur a déraillé en VRAM : PC 0x#{hex4(pc)}, banque ROM #{bank}\n" <>
      "    AF=#{hex(a)}#{hex(f)} BC=#{hex(b)}#{hex(c)} DE=#{hex(d)}#{hex(e)} " <>
      "HL=#{hex(h)}#{hex(l)} SP=0x#{hex4(sp)}\n" <>
      "    pile : #{pile}"
  end

  defp hex(v), do: v |> Integer.to_string(16) |> String.pad_leading(2, "0")
  defp hex4(v), do: v |> Integer.to_string(16) |> String.pad_leading(4, "0")
end
