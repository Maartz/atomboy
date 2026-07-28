defmodule Atomboy.CPU.CartLoop do
  @moduledoc """
  La boucle rapide en sémantique cartouche : la région ROM est en lecture
  seule.

  Même squelette et mêmes clauses générées que `Atomboy.CPU.Loop` — seuls les
  accès mémoire diffèrent :

    * **Écrire sous 0x8000 ne fait rien.** Sur une vraie cartouche, ces
      écritures parlent au contrôleur de banque (MBC) ; sur une ROM de 32 Ko
      sans banking, elles se perdent. Dans le modèle plat de `Loop`, elles
      masqueraient la ROM — blargg écrit l'activation de sa RAM cartouche à
      0x0000 et son numéro de banque à 0x2000, et exécuterait ensuite ces
      octets-là.
    * **Lire sous 0x8000 va droit dans la binary**, sans consulter la map des
      écritures : le fetch en région ROM — l'écrasante majorité — économise le
      test de map. C'est le découpage par région promis depuis le premier test
      d'équivalence.

  `Loop` garde sa sémantique plate : c'est elle que les vecteurs SM83 et le
  test d'équivalence exigent — ils écrivent et exécutent partout. Les deux
  modules sortent du même générateur ; ils ne divergent que par quatre lignes
  de helpers mémoire.

  Le jour du vrai MMU (banking MBC, VRAM en resource NIF), c'est ce module qui
  grandit — région par région, toujours dans les helpers, jamais dans les
  clauses.
  """

  import Bitwise

  alias Atomboy.CPU.Gen
  alias Atomboy.CPU.Insn
  alias Atomboy.CPU.State
  alias Atomboy.CPU.Table

  require Gen

  @typedoc "La ROM : 64 Ko, les 32 premiers adressables en exécution directe."
  @type rom :: binary()

  @typedoc "Les écritures, au-dessus de 0x8000 seulement."
  @type ram :: %{optional(0x8000..0xFFFF) => 0..0xFF}

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

  # ── Fetch — identique à Loop ────────────────────────────────────────────────

  defp fetch(_rom, ram, budget, cycles, a, f, b, c, d, e, h, l, sp, pc, ime, halted, ime_pending)
       when cycles >= budget do
    {{a, f, b, c, d, e, h, l, sp, pc, ime, halted, ime_pending}, ram, cycles}
  end

  defp fetch(rom, ram, budget, cycles, a, f, b, c, d, e, h, l, sp, pc, _ime, halted, 1) do
    fetch(rom, ram, budget, cycles, a, f, b, c, d, e, h, l, sp, pc, 1, halted, 0)
  end

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

  # ── Les clauses — mêmes émetteurs que Loop ──────────────────────────────────

  for %Insn{prefix: nil} = insn <- Table.base() do
    {args, body} = Gen.loop_clause(insn)

    defp exec(unquote(insn.opcode), unquote_splicing(args)) do
      unquote(body)
    end
  end

  defp exec(0xCB, rom, ram, budget, cycles, a, f, b, c, d, e, h, l, sp, pc, ime, halted, pending) do
    exec_cb(
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
      pending
    )
  end

  for %Insn{prefix: :cb} = insn <- Table.extended() do
    {args, body} = Gen.loop_clause(insn)

    defp exec_cb(unquote(insn.opcode), unquote_splicing(args)) do
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

  defp exec_cb(
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
    raise Atomboy.CPU.Unimplemented, opcode: opcode, prefix: :cb
  end

  # ── Mémoire — la seule différence avec Loop ─────────────────────────────────

  @compile {:inline, mem_read: 3, ram_write: 3}

  # La région ROM lit droit dans la binary — pas de map sur le chemin du fetch.
  defp mem_read(rom, _ram, addr) when addr < 0x8000, do: :binary.at(rom, addr)

  # La RAM cartouche est derrière le verrou d'activation du MBC : désactivée,
  # elle lit 0xFF — le bus ouvert. Ce n'est pas du zèle : la détection SRAM de
  # blargg écrit puis relit *verrou fermé*, et conclut « pas de vraie SRAM » si
  # la valeur revient. Sans ce comportement, ses tests se rabattent sur la
  # sortie série et le protocole mémoire reste muet.
  defp mem_read(_rom, ram, addr) when addr >= 0xA000 and addr < 0xC000 do
    case ram do
      %{:cram_enabled => true, ^addr => value} -> value
      _ -> 0xFF
    end
  end

  defp mem_read(rom, ram, addr) do
    case ram do
      %{^addr => value} -> value
      _ -> :binary.at(rom, addr)
    end
  end

  # 0x0000-0x1FFF : le registre d'activation de la RAM cartouche (0x0A active).
  # L'état vit dans la map des écritures sous une clé hors adresse — le seul
  # état du MBC, aucune raison d'élargir la boucle pour lui.
  defp ram_write(ram, addr, value) when addr < 0x2000 do
    Map.put(ram, :cram_enabled, (value &&& 0x0F) == 0x0A)
  end

  # 0xFF02, bit 7 : départ d'un transfert série. L'octet chargé dans 0xFF01
  # part dans le tampon :serial, et le transfert se conclut dans l'instant —
  # bit 7 retombé. C'est le canal de sortie des ROMs blargg de la génération
  # cpu_instrs, qui ignorent le protocole mémoire de leurs cadettes ; la
  # capture doit se faire à l'écriture, les caractères partent à quelques
  # dizaines de cycles d'écart et un échantillonnage les perdrait.
  defp ram_write(ram, 0xFF02, value) when (value &&& 0x80) != 0 do
    char = Map.get(ram, 0xFF01, 0)

    ram
    |> Map.update(:serial, <<char>>, &[&1 | <<char>>])
    |> Map.put(0xFF02, value &&& 0x7F)
  end

  # Le reste de la région ROM parle au MBC — banking inexistant sur 32 Ko.
  defp ram_write(ram, addr, _value) when addr < 0x8000, do: ram

  defp ram_write(ram, addr, value) when addr >= 0xA000 and addr < 0xC000 do
    case ram do
      %{cram_enabled: true} -> Map.put(ram, addr, value)
      _ -> ram
    end
  end

  defp ram_write(ram, addr, value), do: Map.put(ram, addr, value)
end
