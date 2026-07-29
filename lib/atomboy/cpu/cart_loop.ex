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

  # Aucun jeu n'exécute la VRAM : un PC qui y entre a déraillé en amont
  # (table de sauts hors bornes, pile écrasée). L'opcode invalide qui
  # surgirait des décombres arrive trop tard pour comprendre — arrêter à
  # l'entrée, photographier registres et haut de pile.
  defp dispatch(rom, ram, _budget, _cycles, a, f, b, c, d, e, h, l, sp, pc, _ime, _halted, _pending)
       when pc >= 0x8000 and pc < 0xA000 do
    stack =
      for i <- 0..7 do
        lo = mem_read(rom, ram, sp + 2 * i &&& 0xFFFF)
        hi = mem_read(rom, ram, sp + 2 * i + 1 &&& 0xFFFF)
        bsl(hi, 8) ||| lo
      end

    raise Atomboy.CPU.Deraille,
      pc: pc,
      sp: sp,
      bank: div(Map.get(ram, :rom_bank_base, 0x4000), 0x4000),
      regs: {a, f, b, c, d, e, h, l},
      stack: stack
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
        Gen.unimplemented_at(:unimplemented_base)
      )
    )
  end

  defp exec_cb(unquote_splicing(Gen.head_args(:loop))) do
    unquote(Gen.loop_dispatch(Table.extended(), [], Gen.unimplemented_at(:unimplemented_cb)))
  end

  # PC a déjà dépassé l'opcode d'un cran ; la banque vient de la map — le
  # rapport de crash montre l'adresse réelle et la banque ROM en jeu.
  defp unimplemented_base(opcode, pc, ram) do
    raise Atomboy.CPU.Unimplemented,
      opcode: opcode,
      prefix: nil,
      pc: pc - 1 &&& 0xFFFF,
      bank: div(Map.get(ram, :rom_bank_base, 0x4000), 0x4000)
  end

  defp unimplemented_cb(opcode, pc, ram) do
    raise Atomboy.CPU.Unimplemented,
      opcode: opcode,
      prefix: :cb,
      pc: pc - 2 &&& 0xFFFF,
      bank: div(Map.get(ram, :rom_bank_base, 0x4000), 0x4000)
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
      %{cram_enabled: true} ->
        case Map.get(ram, :cram_bank, 0) do
          {:rtc, reg} -> rtc_read(ram, reg)
          bank -> Map.get(ram, addr + bank * 0x10000, 0xFF)
        end

      _ ->
        0xFF
    end
  end

  # La VRAM, banquée sur GBC (VBK, 0xFF4F) : la banque 1 vit à
  # addr + 0x10000 — la banque 0 garde ses clés nues, le PPU DMG et les
  # frames en or ne voient rien changer.
  defp mem_read(_rom, ram, addr) when addr >= 0x8000 and addr < 0xA000 do
    Map.get(ram, addr + Map.get(ram, :vram_base, 0), 0xFF)
  end

  # La WRAM haute, banquée sur GBC (SVBK, 0xFF70) : banques 2-7 à
  # addr + (banque-1) × 0x10000 — la banque 1, par défaut, clés nues.
  defp mem_read(_rom, ram, addr) when addr >= 0xD000 and addr < 0xE000 do
    Map.get(ram, addr + Map.get(ram, :wram_base, 0), 0xFF)
  end

  # L'écho de la WRAM : sur le bus réel, 0xE000-0xFDFF recâble les lignes
  # d'adresse vers 0xC000-0xDDFF. Pokémon lit réellement par ce miroir —
  # sans lui, une table de sauts se lit en 0xFF et le PC part dans des
  # données (opcode illégal E3, neuf minutes après le lancement). Récursif :
  # le miroir de la WRAM haute traverse la banque choisie.
  defp mem_read(rom, ram, addr) when addr >= 0xE000 and addr < 0xFE00 do
    mem_read(rom, ram, addr - 0x2000)
  end

  # HDMA5 : pendant un HDMA, les blocs restants moins un ; sinon la valeur
  # rangée (0xFF une fois fini).
  defp mem_read(_rom, ram, 0xFF55) when :erlang.is_map_key(:hdma, ram) do
    {_src, _dst, blocks} = Map.get(ram, :hdma)
    blocks - 1 &&& 0x7F
  end

  # Relire BCPD/OCPD rend l'octet de palette pointé par l'index courant.
  defp mem_read(_rom, ram, 0xFF69) do
    Map.get(ram, 0x20000 + (Map.get(ram, 0xFF68, 0) &&& 0x3F), 0xFF)
  end

  defp mem_read(_rom, ram, 0xFF6B) do
    Map.get(ram, 0x20040 + (Map.get(ram, 0xFF6A, 0) &&& 0x3F), 0xFF)
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
  # Câble link branché : le transfert reste en cours (bit 7 levé) et
  # l'échange se joue à la scanline, où vit la socket (Atomboy.Link.line/1).
  # Maître si l'horloge est interne (bit 0). Réécrire SC pendant qu'une
  # horloge maître est déjà en vol relance le MÊME transfert — un seul
  # octet sur le fil, comme le silicium : les boucles de sonde des jeux
  # réécrivent SC chaque frame, et en faire des horloges neuves inondait
  # le fil (deux horloges par réponse, la réponse décisive purgée en
  # orpheline — vécu, à la trace).
  defp ram_write(ram, 0xFF02, value)
       when (value &&& 0x80) != 0 and :erlang.is_map_key(:link, ram) do
    op =
      case {value &&& 0x01, Map.get(ram, :link_op)} do
        {1, :master_sent} -> :master_sent
        {1, _} -> :master
        {0, _} -> :slave
      end

    ram
    |> Map.put(0xFF02, value)
    |> Map.put(:link_op, op)
  end

  defp ram_write(ram, 0xFF02, value) when (value &&& 0x80) != 0 do
    char = Map.get(ram, 0xFF01, 0)

    ram
    |> Map.update(:serial, <<char>>, &[&1 | <<char>>])
    |> Map.put(0xFF02, value &&& 0x7F)
  end

  # NRx4, bit 7 : le déclenchement d'un canal son. L'événement doit être
  # capturé à l'écriture — recharge de longueur, d'enveloppe, de sweep —
  # l'APU le consomme à la frame suivante. La valeur reste lisible telle
  # quelle, comme sur le matériel (le bit 7 n'y est jamais relisible, mais
  # aucun jeu ne le relit).
  defp ram_write(ram, addr, value)
       when addr in [0xFF14, 0xFF19, 0xFF1E, 0xFF23] and (value &&& 0x80) != 0 do
    channel = div(addr - 0xFF14, 5) + 1

    ram
    |> Map.put(addr, value)
    |> Map.update(:apu_triggers, [channel], &[channel | &1])
  end

  # 0x2000-0x3FFF : la sélection de banque ROM — cinq bits sur MBC1 (les
  # 512 Ko de Link's Awakening), sept sur MBC3 (les 2 Mo de Pokémon). Zéro
  # vaut un, masqués par le nombre de banques réelles. Sur MBC5 : huit bits
  # bas à 0x2000-0x2FFF, neuvième bit à 0x3000-0x3FFF — et la banque zéro
  # est permise, c'est le seul MBC qui l'autorise dans la fenêtre haute.
  # La base précalculée évite toute arithmétique au fetch.
  defp ram_write(ram, addr, value) when addr < 0x4000 do
    banks = Map.get(ram, :rom_banks, 2)

    bank =
      case Map.get(ram, :mbc) do
        :mbc5 ->
          current = div(Map.get(ram, :rom_bank_base, 0x4000), 0x4000)

          if addr < 0x3000 do
            (current &&& 0x100) ||| value
          else
            bsl(value &&& 1, 8) ||| (current &&& 0xFF)
          end

        :mbc3 ->
          max(value &&& 0x7F, 1)

        _ ->
          max(max(value &&& 0x1F, 1) &&& banks - 1, 1)
      end

    Map.put(ram, :rom_bank_base, (bank &&& banks - 1) * 0x4000)
  end

  # 0x4000-0x5FFF : sur MBC3, la banque de RAM cartouche (0-3) ou un
  # registre RTC (0x08-0x0C) ; sur MBC5, la banque 0-15. Sur MBC1, bits
  # hauts et mode — ignorés tant qu'aucune ROM MBC1 ne dépasse les 512 Ko.
  defp ram_write(ram, addr, value) when addr < 0x6000 do
    case Map.get(ram, :mbc) do
      :mbc3 ->
        cond do
          value <= 0x03 -> Map.put(ram, :cram_bank, value)
          value in 0x08..0x0C -> Map.put(ram, :cram_bank, {:rtc, value})
          true -> ram
        end

      :mbc5 ->
        Map.put(ram, :cram_bank, value &&& 0x0F)

      _ ->
        ram
    end
  end

  # 0x6000-0x7FFF : sur MBC3, écrire 0x01 fige l'horloge dans les registres
  # latchés — les jeux écrivent 0 puis 1 et lisent une photo cohérente.
  defp ram_write(ram, addr, value) when addr < 0x8000 do
    if Map.get(ram, :mbc) == :mbc3 and value == 0x01 do
      Map.put(ram, :rtc_latch, rtc_now())
    else
      ram
    end
  end

  # La RAM cartouche — celle que la pile garde en vie, par banque (clé
  # addr + banque × 0x10000 : la banque 0 garde ses clés nues, les .sav et
  # les jeux MBC1 ne voient rien changer). Chaque écriture la marque sale :
  # Atomboy.Save sait alors qu'un .sav mérite d'être écrit. Les registres
  # RTC ignorent l'écriture — l'horloge suit le temps réel du Mac.
  defp ram_write(ram, addr, value) when addr >= 0xA000 and addr < 0xC000 do
    case ram do
      %{cram_enabled: true} ->
        case Map.get(ram, :cram_bank, 0) do
          {:rtc, _reg} -> ram
          bank -> ram |> Map.put(addr + bank * 0x10000, value) |> Map.put(:cram_dirty, true)
        end

      _ ->
        ram
    end
  end

  # La VRAM et la WRAM haute, banquées en écriture comme en lecture.
  defp ram_write(ram, addr, value) when addr >= 0x8000 and addr < 0xA000 do
    Map.put(ram, addr + Map.get(ram, :vram_base, 0), value)
  end

  defp ram_write(ram, addr, value) when addr >= 0xD000 and addr < 0xE000 do
    Map.put(ram, addr + Map.get(ram, :wram_base, 0), value)
  end

  # L'écho en écriture : même recâblage, récursif — la donnée vit à sa
  # vraie adresse, banque comprise.
  defp ram_write(ram, addr, value) when addr >= 0xE000 and addr < 0xFE00 do
    ram_write(ram, addr - 0x2000, value)
  end

  # KEY1 (0xFF4D) : la double vitesse du GBC. Le matériel exige « préparer
  # (bit 0) puis STOP » ; ici la bascule se joue dès l'écriture — STOP reste
  # le nop qu'il est, le jeu relit le bit 7 et le trouve levé. Le budget de
  # cycles par scanline suit :speed dans Screen. CGB seulement.
  defp ram_write(ram, 0xFF4D, value) when :erlang.is_map_key(:cgb, ram) do
    if (value &&& 0x01) != 0 do
      fast? = Map.get(ram, :speed, 1) == 2

      ram
      |> Map.put(:speed, if(fast?, do: 1, else: 2))
      |> Map.put(0xFF4D, if(fast?, do: 0x00, else: 0x80))
    else
      ram
    end
  end

  # HDMA5 (0xFF55) : les DMA vidéo du GBC. Bit 7 à zéro = transfert général
  # (GDMA), différé à la frontière de scanline — la source peut être en ROM
  # banquée, que seul Screen a sous la main. Bit 7 levé = un bloc de seize
  # octets par HBlank ; écrire bit 7 à zéro pendant un HDMA l'annule.
  defp ram_write(ram, 0xFF55, value) when :erlang.is_map_key(:cgb, ram) do
    src =
      (bsl(Map.get(ram, 0xFF51, 0), 8) ||| Map.get(ram, 0xFF52, 0)) &&& 0xFFF0

    dst = 0x8000 + ((bsl(Map.get(ram, 0xFF53, 0), 8) ||| Map.get(ram, 0xFF54, 0)) &&& 0x1FF0)
    blocks = (value &&& 0x7F) + 1

    cond do
      (value &&& 0x80) != 0 ->
        Map.put(ram, :hdma, {src, dst, blocks})

      Map.has_key?(ram, :hdma) ->
        {_s, _d, restant} = Map.get(ram, :hdma)

        ram
        |> Map.delete(:hdma)
        |> Map.put(0xFF55, 0x80 ||| (restant - 1 &&& 0x7F))

      true ->
        ram
        |> Map.put(:gdma, {src, dst, blocks})
        |> Map.put(0xFF55, 0xFF)
    end
  end

  # VBK (0xFF4F) : la banque de VRAM du GBC — 0 en clés nues, 1 décalée.
  defp ram_write(ram, 0xFF4F, value) do
    ram
    |> Map.put(0xFF4F, value &&& 1)
    |> Map.put(:vram_base, (value &&& 1) * 0x10000)
  end

  # SVBK (0xFF70) : la banque de WRAM haute — 1 à 7, zéro vaut un.
  defp ram_write(ram, 0xFF70, value) do
    bank = max(value &&& 0x07, 1)

    ram
    |> Map.put(0xFF70, bank)
    |> Map.put(:wram_base, (bank - 1) * 0x10000)
  end

  # Les palettes couleur : BCPS/OCPS portent l'index (bit 7 : auto-
  # incrément), BCPD/OCPD écrivent l'octet — rangé hors bus, à
  # 0x20000 + index (fond) et 0x20040 + index (sprites), où le PPU
  # couleur viendra le lire.
  defp ram_write(ram, 0xFF69, value), do: cpal_write(ram, 0xFF68, 0x20000, value)
  defp ram_write(ram, 0xFF6B, value), do: cpal_write(ram, 0xFF6A, 0x20040, value)

  defp ram_write(ram, addr, value), do: Map.put(ram, addr, value)

  @doc "Lit un octet avec la pleine sémantique cartouche — la voie des DMA."
  @spec peek(rom(), ram(), 0..0xFFFF) :: 0..0xFF
  def peek(rom, ram, addr), do: mem_read(rom, ram, addr)

  @doc "Écrit un octet avec la pleine sémantique cartouche — banques comprises."
  @spec poke(ram(), 0..0xFFFF, 0..0xFF) :: ram()
  def poke(ram, addr, value), do: ram_write(ram, addr, value)

  # ── L'horloge temps réel du MBC3 ────────────────────────────────────────────

  # Secondes, minutes, heures, jours (9 bits) — servis depuis l'heure du
  # Mac : le cycle jour/nuit de Pokémon suit ta fenêtre.
  defp cpal_write(ram, spec_addr, base, value) do
    spec = Map.get(ram, spec_addr, 0)
    index = spec &&& 0x3F
    ram = Map.put(ram, base + index, value)

    if (spec &&& 0x80) != 0 do
      Map.put(ram, spec_addr, 0x80 ||| (index + 1 &&& 0x3F))
    else
      ram
    end
  end

  defp rtc_read(ram, reg) do
    ram |> Map.get(:rtc_latch, rtc_now()) |> Map.get(reg, 0)
  end

  defp rtc_now do
    # ATOMBOY_RTC_OFFSET (secondes) décale l'horloge servie — l'outil des
    # chasses aux bugs dépendants de l'heure, et du voyage dans le temps
    # pour les baies.
    offset =
      case System.get_env("ATOMBOY_RTC_OFFSET") do
        nil -> 0
        v -> String.to_integer(v)
      end

    now = System.os_time(:second) + offset
    days = div(now, 86_400)

    %{
      0x08 => rem(now, 60),
      0x09 => rem(div(now, 60), 60),
      0x0A => rem(div(now, 3600), 24),
      0x0B => rem(days, 256),
      0x0C => rem(days, 512) |> bsr(8) |> band(1)
    }
  end
end
