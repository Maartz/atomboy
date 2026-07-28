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

  Renvoie `{state, mem, t_cycles}`.
  """
  @spec step(State.t(), Atomboy.Memory.t()) ::
          {State.t(), Atomboy.Memory.t(), pos_integer()}
  def step(%State{pc: pc} = st, mem) do
    opcode = @mem.read8(mem, pc)
    # PC est avancé avant l'exécution : les clauses générées n'ont donc à s'en
    # occuper que si elles sautent, ce qui est le cas minoritaire.
    exec(opcode, %{st | pc: pc + 1 &&& 0xFFFF}, mem)
  end

  # ── Les clauses ─────────────────────────────────────────────────────────────
  #
  # Rien à lire ici : la description des instructions est dans
  # `Atomboy.CPU.Table`, leur traduction en code dans `Atomboy.CPU.Gen`. Ce bloc
  # ne fait que poser les clauses produites.

  @doc false
  def exec(opcode, state, mem)

  for %Insn{prefix: nil} = insn <- Table.base() do
    @implemented {nil, insn.opcode}
    {args, body} = Gen.clause(insn)

    def exec(unquote(insn.opcode), unquote_splicing(args)) do
      unquote(body)
    end
  end

  # ── Filet ───────────────────────────────────────────────────────────────────

  def exec(opcode, _state, _mem) do
    raise Atomboy.CPU.Unimplemented, opcode: opcode, prefix: nil
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

  # ── Helpers ─────────────────────────────────────────────────────────────────

  @compile {:inline, mem_read: 2, mem_read_pc: 2, mem_read_pc16: 2, mem_write: 3}

  defp mem_read(mem, %State{h: h, l: l}), do: @mem.read8(mem, bsl(h, 8) ||| l)

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

  defexception [:opcode, :prefix]

  @impl true
  def message(%{opcode: opcode, prefix: prefix}) do
    label = if prefix == :cb, do: "CB #{hex(opcode)}", else: hex(opcode)
    "opcode #{label} non implémenté"
  end

  defp hex(opcode), do: opcode |> Integer.to_string(16) |> String.pad_leading(2, "0")
end
