defmodule Potion.Runtime do
  @moduledoc """
  Potion's SM83 runtime, written as data.

  A Potion game is not a program that would run on its own: it is an *actor* —
  a few dozen bytes that read a pad and move a sprite. Everything that separates
  those bytes from a console displaying something is here: turning the screen on,
  keeping the OAM, beating to the rhythm of the vblank, calling the actor once
  per frame.

  This module emits no bytes. It returns **program fragments** in the
  `Potion.Assembler` format — lists of tuples. The kernel is therefore a value,
  which can be concatenated, inspected, sliced, and part of which gets assembled
  separately to be copied elsewhere in memory (the DMA routine, further down). A
  kernel written out as bytes by hand would have none of these properties.

  ## The memory map

      0xC000-0xC09F   the OAM mirror — the 40 sprite entries, in WRAM
      0xC0A0          the pad state, recomposed each frame
      0xC0A1          the "frame ready" flag
      0xC0A2-0xC0FF   reserved for the kernel
      0xC100-0xC1FF   the actor's state — cleared at startup, free afterwards
      0xDFFF          the top of the stack
      0xFF80-0xFF89   the DMA routine, copied into HRAM by the init

  The actor writes its sprites into the OAM mirror, never into the real OAM:
  entry 0 at 0xC000 (Y+16), 0xC001 (X+8), 0xC002 (tile), 0xC003 (attributes).
  The offsets of 16 and 8 are the hardware's own — the OAM stores the position of
  the *extended bottom-right corner*, which lets a sprite leave the screen
  through the top or the left. The next vblank's DMA publishes the whole lot in
  one block.

  ## Why a mirror, and why the DMA from HRAM

  The OAM is only readable by the CPU during the vblank; outside it, the PPU
  scans it and the bus belongs to the PPU. A game writing its sprites as its
  logic unfolds would therefore be writing into the void one frame out of two.
  Hence the mirror in WRAM, accessible at all times, and publication by a single
  transfer once the panel falls silent.

  That transfer is a hardware DMA: the game writes the source page into 0xFF46
  and the controller copies 160 bytes on its own. During those 160 cycles, the
  CPU no longer has access to the main bus — neither ROM nor WRAM. The only
  memory left to it is HRAM, those 127 bytes wired into the processor itself. A
  `CALL` to a routine still sitting in ROM would therefore read nothingness on
  the very next instruction. So the kernel copies the routine to 0xFF80 at
  startup and calls it there: it is the most counter-intuitive hardware
  constraint of the console, and the first place where a Potion ROM has to look
  like a real one.

  Our emulator, for its part, executes the DMA in one go when 0xFF46 is written,
  and would let a routine left in ROM slip through. We write the real one
  anyway: a ROM that only ran on our machine would prove nothing.

  ## The heartbeat

  The init arms the vblank interrupt, and *only* that one (IE = 0x01). The main
  loop is then a `HALT`: the processor sleeps, the vblank wakes it, the handler
  raises the flag, the loop reads the pad, calls each actor in turn, and goes
  back to sleep. That is the scheduler: one slot per actor, called in
  declaration order, and the beat is the vblank rather than a count of cycles.

  The flag is not decoration. `HALT` wakes on *any* serviced interrupt, and
  others will come (the timer, the joypad, STAT) the day the kernel arms them;
  the flag tells "this is a new frame" apart from "someone woke me". Without it,
  the actor would run at a rhythm unknown to it.

  ## The v0's two tiles

  Tile 0 is a solid square — the sprite. Tile 1 is empty, and the init fills the
  whole background map (0x9800-0x9BFF) with tile 1.

  That map is the only departure from a strictly minimal kernel, and it is
  forced: a cleared VRAM leaves the background map at zero, hence at tile 0 — the
  solid square. The background would then be a black expanse, with the sprite
  invisible on top of it. Turning the background off (LCDC bit 0) would be the
  other way out, but a game without a background layer is not a Game Boy; so we
  fill.
  """

  alias Potion.Assembler

  # ── The registers we touch ──────────────────────────────────────────────────

  @p1 0x00
  @div 0x04
  @lcdc 0x40
  @scy 0x42
  @scx 0x43
  @ly 0x44
  @dma 0x46
  @bgp 0x47
  @obp0 0x48
  @irq_if 0x0F
  @irq_ie 0xFF

  # ── The memory map ──────────────────────────────────────────────────────────

  @oam_mirror 0xC000
  @pad 0xC0A0
  @flag 0xC0A1
  @state 0xC100
  @hram_dma 0xFF80
  @stack 0xDFFF

  # The whole VRAM, the background map, and the page of WRAM the init clears:
  # the OAM mirror, the kernel's cells, and the actor's state.
  @vram 0x8000
  @vram_bytes 0x2000
  @background 0x9800
  @wram_cleared 0x0200

  # LCD on, tile data at 0x8000 (unsigned indices), OBJ and BG on. 0x93 is what
  # very nearly every DMG game writes.
  @lcdc_on 0x93

  # The identity palette: colour 0 → shade 0, 1 → 1, 2 → 2, 3 → 3.
  @palette 0xE4

  @doc """
  The complete program: the init, the kernel, then the actor's code.

  Ready for `Potion.ROM.build(program, vblank: :vblank)` — without that option
  vector 0x40 stays zeros and the first serviced interrupt would execute
  padding.

  The `actor` fragment does not have to name itself: the kernel places the
  `:actor` label right before it. It must, however, end with a `{:ret}` — it is
  a `CALL` that reaches it, and an actor overflowing its fragment carries on
  into the bytes that follow, that is, into the cartridge's padding. The check
  happens here, at assembly time, because at run time the symptom would be an
  illegal opcode thousands of cycles away from its cause.
  """
  @spec program([Assembler.element()]) :: [Assembler.element()]
  def program(actors) when is_list(actors) do
    fragments = fragments(actors)
    Enum.each(fragments, &check_actor!/1)

    init() ++
      vblank() ++
      read_pad() ++
      main_loop(length(fragments)) ++
      [{:label, :dma_source}, {:bytes, dma_bytes()}] ++
      Enum.flat_map(Enum.with_index(fragments), fn {fragment, slot} ->
        [{:label, actor_label(slot)}] ++ fragment
      end)
  end

  @doc """
  The label the kernel calls for the actor in a given slot.

  Numbered rather than named: the kernel schedules positions, and it is the
  language above that knows an actor is called `:ball`.
  """
  @spec actor_label(non_neg_integer()) :: atom()
  def actor_label(slot), do: :"actor_#{slot}"

  # One fragment or several. A fragment is a list of tuples, a list of fragments
  # a list of lists -- the two cannot be confused, and accepting both means the
  # hand-written actors that predate the scheduler still read as they did.
  defp fragments([head | _] = actors) when is_list(head), do: actors
  defp fragments(actor), do: [actor]

  defp check_actor!(actor) do
    case List.last(actor) do
      {:ret} ->
        :ok

      other ->
        raise ArgumentError, """
        the actor does not end with a RET: #{inspect(other)}

        The kernel reaches the actor through a CALL, once per frame. Without a \
        closing RET, execution carries on into whatever follows the fragment — \
        the cartridge's padding, then the VRAM.
        """
    end
  end

  @doc """
  The address of the OAM mirror — entry 0 starts there.
  """
  @spec oam_mirror() :: 0xC000
  def oam_mirror, do: @oam_mirror

  @doc "The pad state cell, recomposed on every frame by the kernel."
  @spec pad() :: 0xC0A0
  def pad, do: @pad

  @doc "The \"frame ready\" flag: raised by the handler, consumed by the loop."
  @spec frame_flag() :: 0xC0A1
  def frame_flag, do: @flag

  @doc "The first address left to the actor."
  @spec actor_state() :: 0xC100
  def actor_state, do: @state

  @doc "The address of the DMA routine in HRAM."
  @spec hram_dma() :: 0xFF80
  def hram_dma, do: @hram_dma

  # ══ The init ═════════════════════════════════════════════════════════════════

  @doc """
  Startup: from the state the boot ROM leaves behind to a machine with a pulse.

  In order, and the order matters: cut the interrupts, place the stack, wait for
  the vblank *before* touching the LCD (turning it off mid visible line damages
  real panels), clear the VRAM that nothing has initialised, install the tiles
  and the background map, copy the DMA into HRAM, set the palettes, and only
  then turn the screen back on and open the interrupts.
  """
  @spec init() :: [Assembler.element()]
  def init do
    [
      {:label, :init},
      {:di},
      {:ld, :sp, @stack},
      # DIV reset to zero: the only counter running since the boot, and the only
      # grain of randomness a v0 game would have. Might as well start from a
      # known state — a golden frame cannot be compared against a machine that
      # started at some other instant.
      {:xor, :a, :a},
      {:ldh, {:high, @div}, :a}
    ] ++
      wait_vblank() ++
      [
        # LCD off: the PPU lets go of the bus, the VRAM becomes writable from
        # one end to the other. The same zero serves to recentre the background
        # — SCX and SCY come out of the boot at zero on DMG, but nothing
        # requires them to.
        {:xor, :a, :a},
        {:ldh, {:high, @lcdc}, :a},
        {:ldh, {:high, @scy}, :a},
        {:ldh, {:high, @scx}, :a}
      ] ++
      clear(@vram, @vram_bytes, :clear_vram) ++
      clear(@oam_mirror, @wram_cleared, :clear_wram) ++
      bg_map() ++
      tiles() ++
      copy_dma() ++
      [
        {:ld, :a, @palette},
        {:ldh, {:high, @bgp}, :a},
        {:ldh, {:high, @obp0}, :a},
        # IF wiped before opening up: the vblank wait above left bit 0 raised.
        # Without that sweep, the first EI would service a ghost frame and the
        # actor would run twice for a single panel.
        {:xor, :a, :a},
        {:ldh, {:high, @irq_if}, :a},
        {:ld, :a, 0x01},
        {:ldh, {:high, @irq_ie}, :a},
        {:ld, :a, @lcdc_on},
        {:ldh, {:high, @lcdc}, :a},
        {:ei},
        {:jp, {:label, :main_loop}}
      ]
  end

  # Poll LY until the vblank. This is the busy wait of real games — there is
  # nothing else to do before the interrupts are armed, and the hardware offers
  # no "wait" that is not a loop.
  defp wait_vblank do
    [
      {:label, :wait_vblank},
      {:ldh, :a, {:high, @ly}},
      {:cp, :a, 144},
      {:jr, :c, {:label, :wait_vblank}}
    ]
  end

  # A range zeroed out: 256 turns of a body unrolled as many times as needed.
  # `LD (HL+), A` costs 8 cycles, ending the loop 16 more — a loop with a single
  # write would spend two thirds of its time counting, and the whole VRAM would
  # take it three frames. Unrolled thirty-two times, it fits in one.
  #
  # `LD B, 0` then `DEC B`: 256 turns, the zero counting as a full turn. The
  # counter is the register, never a memory cell.
  defp clear(base, bytes, label) when rem(bytes, 256) == 0 do
    [
      {:ld, :hl, base},
      {:xor, :a, :a},
      {:ld, :b, 0},
      {:label, label}
    ] ++
      List.duplicate({:ld, {:mem, :hl_inc}, :a}, div(bytes, 256)) ++
      [
        {:dec, :b},
        {:jr, :nz, {:label, label}}
      ]
  end

  # The background map in tile 1 — the empty tile. The loop exit is read off H:
  # the map runs from 0x9800 to 0x9BFF, and 0x9C is the first high byte whose
  # bit 2 is raised. Testing a bit of a register costs less than maintaining a
  # counter, and the end address is already in HL.
  defp bg_map do
    [
      {:ld, :hl, @background},
      {:ld, :a, 0x01},
      {:label, :bg_map},
      {:ld, {:mem, :hl_inc}, :a},
      {:bit, 2, :h},
      {:jr, :z, {:label, :bg_map}}
    ]
  end

  # Tile 0: sixteen bytes of 0xFF, that is, eight lines of eight pixels in
  # colour 3 — a solid square. Two bitplanes set to 1 make colour 3, and that is
  # the whole v0 tileset. Tile 1 stays the one the clearing left behind.
  defp tiles do
    [
      {:ld, :hl, @vram},
      {:ld, :a, 0xFF},
      {:ld, :b, 16},
      {:label, :solid_tile},
      {:ld, {:mem, :hl_inc}, :a},
      {:dec, :b},
      {:jr, :nz, {:label, :solid_tile}}
    ]
  end

  # Copying the DMA routine into HRAM. Its length is not written by hand: it
  # comes from assembling the routine itself. That is the concrete benefit of a
  # kernel that is a value — the source and the measurement cannot diverge.
  defp copy_dma do
    [
      {:ld, :hl, {:label, :dma_source}},
      {:ld, :c, @hram_dma - 0xFF00},
      {:ld, :b, byte_size(dma_bytes())},
      {:label, :copy_dma},
      {:ld, :a, {:mem, :hl_inc}},
      {:ldh, {:high, :c}, :a},
      {:inc, :c},
      {:dec, :b},
      {:jr, :nz, {:label, :copy_dma}}
    ]
  end

  # ══ The vblank handler ═══════════════════════════════════════════════════════

  @doc """
  The vblank interrupt handler — the target of `Potion.ROM`'s `vblank:` option.

  It saves all four pairs: an interrupt lands between any two instructions of
  the main loop, and handing control back with a modified register is the kind
  of bug that shows up once every thousand frames.

  The flag is raised *before* the DMA. The order is free — the main loop cannot
  see anything before the RETI — and this one says what the flag really means:
  "a frame has begun", not "the OAM is published".
  """
  @spec vblank() :: [Assembler.element()]
  def vblank do
    [
      {:label, :vblank},
      {:push, :af},
      {:push, :bc},
      {:push, :de},
      {:push, :hl},
      {:ld, :a, 0x01},
      {:ld, {:mem, @flag}, :a},
      {:call, @hram_dma},
      {:pop, :hl},
      {:pop, :de},
      {:pop, :bc},
      {:pop, :af},
      {:reti}
    ]
  end

  @doc """
  The DMA routine, in its source form — the one that will be assembled apart and
  copied to 0xFF80.

  The wait is a countdown of forty turns at sixteen cycles: the 160 machine
  cycles the controller takes to copy the OAM. There is no register to poll —
  the hardware does not announce the end of a DMA, it has to be counted.
  """
  @spec dma_routine() :: [Assembler.element()]
  def dma_routine do
    [
      {:ld, :a, div(@oam_mirror, 0x100)},
      {:ldh, {:high, @dma}, :a},
      {:ld, :a, 40},
      {:label, :wait},
      {:dec, :a},
      {:jr, :nz, {:label, :wait}},
      {:ret}
    ]
  end

  @doc """
  The bytes of the DMA routine, assembled at its execution address.

  The 0xFF80 origin is not decorative: the routine's labels name absolute
  addresses, and assembling it at 0x0150 would give a correct relative jump by
  accident (JR counts a distance) but any evolution — a `JP`, a table — would
  come out wrong. Assembled apart, the routine also has its own label space: its
  `:wait` cannot collide with the kernel's.
  """
  @spec dma_bytes() :: binary()
  def dma_bytes, do: Assembler.assemble(dma_routine(), origin: @hram_dma)

  # ══ The pad ══════════════════════════════════════════════════════════════════

  @doc """
  Reading the pad, recomposed into a byte the right way round.

  P1 (0xFF00) is a matrix register: the game pulls one of the two rows to ground
  (bit 4 the directions, bit 5 the buttons — active at *zero*) and reads back
  four lines in the low nibble, themselves also active at zero. Two levels of
  inverted logic that no game wants anywhere near its own logic.

  The kernel pays for them once and for all: `CPL` puts the keys the right way
  round, `SWAP` files the buttons into the high nibble, and 0xC0A0 carries a
  byte where a bit set to 1 means "pressed":

      bit 0 Right    bit 1 Left     bit 2 Up       bit 3 Down
      bit 4 A        bit 5 B        bit 6 Select   bit 7 Start

  Reading each row twice is a hardware rite: the lines are pull-up resistors,
  they take a few cycles to settle after a change of selection, and the first
  read can lie. It costs nothing and one day it will spare us a bug we would not
  know how to name.
  """
  @spec read_pad() :: [Assembler.element()]
  def read_pad do
    [{:label, :read_pad}] ++
      row(0x20) ++
      [{:ld, :b, :a}] ++
      row(0x10) ++
      [
        {:swap, :a},
        {:or, :a, :b},
        {:ld, {:mem, @pad}, :a},
        # Both rows released: that is the register's resting state, and the one
        # an outside reader (the hardware reset combo, for instance) expects
        # between two frames.
        {:ld, :a, 0x30},
        {:ldh, {:high, @p1}, :a},
        {:ret}
      ]
  end

  defp row(selection) do
    [
      {:ld, :a, selection},
      {:ldh, {:high, @p1}, :a},
      {:ldh, :a, {:high, @p1}},
      {:ldh, :a, {:high, @p1}},
      {:cpl},
      {:and, :a, 0x0F}
    ]
  end

  # ══ The main loop ════════════════════════════════════════════════════════════

  @doc """
  The scheduler: sleep, wake on the vblank, read the pad, call each actor in
  turn, go back to sleep.

  `HALT` is not a battery saving here, it is the system's only clock: it gives
  the kernel a rhythm of exactly one frame, without counting a single cycle. A
  loop polling LY would work too, and would drift as soon as the actors grew.

  The slots run in declaration order, every frame, with nothing between them: an
  actor that writes a cell another one reads will be read in that order, always.
  That is the whole scheduling contract, and it is worth stating because it is
  the one an actor cannot check for itself.
  """
  @spec main_loop(pos_integer()) :: [Assembler.element()]
  def main_loop(slots \\ 1) when slots >= 1 do
    calls = for slot <- 0..(slots - 1), do: {:call, {:label, actor_label(slot)}}

    [
      {:label, :main_loop},
      {:halt},
      # Awake: where from? With no flag raised, it was not a frame.
      {:ld, :a, {:mem, @flag}},
      {:and, :a, :a},
      {:jr, :z, {:label, :main_loop}},
      {:xor, :a, :a},
      {:ld, {:mem, @flag}, :a},
      {:call, {:label, :read_pad}},
      calls,
      {:jr, {:label, :main_loop}}
    ]
    |> List.flatten()
  end
end
