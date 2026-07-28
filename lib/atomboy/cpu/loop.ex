defmodule Atomboy.CPU.Loop do
  @moduledoc """
  La boucle rapide : le même CPU que `Atomboy.CPU`, sans map sur le chemin
  chaud.

  Générée depuis la même `Atomboy.CPU.Table` que l'oracle, avec les mêmes
  primitives `Atomboy.CPU.ALU` — seule la convention d'appel change :

    * les dix registres voyagent en **arguments de fonction**, jamais dans une
      structure ; en code natif AOT ce sont des registres machine ;
    * chaque instruction se termine par un **appel terminal** vers le fetch
      suivant — pas de valeur de retour par pas, pas d'allocation ;
    * le fetch lit une **ROM binary** (`:binary.at/2`), pas une map ;
    * l'état n'est matérialisé en `Atomboy.CPU.State` qu'à l'épuisement du
      **budget de cycles** — une fois par scanline dans la boucle de frame, au
      lieu d'une fois par instruction.

  Les écritures mémoire vont dans une map threadée en argument : rare par
  rapport au fetch, et remplaçable par la resource NIF du brief sans toucher
  aux clauses — le générateur est le seul à connaître `ram_write/3`.

  ## Contrat

  `run/4` exécute des instructions entières jusqu'à ce que le compteur de
  cycles **atteigne ou dépasse** le budget : la dernière instruction peut
  déborder, le débordement est visible dans le compte renvoyé. Le PPU
  consommera ce surplus en le décomptant du budget suivant.

  Interruptions : `ime` voyage dans la boucle — RETI le rallume, EI/DI le
  manipuleront. `ie` et `halted` traversent `run/4` inchangés tant qu'aucune
  instruction ne les touche.

  La justesse de ce module n'est pas testée directement : elle est héritée.
  L'oracle passe les vecteurs SM83 ; le test d'équivalence croisée vérifie que
  `run/4` produit, sur des programmes aléatoires, exactement l'état et la
  mémoire de N pas d'oracle.
  """

  import Bitwise

  alias Atomboy.CPU.Gen
  alias Atomboy.CPU.Insn
  alias Atomboy.CPU.State
  alias Atomboy.CPU.Table

  require Gen

  @typedoc "La ROM : l'espace d'adressage de 64 Ko, immuable."
  @type rom :: binary()

  @typedoc "Les écritures : adresse → octet, prioritaire sur la ROM en lecture."
  @type ram :: %{optional(0..0xFFFF) => 0..0xFF}

  @doc """
  Exécute depuis `state` jusqu'à `budget` T-cycles. Renvoie
  `{state, ram, cycles_consommés}`.
  """
  @spec run(State.t(), rom(), ram(), pos_integer()) :: {State.t(), ram(), non_neg_integer()}
  def run(%State{} = st, rom, ram, budget) when byte_size(rom) == 0x10000 do
    {{a, f, b, c, d, e, h, l, sp, pc, ime, halted, ime_pending}, ram, cycles} =
      fetch(
        rom,
        ram,
        budget,
        0,
        st.a,
        st.f,
        st.b,
        st.c,
        st.d,
        st.e,
        st.h,
        st.l,
        st.sp,
        st.pc,
        st.ime,
        st.halted,
        st.ime_pending
      )

    {%{
       st
       | a: a,
         f: f,
         b: b,
         c: c,
         d: d,
         e: e,
         h: h,
         l: l,
         sp: sp,
         pc: pc,
         ime: ime,
         halted: halted,
         ime_pending: ime_pending
     }, ram, cycles}
  end

  # ── Fetch ───────────────────────────────────────────────────────────────────

  # Budget épuisé : matérialisation, l'unique construction de la boucle.
  defp fetch(_rom, ram, budget, cycles, a, f, b, c, d, e, h, l, sp, pc, ime, halted, ime_pending)
       when cycles >= budget do
    {{a, f, b, c, d, e, h, l, sp, pc, ime, halted, ime_pending}, ram, cycles}
  end

  # La promotion d'un EI armé — même point que dans l'oracle : l'entrée du pas.
  defp fetch(rom, ram, budget, cycles, a, f, b, c, d, e, h, l, sp, pc, _ime, halted, 1) do
    fetch(rom, ram, budget, cycles, a, f, b, c, d, e, h, l, sp, pc, 1, halted, 0)
  end

  # Le fetch passe par la même vue rom+ram que les lectures d'opérandes : la
  # Game Boy exécute réellement du code depuis la RAM (les routines OAM-DMA
  # tournent en HRAM), et le test d'équivalence l'a exigé dès son premier run —
  # les programmes aléatoires s'auto-modifient. Le surcoût est un test de map
  # sur la ram des écritures ; le jour du vrai MMU, le découpage par région
  # (fetch ROM sans map, fetch RAM avec) se fera dans le générateur.
  defp fetch(rom, ram, budget, cycles, a, f, b, c, d, e, h, l, sp, pc, ime, halted, ime_pending) do
    exec(
      mem_read(rom, ram, pc),
      rom,
      ram,
      budget,
      cycles,
      a,
      f,
      b,
      c,
      d,
      e,
      h,
      l,
      sp,
      pc + 1 &&& 0xFFFF,
      ime,
      halted,
      ime_pending
    )
  end

  # ── Les clauses ─────────────────────────────────────────────────────────────
  #
  # Rien à lire ici — même table que l'oracle, autre émetteur.

  for %Insn{prefix: nil} = insn <- Table.base() do
    {args, body} = Gen.loop_clause(insn)

    defp exec(unquote(insn.opcode), unquote_splicing(args)) do
      unquote(body)
    end
  end

  defp exec(
         opcode,
         _rom,
         _ram,
         _budget,
         _cycles,
         _a,
         _f,
         _b,
         _c,
         _d,
         _e,
         _h,
         _l,
         _sp,
         _pc,
         _ime,
         _halted,
         _ime_pending
       ) do
    raise Atomboy.CPU.Unimplemented, opcode: opcode, prefix: nil
  end

  # ── Mémoire ─────────────────────────────────────────────────────────────────

  @compile {:inline, mem_read: 3, ram_write: 3}

  # Les écritures masquent la ROM. `0` est une valeur valide : le repli sur la
  # ROM ne se fait que sur absence réelle (`nil`).
  defp mem_read(rom, ram, addr) do
    case ram do
      %{^addr => value} -> value
      _ -> :binary.at(rom, addr)
    end
  end

  defp ram_write(ram, addr, value), do: Map.put(ram, addr, value)
end
