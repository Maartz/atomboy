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
  def run(%State{} = st, rom, ram, budget)
      when byte_size(rom) >= 0x8000 and rem(byte_size(rom), 0x4000) == 0 do
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

  # IF et IE se lisent ici dans la map seule, défaut 0 : le matériel démarre
  # ces registres à zéro — pas au remplissage 0xFF de la ROM étendue, qui
  # déclencherait des interruptions fantômes dès le premier EI.
  # HALT : le processeur dort par pas de 4 T tant que rien n'est en attente —
  # même granularité que le tick de l'oracle, l'équivalence en dépend. Le
  # réveil est gratuit, le service éventuel se joue à la passe suivante.
  defp fetch(rom, ram, budget, cycles, a, f, b, c, d, e, h, l, sp, pc, ime, true, pending) do
    if (Map.get(ram, 0xFF0F, 0) &&& Map.get(ram, 0xFFFF, 0) &&& 0x1F) == 0 do
      fetch(rom, ram, budget, cycles + 4, a, f, b, c, d, e, h, l, sp, pc, ime, true, pending)
    else
      fetch(rom, ram, budget, cycles, a, f, b, c, d, e, h, l, sp, pc, ime, false, pending)
    end
  end

  # IME actif : une source en attente détourne l'exécution — IME retombe, le
  # bit d'IF s'efface, PC part sur la pile, le vecteur prend la main. 20 T.
  defp fetch(rom, ram, budget, cycles, a, f, b, c, d, e, h, l, sp, pc, 1, halted, pending) do
    irq = Map.get(ram, 0xFF0F, 0) &&& Map.get(ram, 0xFFFF, 0) &&& 0x1F

    if irq == 0 do
      dispatch(rom, ram, budget, cycles, a, f, b, c, d, e, h, l, sp, pc, 1, halted, pending)
    else
      bit = irq &&& -irq
      vector = 0x40 + irq_index(bit) * 8
      new_sp = sp - 2 &&& 0xFFFF

      ram =
        ram
        |> ram_write(new_sp, pc &&& 0xFF)
        |> ram_write(new_sp + 1 &&& 0xFFFF, pc >>> 8)
        |> ram_write(0xFF0F, Map.get(ram, 0xFF0F, 0) &&& bxor(bit, 0xFF))

      fetch(
        rom,
        ram,
        budget,
        cycles + 20,
        a,
        f,
        b,
        c,
        d,
        e,
        h,
        l,
        new_sp,
        vector,
        0,
        halted,
        pending
      )
    end
  end

  defp fetch(rom, ram, budget, cycles, a, f, b, c, d, e, h, l, sp, pc, ime, halted, ime_pending) do
    dispatch(rom, ram, budget, cycles, a, f, b, c, d, e, h, l, sp, pc, ime, halted, ime_pending)
  end

  defp dispatch(
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
         pc,
         ime,
         halted,
         ime_pending
       ) do
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

  defp irq_index(0x01), do: 0
  defp irq_index(0x02), do: 1
  defp irq_index(0x04), do: 2
  defp irq_index(0x08), do: 3
  defp irq_index(0x10), do: 4

  # ── Le dispatch ─────────────────────────────────────────────────────────────
  #
  # Un arbre à deux étages émis par Gen — voir son commentaire sur le
  # select_val linéaire du JIT. 0xCB fetch le second octet et redispatche vers
  # exec_cb, même arbre sur la table étendue.

  defp exec(unquote_splicing(Gen.head_args(:loop))) do
    unquote(
      Gen.loop_dispatch(
        Table.base(),
        [Gen.loop_cb_entry()],
        Gen.unimplemented(:unimplemented_base)
      )
    )
  end

  defp exec_cb(unquote_splicing(Gen.head_args(:loop))) do
    unquote(Gen.loop_dispatch(Table.extended(), [], Gen.unimplemented(:unimplemented_cb)))
  end

  defp unimplemented_base(opcode) do
    raise Atomboy.CPU.Unimplemented, opcode: opcode, prefix: nil
  end

  defp unimplemented_cb(opcode) do
    raise Atomboy.CPU.Unimplemented, opcode: opcode, prefix: :cb
  end

  # ── Mémoire — la seule différence avec Loop ─────────────────────────────────

  @compile {:inline, mem_read: 3, ram_write: 3}

  # La région ROM lit droit dans la binary — pas de map sur le chemin du
  # fetch. La banque 0 est fixe ; la fenêtre 0x4000-0x7FFF regarde la banque
  # choisie via le MBC1, dont la base précalculée vit dans la map.
  defp mem_read(rom, _ram, addr) when addr < 0x4000, do: :binary.at(rom, addr)

  defp mem_read(rom, ram, addr) when addr < 0x8000 do
    :binary.at(rom, Map.get(ram, :rom_bank_base, 0x4000) + addr - 0x4000)
  end

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

  # Au-dessus de la cartouche, une adresse jamais écrite lit 0xFF — le bus
  # ouvert. Plus de repli sur la binary : avec une ROM à banques, l'octet
  # 0x8000 de la binary est du contenu de banque 2, pas de la VRAM.
  defp mem_read(_rom, ram, addr) do
    case ram do
      %{^addr => value} -> value
      _ -> 0xFF
    end
  end

  # 0x0000-0x1FFF : le registre d'activation de la RAM cartouche (0x0A active).
  # L'état vit dans la map des écritures sous une clé hors adresse — le seul
  # état du MBC, aucune raison d'élargir la boucle pour lui.
  defp ram_write(ram, addr, value) when addr < 0x2000 do
    Map.put(ram, :cram_enabled, (value &&& 0x0F) == 0x0A)
  end

  # 0xFF00 : le joypad. Le jeu écrit les bits de sélection (5-4) et relit les
  # lignes de touches dans le quartet bas — actives à zéro. Renvoyer l'octet
  # écrit tel quel, quartet bas à zéro, simule quatre boutons enfoncés en
  # permanence : Tetris y voit A+B+Start+Select, son combo de reset logiciel,
  # et reboote pour l'éternité, écran blanc. Les vraies lignes vivent dans
  # Atomboy.Joypad — le clavier les pose via Joypad.set/3 entre deux frames.
  defp ram_write(ram, 0xFF00, value) do
    Atomboy.Joypad.write(ram, value)
  end

  # 0xFF46 : l'OAM DMA — la page source, copiée d'un bloc vers l'OAM. C'est
  # ainsi que les jeux réels placent leurs sprites : un tampon en WRAM,
  # recopié à chaque vblank. Sans cette interception, l'OAM reste vide et
  # tous les personnages sont invisibles. Source en ROM non gérée — les jeux
  # transfèrent depuis la WRAM, le tampon doit être modifiable.
  defp ram_write(ram, 0xFF46, value) when value >= 0x80 do
    base = bsl(value, 8)

    Enum.reduce(0..0x9F, Map.put(ram, 0xFF46, value), fn offset, acc ->
      Map.put(acc, 0xFE00 + offset, Map.get(ram, base + offset, 0))
    end)
  end

  # Écrire DIV — n'importe quelle valeur — le remet à zéro, sous-compteur
  # compris. C'est le comportement du matériel, et blargg s'en sert pour
  # synchroniser ses mesures de timer.
  defp ram_write(ram, 0xFF04, _value) do
    ram |> Map.put(0xFF04, 0) |> Map.put(:div_acc, 0)
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

  # 0x2000-0x3FFF : la sélection de banque ROM du MBC1 — cinq bits, zéro vaut
  # un, masqués par le nombre de banques réelles. La base précalculée évite
  # toute arithmétique au fetch.
  defp ram_write(ram, addr, value) when addr < 0x4000 do
    banks = Map.get(ram, :rom_banks, 2)
    bank = max(value &&& 0x1F, 1) &&& banks - 1
    Map.put(ram, :rom_bank_base, max(bank, 1) * 0x4000)
  end

  # Le reste de la région ROM parle au MBC — bits hauts et mode, ignorés tant
  # qu'aucune ROM ne dépasse les 512 Ko des cinq bits bas.
  defp ram_write(ram, addr, _value) when addr < 0x8000, do: ram

  defp ram_write(ram, addr, value) when addr >= 0xA000 and addr < 0xC000 do
    case ram do
      %{cram_enabled: true} -> Map.put(ram, addr, value)
      _ -> ram
    end
  end

  defp ram_write(ram, addr, value), do: Map.put(ram, addr, value)
end
