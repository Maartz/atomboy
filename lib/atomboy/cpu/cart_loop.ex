defmodule Atomboy.CPU.CartLoop do
  @moduledoc """
  The fast loop with cartridge semantics: the ROM region is read-only.

  Same skeleton and same generated clauses as `Atomboy.CPU.Loop` — only the
  memory accesses differ:

    * **Writing below 0x8000 does nothing.** On a real cartridge, those writes
      talk to the bank controller (MBC); on a 32 KB ROM without banking, they are
      lost. In `Loop`'s flat model they would mask the ROM — blargg writes its
      cartridge RAM enable at 0x0000 and its bank number at 0x2000, and would
      then go on to execute those very bytes.
    * **Reading below 0x8000 goes straight into the binary**, without consulting
      the writes map: fetching in the ROM region — the overwhelming majority —
      skips the map lookup. This is the split by region promised ever since the
      first equivalence test.

  `Loop` keeps its flat semantics: that is what the SM83 vectors and the
  equivalence test require — they write and execute everywhere. Both modules come
  out of the same generator; they diverge by four lines of memory helpers and
  nothing else.

  The day the real MMU lands (MBC banking, VRAM as a NIF resource), this is the
  module that grows — region by region, always in the helpers, never in the
  clauses.
  """

  import Bitwise

  alias Atomboy.CPU.Gen
  alias Atomboy.CPU.State
  alias Atomboy.CPU.Table

  require Gen

  @typedoc "The ROM: 64 KB, the first 32 addressable for direct execution."
  @type rom :: binary()

  @typedoc "The writes, above 0x8000 only."
  @type ram :: %{optional(0x8000..0xFFFF) => 0..0xFF}

  @doc """
  Runs from `state` for up to `budget` T-cycles. Returns
  `{state, ram, cycles_consumed}`.
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

  # ── Fetch — identical to Loop ───────────────────────────────────────────────

  defp fetch(_rom, ram, budget, cycles, a, f, b, c, d, e, h, l, sp, pc, ime, halted, ime_pending)
       when cycles >= budget do
    {{a, f, b, c, d, e, h, l, sp, pc, ime, halted, ime_pending}, ram, cycles}
  end

  defp fetch(rom, ram, budget, cycles, a, f, b, c, d, e, h, l, sp, pc, _ime, halted, 1) do
    fetch(rom, ram, budget, cycles, a, f, b, c, d, e, h, l, sp, pc, 1, halted, 0)
  end

  # IF and IE are read from the map alone here, defaulting to 0: the hardware
  # starts these registers at zero — not at the 0xFF padding of an extended ROM,
  # which would fire phantom interrupts on the very first EI.
  # HALT: the processor sleeps in 4 T steps as long as nothing is pending — the
  # same granularity as the oracle's tick, and the equivalence depends on it.
  # Waking up is free; any servicing happens on the next pass.
  defp fetch(rom, ram, budget, cycles, a, f, b, c, d, e, h, l, sp, pc, ime, true, pending) do
    if (Map.get(ram, 0xFF0F, 0) &&& Map.get(ram, 0xFFFF, 0) &&& 0x1F) == 0 do
      fetch(rom, ram, budget, cycles + 4, a, f, b, c, d, e, h, l, sp, pc, ime, true, pending)
    else
      fetch(rom, ram, budget, cycles, a, f, b, c, d, e, h, l, sp, pc, ime, false, pending)
    end
  end

  # IME set: a pending source diverts execution — IME drops, the IF bit clears,
  # PC goes onto the stack, the vector takes over. 20 T.
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

  # No game executes VRAM: a PC that enters it derailed further upstream (a jump
  # table out of bounds, a smashed stack). The invalid opcode that would surface
  # from the wreckage comes too late to explain anything — stop at the entry,
  # photograph the registers and the top of the stack.
  defp dispatch(
         rom,
         ram,
         _budget,
         _cycles,
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
         _ime,
         _halted,
         _pending
       )
       when pc >= 0x8000 and pc < 0xA000 do
    stack =
      for i <- 0..7 do
        lo = mem_read(rom, ram, sp + 2 * i &&& 0xFFFF)
        hi = mem_read(rom, ram, sp + 2 * i + 1 &&& 0xFFFF)
        bsl(hi, 8) ||| lo
      end

    raise Atomboy.CPU.Derailed,
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

  # ── The dispatch ────────────────────────────────────────────────────────────
  #
  # A two-level tree emitted by Gen — see its comment on the JIT's linear
  # select_val. 0xCB fetches the second byte and dispatches again into exec_cb,
  # the same tree over the extended table.

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

  # PC has already moved one step past the opcode; the bank comes from the map —
  # the crash report shows the real address and the ROM bank in play.
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

  # ── Memory — the only difference from Loop ──────────────────────────────────

  @compile {:inline, mem_read: 3, ram_write: 3}

  # The ROM region reads straight from the binary — no map on the fetch path.
  # Bank 0 is fixed; the 0x4000-0x7FFF window looks at whichever bank the MBC1
  # selected, whose precomputed base lives in the map.
  defp mem_read(rom, _ram, addr) when addr < 0x4000, do: :binary.at(rom, addr)

  defp mem_read(rom, ram, addr) when addr < 0x8000 do
    :binary.at(rom, Map.get(ram, :rom_bank_base, 0x4000) + addr - 0x4000)
  end

  # Cartridge RAM sits behind the MBC's enable latch: disabled, it reads 0xFF —
  # the open bus. This is not over-engineering: blargg's SRAM detection writes
  # then reads back *with the latch closed*, and concludes "no real SRAM" if the
  # value comes back. Without this behaviour its tests fall back to serial output
  # and the memory protocol stays silent.
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

  # VRAM, banked on GBC (VBK, 0xFF4F): bank 1 lives at addr + 0x10000 — bank 0
  # keeps its bare keys, so the DMG PPU and the golden frames see nothing change.
  defp mem_read(_rom, ram, addr) when addr >= 0x8000 and addr < 0xA000 do
    Map.get(ram, addr + Map.get(ram, :vram_base, 0), 0xFF)
  end

  # High WRAM, banked on GBC (SVBK, 0xFF70): banks 2-7 at
  # addr + (bank-1) × 0x10000 — bank 1, the default, keeps bare keys.
  defp mem_read(_rom, ram, addr) when addr >= 0xD000 and addr < 0xE000 do
    Map.get(ram, addr + Map.get(ram, :wram_base, 0), 0xFF)
  end

  # The WRAM echo: on the real bus, 0xE000-0xFDFF rewires the address lines to
  # 0xC000-0xDDFF. Pokémon genuinely reads through this mirror — without it, a
  # jump table reads as 0xFF and PC wanders off into data (illegal opcode E3,
  # nine minutes after launch). Recursive: the high WRAM mirror goes through
  # whichever bank is selected.
  defp mem_read(rom, ram, addr) when addr >= 0xE000 and addr < 0xFE00 do
    mem_read(rom, ram, addr - 0x2000)
  end

  # HDMA5: during an HDMA, the remaining blocks minus one; otherwise the stored
  # value (0xFF once finished).
  defp mem_read(_rom, ram, 0xFF55) when :erlang.is_map_key(:hdma, ram) do
    {_src, _dst, blocks} = Map.get(ram, :hdma)
    blocks - 1 &&& 0x7F
  end

  # Reading BCPD/OCPD back yields the palette byte the current index points at.
  defp mem_read(_rom, ram, 0xFF69) do
    Map.get(ram, 0x20000 + (Map.get(ram, 0xFF68, 0) &&& 0x3F), 0xFF)
  end

  defp mem_read(_rom, ram, 0xFF6B) do
    Map.get(ram, 0x20040 + (Map.get(ram, 0xFF6A, 0) &&& 0x3F), 0xFF)
  end

  # Above the cartridge, an address never written reads 0xFF — the open bus. No
  # more falling back to the binary: with a banked ROM, the binary's byte at
  # 0x8000 is bank 2 content, not VRAM.
  defp mem_read(_rom, ram, addr) do
    case ram do
      %{^addr => value} -> value
      _ -> 0xFF
    end
  end

  # 0x0000-0x1FFF: the cartridge RAM enable register (0x0A enables). The state
  # lives in the writes map under a non-address key — the MBC's only state, and
  # no reason to widen the loop for it.
  defp ram_write(ram, addr, value) when addr < 0x2000 do
    Map.put(ram, :cram_enabled, (value &&& 0x0F) == 0x0A)
  end

  # 0xFF00: the joypad. The game writes the select bits (5-4) and reads the key
  # lines back in the low nibble — active low. Returning the written byte as-is,
  # low nibble at zero, simulates four buttons held down forever: Tetris sees
  # A+B+Start+Select there, its soft-reset combo, and reboots for eternity, white
  # screen. The real lines live in Atomboy.Joypad — the keyboard sets them through
  # Joypad.set/3 between frames.
  defp ram_write(ram, 0xFF00, value) do
    Atomboy.Joypad.write(ram, value)
  end

  # 0xFF46: the OAM DMA — the source page, copied wholesale into OAM. This is how
  # real games place their sprites: a buffer in WRAM, copied over on every vblank.
  # Without this interception, OAM stays empty and every character is invisible.
  # A source in ROM is not handled — games transfer from WRAM, since the buffer
  # has to be writable.
  defp ram_write(ram, 0xFF46, value) when value >= 0x80 do
    base = bsl(value, 8)

    Enum.reduce(0..0x9F, Map.put(ram, 0xFF46, value), fn offset, acc ->
      Map.put(acc, 0xFE00 + offset, Map.get(ram, base + offset, 0))
    end)
  end

  # Writing DIV — any value at all — resets it to zero, sub-counter included.
  # That is the hardware's behaviour, and blargg uses it to synchronise its timer
  # measurements.
  defp ram_write(ram, 0xFF04, _value) do
    ram |> Map.put(0xFF04, 0) |> Map.put(:div_acc, 0)
  end

  # 0xFF02, bit 7: the start of a serial transfer. The byte loaded into 0xFF01
  # goes into the :serial buffer, and the transfer concludes on the spot — bit 7
  # back down. This is the output channel of the cpu_instrs-generation blargg
  # ROMs, which know nothing of the memory protocol their younger siblings use;
  # the capture has to happen on the write, because the characters leave a few
  # dozen cycles apart and sampling would lose them.
  # With a link cable plugged in: the transfer stays in flight (bit 7 up) and the
  # exchange happens at the scanline, where the socket lives
  # (Atomboy.Link.line/1). Master if the clock is internal (bit 0). Rewriting SC
  # while a master clock is already in flight restarts the SAME transfer — one
  # byte on the wire, just like the silicon: games' polling loops rewrite SC every
  # frame, and turning those into fresh clocks flooded the wire (two clocks per
  # reply, the decisive reply purged as an orphan — lived through it, trace in
  # hand).
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

  # NRx4, bit 7: triggering a sound channel. The event has to be captured on the
  # write — length, envelope and sweep reload — and the APU consumes it on the
  # next frame. The value stays readable as written, as on the hardware (where bit
  # 7 is never readable, but no game reads it back).
  defp ram_write(ram, addr, value)
       when addr in [0xFF14, 0xFF19, 0xFF1E, 0xFF23] and (value &&& 0x80) != 0 do
    channel = div(addr - 0xFF14, 5) + 1

    ram
    |> Map.put(addr, value)
    |> Map.update(:apu_triggers, [channel], &[channel | &1])
  end

  # 0x2000-0x3FFF: ROM bank selection — five bits on MBC1 (Link's Awakening's
  # 512 KB), seven on MBC3 (Pokémon's 2 MB). Zero counts as one, both masked by
  # the real bank count. On MBC5: the low eight bits at 0x2000-0x2FFF, the ninth
  # bit at 0x3000-0x3FFF — and bank zero is allowed, the only MBC that permits it
  # in the high window. The precomputed base keeps all arithmetic out of the
  # fetch.
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

  # 0x4000-0x5FFF: on MBC3, the cartridge RAM bank (0-3) or an RTC register
  # (0x08-0x0C); on MBC5, bank 0-15. On MBC1, the high bits and the mode —
  # ignored as long as no MBC1 ROM goes past 512 KB.
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

  # 0x6000-0x7FFF: on MBC3, writing 0x01 freezes the clock into the latched
  # registers — games write 0 then 1 and read a consistent snapshot.
  defp ram_write(ram, addr, value) when addr < 0x8000 do
    if Map.get(ram, :mbc) == :mbc3 and value == 0x01 do
      Map.put(ram, :rtc_latch, rtc_now())
    else
      ram
    end
  end

  # Cartridge RAM — the one the battery keeps alive, per bank (key
  # addr + bank × 0x10000: bank 0 keeps its bare keys, so .sav files and MBC1
  # games see nothing change). Every write marks it dirty: Atomboy.Save then knows
  # a .sav is worth writing. The RTC registers ignore writes — the clock follows
  # the Mac's real time.
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

  # VRAM and high WRAM, banked on writes just as on reads.
  defp ram_write(ram, addr, value) when addr >= 0x8000 and addr < 0xA000 do
    Map.put(ram, addr + Map.get(ram, :vram_base, 0), value)
  end

  defp ram_write(ram, addr, value) when addr >= 0xD000 and addr < 0xE000 do
    Map.put(ram, addr + Map.get(ram, :wram_base, 0), value)
  end

  # The echo on writes: the same rewiring, recursive — the data lives at its real
  # address, bank included.
  defp ram_write(ram, addr, value) when addr >= 0xE000 and addr < 0xFE00 do
    ram_write(ram, addr - 0x2000, value)
  end

  # KEY1 (0xFF4D): the GBC's double speed. The hardware demands "prepare (bit 0)
  # then STOP"; here the switch happens on the write itself — STOP stays the nop it
  # already is, and the game reads bit 7 back to find it up. The per-scanline cycle
  # budget follows :speed in Screen. CGB only.
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

  # HDMA5 (0xFF55): the GBC's video DMAs. Bit 7 clear = a general transfer (GDMA),
  # deferred to the scanline boundary — the source may sit in banked ROM, which
  # only Screen has to hand. Bit 7 set = one sixteen-byte block per HBlank; writing
  # bit 7 clear during an HDMA cancels it.
  defp ram_write(ram, 0xFF55, value) when :erlang.is_map_key(:cgb, ram) do
    src =
      (bsl(Map.get(ram, 0xFF51, 0), 8) ||| Map.get(ram, 0xFF52, 0)) &&& 0xFFF0

    dst = 0x8000 + ((bsl(Map.get(ram, 0xFF53, 0), 8) ||| Map.get(ram, 0xFF54, 0)) &&& 0x1FF0)
    blocks = (value &&& 0x7F) + 1

    cond do
      (value &&& 0x80) != 0 ->
        Map.put(ram, :hdma, {src, dst, blocks})

      Map.has_key?(ram, :hdma) ->
        {_s, _d, remaining} = Map.get(ram, :hdma)

        ram
        |> Map.delete(:hdma)
        |> Map.put(0xFF55, 0x80 ||| (remaining - 1 &&& 0x7F))

      true ->
        ram
        |> Map.put(:gdma, {src, dst, blocks})
        |> Map.put(0xFF55, 0xFF)
    end
  end

  # VBK (0xFF4F): the GBC's VRAM bank — 0 on bare keys, 1 shifted.
  defp ram_write(ram, 0xFF4F, value) do
    ram
    |> Map.put(0xFF4F, value &&& 1)
    |> Map.put(:vram_base, (value &&& 1) * 0x10000)
  end

  # SVBK (0xFF70): the high WRAM bank — 1 to 7, zero counts as one.
  defp ram_write(ram, 0xFF70, value) do
    bank = max(value &&& 0x07, 1)

    ram
    |> Map.put(0xFF70, bank)
    |> Map.put(:wram_base, (bank - 1) * 0x10000)
  end

  # The colour palettes: BCPS/OCPS carry the index (bit 7: auto-increment),
  # BCPD/OCPD write the byte — stored off-bus, at 0x20000 + index (background) and
  # 0x20040 + index (sprites), where the colour PPU will come and read it.
  defp ram_write(ram, 0xFF69, value), do: cpal_write(ram, 0xFF68, 0x20000, value)
  defp ram_write(ram, 0xFF6B, value), do: cpal_write(ram, 0xFF6A, 0x20040, value)

  defp ram_write(ram, addr, value), do: Map.put(ram, addr, value)

  @doc "Reads a byte with the full cartridge semantics — the DMAs' route in."
  @spec peek(rom(), ram(), 0..0xFFFF) :: 0..0xFF
  def peek(rom, ram, addr), do: mem_read(rom, ram, addr)

  @doc "Writes a byte with the full cartridge semantics — banking included."
  @spec poke(ram(), 0..0xFFFF, 0..0xFF) :: ram()
  def poke(ram, addr, value), do: ram_write(ram, addr, value)

  # ── The MBC3's real-time clock ──────────────────────────────────────────────

  # Seconds, minutes, hours, days (9 bits) — served from the Mac's own clock:
  # Pokémon's day/night cycle follows your window.
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
    # ATOMBOY_RTC_OFFSET (in seconds) shifts the clock that gets served — the tool
    # for hunting time-dependent bugs, and for time travel when growing berries.
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
