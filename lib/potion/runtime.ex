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

  ## The tiles

  Tile 0 is a solid square — the sprite. Tile 1 is empty, and the init fills the
  whole background map (0x9800-0x9BFF) with tile 1. Tiles 2 to 11 are the ten
  digits, copied from ROM at startup: a score is the first thing a game wants to
  say in words rather than in sprites, and it is also the cheapest — 160 bytes
  and a copy loop, against one OAM entry per figure.

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
  @nr10 0x10
  @nr11 0x11
  @nr12 0x12
  @nr13 0x13
  @nr14 0x14

  @nr30 0x1A
  @nr32 0x1C
  @nr33 0x1D
  @nr34 0x1E
  @wave 0xFF30

  @nr21 0x16
  @nr22 0x17
  @nr23 0x18
  @nr24 0x19

  @nr41 0x20
  @nr42 0x21
  @nr43 0x22
  @nr44 0x23

  @nr50 0x24
  @nr51 0x25
  @nr52 0x26

  @bgp 0x47
  @obp0 0x48
  @irq_if 0x0F
  @irq_ie 0xFF

  # ── The memory map ──────────────────────────────────────────────────────────

  @oam_mirror 0xC000
  @pad 0xC0A0
  @flag 0xC0A1
  # The music player's own cells, in the page the kernel keeps for itself: where
  # the tune is being read from, where it started so it can loop, and how many
  # frames the current step has left. A pointer of zero is silence, which is what
  # the init's clearing leaves behind.
  # Which instance of a pooled actor is running. One cell for all of them: actors
  # run one at a time and never nest, so there is never a second answer.
  @me 0xC0A1 + 1
  @tune 0xC0A3
  @tune_base 0xC0A5
  @tune_wait 0xC0A7

  # The bass, on the wave channel: the same three, a second time.
  @bass 0xC0A8
  @bass_base 0xC0AA
  @bass_wait 0xC0AC

  # Which square the lead is: `play` writes it, the player reads it on every note.
  @tune_duty 0xC0AD

  # The harmony, on channel 2 -- the same three cells a third time.
  @harmony 0xC0AE
  @harmony_base 0xC0B0
  @harmony_wait 0xC0B2

  # The vibrato. `@wobble` holds which table of deviations is in use, or zero for
  # none; each pulse voice keeps the frequency its note was struck at and how far
  # into the wobble it has walked.
  @wobble 0xC0B3
  @lead_pitch 0xC0B5
  @lead_phase 0xC0B7
  @harm_pitch 0xC0B8
  @harm_phase 0xC0BA

  # The envelope the tune's pulse notes take: `play` writes it, both pulse
  # players read it on every note.
  @tune_env 0xC0BB

  # Where the current room's bytes live in ROM -- `show` writes it, `touching?`
  # reads it -- and the tile a `touching?` is asking about.
  @current_room 0xC0BC
  @probe 0xC0BE

  # The `random` routine's state: one byte, stirred with DIV on every draw. The
  # init's clearing seeds it with zero, and the hardware un-seeds it from there.
  @rng 0xC0BF

  @state 0xC100
  @hram_dma 0xFF80
  @stack 0xDFFF

  # The whole VRAM, the background map, and the page of WRAM the init clears:
  # the OAM mirror, the kernel's cells, and the actor's state.
  @vram 0x8000
  @vram_bytes 0x2000
  @background 0x9800
  @digits 2

  # Five columns of ink in an eight-wide tile, with the last row left blank so
  # two lines of digits do not touch.
  @font [
    [0x3C, 0x66, 0x6E, 0x7E, 0x76, 0x66, 0x3C, 0x00],
    [0x18, 0x38, 0x18, 0x18, 0x18, 0x18, 0x7E, 0x00],
    [0x3C, 0x66, 0x06, 0x0C, 0x18, 0x30, 0x7E, 0x00],
    [0x3C, 0x66, 0x06, 0x1C, 0x06, 0x66, 0x3C, 0x00],
    [0x0C, 0x1C, 0x3C, 0x6C, 0x7E, 0x0C, 0x0C, 0x00],
    [0x7E, 0x60, 0x7C, 0x06, 0x06, 0x66, 0x3C, 0x00],
    [0x1C, 0x30, 0x60, 0x7C, 0x66, 0x66, 0x3C, 0x00],
    [0x7E, 0x66, 0x06, 0x0C, 0x18, 0x18, 0x18, 0x00],
    [0x3C, 0x66, 0x66, 0x3C, 0x66, 0x66, 0x3C, 0x00],
    [0x3C, 0x66, 0x66, 0x3E, 0x06, 0x0C, 0x38, 0x00]
  ]

  # The alphabet, five columns wide and seated at the same bits as the digits.
  # Uppercase only, which is what a Game Boy font is: lowercase would double the
  # VRAM for glyphs a title screen does not use. `text` upcases what it is given.
  #
  # A space is not here. It is tile 1 -- the empty one the init already fills the
  # whole background map with -- so a gap between two words costs nothing that
  # was not already spent.
  @letters [
    # A
    [0x38, 0x44, 0x44, 0x7C, 0x44, 0x44, 0x44, 0x00],
    # B
    [0x78, 0x44, 0x78, 0x44, 0x44, 0x44, 0x78, 0x00],
    # C
    [0x38, 0x44, 0x40, 0x40, 0x40, 0x44, 0x38, 0x00],
    # D
    [0x78, 0x44, 0x44, 0x44, 0x44, 0x44, 0x78, 0x00],
    # E
    [0x7C, 0x40, 0x78, 0x40, 0x40, 0x40, 0x7C, 0x00],
    # F
    [0x7C, 0x40, 0x78, 0x40, 0x40, 0x40, 0x40, 0x00],
    # G
    [0x38, 0x44, 0x40, 0x4C, 0x44, 0x44, 0x38, 0x00],
    # H
    [0x44, 0x44, 0x7C, 0x44, 0x44, 0x44, 0x44, 0x00],
    # I
    [0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x00],
    # J
    [0x04, 0x04, 0x04, 0x04, 0x44, 0x44, 0x38, 0x00],
    # K
    [0x44, 0x48, 0x50, 0x60, 0x50, 0x48, 0x44, 0x00],
    # L
    [0x40, 0x40, 0x40, 0x40, 0x40, 0x40, 0x7C, 0x00],
    # M
    [0x44, 0x6C, 0x54, 0x44, 0x44, 0x44, 0x44, 0x00],
    # N
    [0x44, 0x64, 0x54, 0x4C, 0x44, 0x44, 0x44, 0x00],
    # O
    [0x38, 0x44, 0x44, 0x44, 0x44, 0x44, 0x38, 0x00],
    # P
    [0x78, 0x44, 0x44, 0x78, 0x40, 0x40, 0x40, 0x00],
    # Q
    [0x38, 0x44, 0x44, 0x44, 0x54, 0x48, 0x34, 0x00],
    # R
    [0x78, 0x44, 0x44, 0x78, 0x50, 0x48, 0x44, 0x00],
    # S
    [0x3C, 0x40, 0x40, 0x38, 0x04, 0x04, 0x78, 0x00],
    # T
    [0x7C, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x00],
    # U
    [0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x38, 0x00],
    # V
    [0x44, 0x44, 0x44, 0x44, 0x44, 0x28, 0x10, 0x00],
    # W
    [0x44, 0x44, 0x44, 0x44, 0x54, 0x6C, 0x44, 0x00],
    # X
    [0x44, 0x44, 0x28, 0x10, 0x28, 0x44, 0x44, 0x00],
    # Y
    [0x44, 0x44, 0x28, 0x10, 0x10, 0x10, 0x10, 0x00],
    # Z
    [0x7C, 0x04, 0x08, 0x10, 0x20, 0x40, 0x7C, 0x00],
    # .
    [0x00, 0x00, 0x00, 0x00, 0x00, 0x30, 0x30, 0x00],
    # ,
    [0x00, 0x00, 0x00, 0x00, 0x30, 0x30, 0x20, 0x00],
    # !
    [0x10, 0x10, 0x10, 0x10, 0x10, 0x00, 0x10, 0x00],
    # ?
    [0x38, 0x44, 0x04, 0x18, 0x10, 0x00, 0x10, 0x00],
    # -
    [0x00, 0x00, 0x00, 0x7C, 0x00, 0x00, 0x00, 0x00],
    # :
    [0x00, 0x30, 0x30, 0x00, 0x30, 0x30, 0x00, 0x00]
  ]

  # Where a game's own tiles begin: after the solid square, the empty one, and
  # the ten digits. A game never writes this number — it names a tile and the
  # compiler adds the base, exactly as `digit:` does.
  @alphabet 12
  @art 44

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
  @spec program([Assembler.element()], binary(), [{atom(), binary()}]) :: [Assembler.element()]
  def program(actors, art \\ <<>>, tunes \\ [], rooms \\ [])
      when is_list(actors) and is_binary(art) do
    fragments = fragments(actors)
    Enum.each(fragments, &check_actor!/1)
    art!(art)

    init(art) ++
      vblank() ++
      read_pad() ++
      play_music() ++
      main_loop(length(fragments)) ++
      [{:label, :dma_source}, {:bytes, dma_bytes()}] ++
      [{:label, :font_data}, {:bytes, font_bytes()}] ++
      [{:label, :letter_data}, {:bytes, letter_bytes()}] ++
      [{:label, :wave_data}, {:bytes, wave_bytes()}] ++
      [{:label, :wobble_gentle}, {:bytes, wobble_bytes(:gentle)}] ++
      [{:label, :wobble_deep}, {:bytes, wobble_bytes(:deep)}] ++
      art_data(art) ++
      Enum.flat_map(tunes, fn {name, voices} ->
        [{:label, :"potion_tune_#{name}"}, {:bytes, voices.lead}] ++
          bytes_for(:"potion_harmony_#{name}", voices.harmony) ++
          bytes_for(:"potion_bass_#{name}", voices.bass)
      end) ++
      Enum.flat_map(rooms, fn {name, bytes} ->
        [{:label, :"potion_room_#{name}"}, {:bytes, bytes}]
      end) ++
      Enum.flat_map(Enum.with_index(fragments), fn {fragment, slot} ->
        [{:label, actor_label(slot)}] ++ fragment
      end)
  end

  defp bytes_for(_label, <<>>), do: []
  defp bytes_for(label, bytes), do: [{:label, label}, {:bytes, bytes}]

  defp art_data(<<>>), do: []
  defp art_data(art), do: [{:label, :art_data}, {:bytes, art}]

  # 256 tiles answer to an unsigned index, and the kernel has spoken for the
  # first twelve. The check is here rather than at the drawing, because it is
  # only here that the kernel's own tiles and the game's are counted together.
  defp art!(art) do
    tiles = div(byte_size(art), 16)

    if @art + tiles > 256 do
      raise ArgumentError, """
      #{tiles} tiles of art, and there is room for #{256 - @art}.

      Tile data at 0x8000 is addressed by an unsigned byte, so a game has 256 of \
      them and the kernel keeps the first #{@art}: the solid square, the empty \
      one the background is filled with, and the ten digits.
      """
    end
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

  @doc """
  The tile index of the digit `0`; the ten follow it in order.

  Tiles 0 and 1 belong to the kernel -- the solid square and the empty one --
  so the font starts at 2. A game rarely needs the number: `background(c, r,
  digit: n)` adds it, which is the whole point of spelling `digit:` rather than
  `tile:`.
  """
  @spec digits() :: 2
  def digits, do: @digits

  @doc "The first byte of the background map."
  @spec background_map() :: 0x9800
  def background_map, do: @background

  @doc """
  Where a square of the background map lives.

  The map is 32 tiles wide, of which the screen shows 20; a row is therefore 32
  bytes, and the eleven past the twentieth are off-screen unless the game
  scrolls.

      iex> Potion.Runtime.background_address(0, 0)
      0x9800

      iex> Potion.Runtime.background_address(2, 1)
      0x9822
  """
  @spec background_address(0..31, 0..31) :: 0x9800..0x9BFF
  def background_address(column, row)
      when column in 0..31 and row in 0..31 do
    @background + row * 32 + column
  end

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
  @spec init(binary()) :: [Assembler.element()]
  def init(art \\ <<>>) do
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
      font() ++
      letters() ++
      art(art) ++
      copy_dma() ++
      sound_on() ++
      wave_table() ++
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
  # The ten digits, copied into VRAM behind the kernel's two tiles.
  #
  # A score is the first thing a game wants to say in words rather than in
  # sprites, and it is also the cheapest: ten tiles, 160 bytes of ROM, and a
  # copy loop the init runs once. Sprites could spell it too -- the OAM holds
  # forty -- but they would ride above the playfield and cost an entry each.
  defp font do
    [
      {:ld, :hl, {:label, :font_data}},
      {:ld, :de, @vram + @digits * 16},
      {:ld, :b, 10 * 16},
      {:label, :copy_font},
      {:ld, :a, {:mem, :hl_inc}},
      {:ld, {:mem, :de}, :a},
      {:inc, :de},
      {:dec, :b},
      {:jr, :nz, {:label, :copy_font}}
    ]
  end

  @doc """
  The font's bytes: ten digits, 8x8, in the Game Boy's two-plane format.

  Both planes carry the same bitmap, which puts the ink at colour 3 -- the same
  the solid tile uses, so a digit and a sprite are the same black.
  """
  @spec font_bytes() :: binary()
  def font_bytes do
    for glyph <- @font, row <- glyph, into: <<>>, do: <<row, row>>
  end

  @doc """
  The tile index of the letter `A`; the alphabet then the punctuation follow it.

  The order is the one `Potion.Compiler` maps characters through, and it is
  written down in one place: A to Z, then `.` `,` `!` `?` `-` `:`.
  """
  @spec alphabet() :: non_neg_integer()
  def alphabet, do: @alphabet

  @doc "The alphabet's bytes, in the Game Boy's two-plane format."
  @spec letter_bytes() :: binary()
  def letter_bytes do
    for glyph <- @letters, row <- glyph, into: <<>>, do: <<row, row>>
  end

  @doc """
  Channel 2's four registers: duty and length, envelope, frequency low, and the
  one that carries the trigger.

  The simple pulse, and the reason it is the one a `beep` uses: channel 1 is the
  same generator with a frequency sweep bolted on, and leaving it alone leaves a
  voice for whatever wants to slide.
  """
  @spec pulse() :: {byte(), byte(), byte(), byte()}
  def pulse, do: {0x16, 0x17, 0x18, 0x19}

  @doc """
  Channel 4's four: length, envelope, the noise's own shape, and the trigger.

  There is no frequency here. The channel is a shift register clocked by a
  divisor and a shift — `NR43` — so what a game chooses is how coarse the noise
  is, not what pitch it is. `Potion.Compiler` holds the four it names.
  """
  @spec noise() :: {byte(), byte(), byte(), byte()}
  def noise, do: {@nr41, @nr42, @nr43, @nr44}

  @doc "Channel 1's five, the one the tune plays on: sweep, duty, envelope, frequency."
  @spec pulse_one() :: {byte(), byte(), byte(), byte(), byte()}
  def pulse_one, do: {@nr10, @nr11, @nr12, @nr13, @nr14}

  @doc """
  The two palette registers, background then sprites.

  A fade on this console is not a fade at all: there is nothing to blend. What
  there is, is a table saying which of the four greys each shade prints as, and
  darkening a picture means rewriting that table. `Potion.Compiler` holds the
  four steps.
  """
  @spec palettes() :: {byte(), byte()}
  def palettes, do: {@bgp, @obp0}

  @doc "The tile index a game's own art starts at."
  @spec art_base() :: non_neg_integer()
  def art_base, do: @art

  # The game's tiles, on the font's pattern with one difference that matters:
  # the counter is sixteen bits. The font is 160 bytes and fits in B; a sheet is
  # whatever was drawn, and forty tiles is already 640. `DEC BC` sets no flags on
  # this processor -- that is the reason for the `LD A, B / OR C` rather than
  # forgetfulness -- so the loop tests the pair by hand.
  defp art(<<>>), do: []

  defp art(bytes) do
    [
      {:ld, :hl, {:label, :art_data}},
      {:ld, :de, @vram + @art * 16},
      {:ld, :bc, byte_size(bytes)},
      {:label, :copy_art},
      {:ld, :a, {:mem, :hl_inc}},
      {:ld, {:mem, :de}, :a},
      {:inc, :de},
      {:dec, :bc},
      {:ld, :a, :b},
      {:or, :a, :c},
      {:jr, :nz, {:label, :copy_art}}
    ]
  end

  # The alphabet, copied like the digits and for the same reason: a game that
  # wants to say PRESS START should not have to spend an OAM entry a letter.
  @doc """
  The four cells and the routine that make a tune play itself.

  Called by the main loop every frame, right after the pad and before the
  actors, so a game that starts a tune hears it from the next frame and never
  has to feed it. That placement is the whole design: a game says `play(:theme)`
  once and the kernel owns the beat, exactly as it owns the vblank.

  A pointer of zero is silence, and zero is what the init's clearing leaves — so
  a game that never mentions music costs three instructions a frame and no
  thought.
  """
  @spec music_cells() :: {non_neg_integer(), non_neg_integer(), non_neg_integer()}
  def music_cells, do: {@tune, @tune_base, @tune_wait}

  @doc "The same three for the bass, which plays on the wave channel."
  @spec bass_cells() :: {non_neg_integer(), non_neg_integer(), non_neg_integer()}
  def bass_cells, do: {@bass, @bass_base, @bass_wait}

  @doc "The cell holding the lead's duty, which `play` sets from the tune."
  @spec duty_cell() :: non_neg_integer()
  def duty_cell, do: @tune_duty

  @doc "The harmony's three, on channel 2 -- the one `beep` borrows."
  @spec harmony_cells() :: {non_neg_integer(), non_neg_integer(), non_neg_integer()}
  def harmony_cells, do: {@harmony, @harmony_base, @harmony_wait}

  @doc "The cell naming which wobble table is in use, or zero for none."
  @spec wobble_cell() :: non_neg_integer()
  def wobble_cell, do: @wobble

  @doc "The cell holding the envelope the tune's pulse notes take."
  @spec env_cell() :: non_neg_integer()
  def env_cell, do: @tune_env

  @doc "The pointer to the room `show` last painted; zero until one has been."
  @spec room_cell() :: non_neg_integer()
  def room_cell, do: @current_room

  @doc "The tile index a `touching?` is asking about, written by its call site."
  @spec probe_cell() :: non_neg_integer()
  def probe_cell, do: @probe

  @doc "The cell the `random` routine keeps its state in."
  @spec rng_cell() :: non_neg_integer()
  def rng_cell, do: @rng

  @doc """
  The two wobble tables, sixteen signed frames each.

  They open on four zeros, and that is the delay rather than a counter: a note
  is struck in tune, walks into the wobble, and comes back. A note shorter than
  four frames never leaves the zeros, which is what keeps a run of short notes
  from sounding seasick.

  The register is a period and not a pitch, so the same deviation is a different
  interval at every note — two units is some four hertz at c5 and a third of one
  at c2. That is why a game names a wobble instead of giving a number, and why
  the bass has none: on a low note these would be inaudible, and a table deep
  enough to hear down there would be a siren up top.
  """
  @spec wobble_bytes(:gentle | :deep) :: binary()
  def wobble_bytes(:gentle), do: wobble(2)
  def wobble_bytes(:deep), do: wobble(5)

  defp wobble(depth) do
    for step <- 0..15, into: <<>> do
      value =
        if step < 4 do
          0
        else
          round(depth * :math.sin((step - 4) / 12 * 2 * :math.pi()))
        end

      <<value::signed-8>>
    end
  end

  @doc "Channel 2's four, which the harmony and `beep` share."
  @spec pulse_two() :: {byte(), byte(), byte(), byte()}
  def pulse_two, do: {@nr21, @nr22, @nr23, @nr24}

  @doc "The wave channel's registers: DAC, volume, frequency, trigger."
  @spec wave() :: {byte(), byte(), byte(), byte()}
  def wave, do: {@nr30, @nr32, @nr33, @nr34}

  @doc """
  The 32 nibbles the wave channel steps through: a triangle, up and back down.

  Sixteen bytes, and the only shape the v0 offers. A triangle rather than a saw
  because a bass sits under a square lead and a saw fights it — and because the
  table is one constant, so the day a game wants to choose, this is what it
  chooses instead of.
  """
  @spec wave_bytes() :: binary()
  def wave_bytes do
    ramp = Enum.to_list(0..15) ++ Enum.to_list(15..0//-1)

    for [high, low] <- Enum.chunk_every(ramp, 2), into: <<>>, do: <<high::4, low::4>>
  end

  @doc "The cell holding which instance of a pooled actor is running."
  @spec me() :: non_neg_integer()
  def me, do: @me

  # Three bytes a step: frequency low, frequency high with the trigger bit, and
  # a count of frames. A length of zero is the end and sends the pointer back to
  # where it started, which is why a tune loops without saying so.
  defp play_music do
    voice(:play_music, {@tune, @tune_base, @tune_wait}, :pulse) ++
      voice(:play_harmony, {@harmony, @harmony_base, @harmony_wait}, :pulse_two) ++
      voice(:play_bass, {@bass, @bass_base, @bass_wait}, :wave) ++
      vibrato(:vibrato_lead, @lead_pitch, @lead_phase, {@nr13, @nr14}) ++
      vibrato(:vibrato_harmony, @harm_pitch, @harm_phase, {@nr23, @nr24}) ++
      show_room() ++ touching() ++ random() ++ divide()
  end

  defp voice(label, {tune, tune_base, tune_wait}, kind) do
    [
      {:label, label},
      # A pointer of zero means no tune. Both halves, because a tune could sit
      # at 0x0100-something and have a zero low byte.
      {:ld, :a, {:mem, tune}},
      {:ld, :b, :a},
      {:ld, :a, {:mem, tune + 1}},
      {:or, :a, :b},
      {:ret, :z},

      # Still inside the current step? Count down and leave.
      {:ld, :a, {:mem, tune_wait}},
      {:and, :a, :a},
      {:jr, :z, {:label, :"#{label}_step"}},
      {:dec, :a},
      {:ld, {:mem, tune_wait}, :a},
      {:ret},
      {:label, :"#{label}_step"},
      {:ld, :a, {:mem, tune}},
      {:ld, :l, :a},
      {:ld, :a, {:mem, tune + 1}},
      {:ld, :h, :a},

      # The third byte first: a zero length is the terminator, and the tune goes
      # back to its start rather than walking off into whatever follows it.
      {:inc, :hl},
      {:inc, :hl},
      {:ld, :a, {:mem, :hl}},
      {:and, :a, :a},
      {:jr, :nz, {:label, :"#{label}_sound"}},
      {:ld, :a, {:mem, tune_base}},
      {:ld, {:mem, tune}, :a},
      {:ld, :l, :a},
      {:ld, :a, {:mem, tune_base + 1}},
      {:ld, {:mem, tune + 1}, :a},
      {:ld, :h, :a},
      {:inc, :hl},
      {:inc, :hl},
      {:ld, :a, {:mem, :hl}},
      {:label, :"#{label}_sound"},

      # `frames` is in A. Keep it, then walk HL back to the step's first byte.
      {:ld, {:mem, tune_wait}, :a},
      {:dec, :hl},
      {:dec, :hl},
      {:ld, :a, {:mem, :hl_inc}},
      {:ld, :c, :a},
      {:ld, :a, {:mem, :hl_inc}},
      {:ld, :b, :a},
      {:inc, :hl},

      # HL now points at the next step: put it back before touching the channel.
      {:ld, :a, :l},
      {:ld, {:mem, tune}, :a},
      {:ld, :a, :h},
      {:ld, {:mem, tune + 1}, :a},

      # B holds the high byte. Without the trigger bit this step is a rest, and
      # a rest is the envelope taken to zero -- silence that does not restart
      # anything when the next note arrives.
      {:bit, 7, :b},
      {:jr, :nz, {:label, :"#{label}_note"}}
    ] ++
      hush(kind) ++
      [{:ret}, {:label, :"#{label}_note"}] ++
      sound(kind)
  end

  # A rest, which on either channel is the same idea said to a different
  # register: take the volume to nothing, without triggering anything, so the
  # note already sounding stops rather than being replaced.
  # A rest clears the remembered pitch as well, so the vibrato has nothing to
  # wobble until the next note gives it something.
  defp hush(:pulse),
    do: [{:xor, :a, :a}, {:ldh, {:high, @nr12}, :a}, {:ld, {:mem, @lead_pitch + 1}, :a}]

  defp hush(:pulse_two),
    do: [{:xor, :a, :a}, {:ldh, {:high, @nr22}, :a}, {:ld, {:mem, @harm_pitch + 1}, :a}]

  defp hush(:wave), do: [{:xor, :a, :a}, {:ldh, {:high, @nr32}, :a}]

  # A note. C holds the frequency's low byte and B its high byte with the
  # trigger already on it, which is the one thing the two channels share.
  #
  # No sweep, 50% duty, and a volume that does not decay: a tune wants a note
  # that lasts until the next one, which is the opposite of what `beep` asks of
  # channel 2.
  defp sound(:pulse) do
    [
      {:xor, :a, :a},
      {:ldh, {:high, @nr10}, :a},
      # The duty the tune asked for, rather than a fixed square. It is read every
      # note because a game may start another tune between two of them.
      {:ld, :a, {:mem, @tune_duty}},
      {:ldh, {:high, @nr11}, :a},
      {:ld, :a, {:mem, @tune_env}},
      {:ldh, {:high, @nr12}, :a},
      {:ld, :a, :c},
      {:ldh, {:high, @nr13}, :a},
      {:ld, :a, :b},
      {:ldh, {:high, @nr14}, :a}
    ] ++ remember(@lead_pitch, @lead_phase)
  end

  # Channel 2 is channel 1 without the sweep register, and it shares the duty
  # the tune asked for -- two pulses in parallel thirds want the same instrument,
  # and a harmony in a different one reads as a second melody rather than as
  # thickness.
  defp sound(:pulse_two) do
    [
      {:ld, :a, {:mem, @tune_duty}},
      {:ldh, {:high, @nr21}, :a},
      {:ld, :a, {:mem, @tune_env}},
      {:ldh, {:high, @nr22}, :a},
      {:ld, :a, :c},
      {:ldh, {:high, @nr23}, :a},
      {:ld, :a, :b},
      {:ldh, {:high, @nr24}, :a}
    ] ++ remember(@harm_pitch, @harm_phase)
  end

  # The wave channel has no envelope: its volume is a shift, and the DAC has to
  # be switched back on because a rest muted it.
  defp sound(:wave) do
    [
      {:ld, :a, 0x80},
      {:ldh, {:high, @nr30}, :a},
      {:ld, :a, 0x20},
      {:ldh, {:high, @nr32}, :a},
      {:ld, :a, :c},
      {:ldh, {:high, @nr33}, :a},
      {:ld, :a, :b},
      {:ldh, {:high, @nr34}, :a},
      {:ret}
    ]
  end

  # A room onto the panel: 360 bytes into the background map, with the LCD off
  # for the length of the copy.
  #
  # Off, because the copy cannot fit in a vblank -- 360 bytes is three times the
  # window -- and a write the PPU is scanning past is a write the real hardware
  # drops. One dark frame instead of a torn room, which is exactly what a room
  # change looked like on the consoles this one imitates. The emulator would
  # have allowed the writes; the ROM is written for the machine, not for its
  # emulator.
  #
  # HL arrives holding the room's first byte: the caller loads it, and HL is the
  # register everything here already clobbers freely.
  defp show_room do
    [
      {:label, :show_room},
      # The room being shown becomes the room being *in*: `touching?` reads its
      # bytes from ROM rather than from the map, so what a `text` or a
      # `background` scribbles over the picture never becomes an obstacle.
      {:ld, :a, :l},
      {:ld, {:mem, @current_room}, :a},
      {:ld, :a, :h},
      {:ld, {:mem, @current_room + 1}, :a},
      {:xor, :a, :a},
      {:ldh, {:high, @lcdc}, :a},
      {:ld, :de, @background},
      {:ld, :b, 18},
      {:label, :room_row},
      {:ld, :c, 20},
      {:label, :room_cell},
      {:ld, :a, {:mem, :hl_inc}},
      {:ld, {:mem, :de}, :a},
      {:inc, :de},
      {:dec, :c},
      {:jr, :nz, {:label, :room_cell}},
      # The map is 32 wide and the screen 20: walk past the 12 nobody sees.
      {:ld, :a, :e},
      {:add, :a, 12},
      {:ld, :e, :a},
      {:ld, :a, :d},
      {:adc, :a, 0},
      {:ld, :d, :a},
      {:dec, :b},
      {:jr, :nz, {:label, :room_row}},
      {:ld, :a, @lcdc_on},
      {:ldh, {:high, @lcdc}, :a},
      {:ret}
    ]
  end

  # Which tile of the current room a screen pixel stands on, against the one
  # the game asked about. A = y, C = x on entry; the probe cell holds the tile;
  # Z comes back set when they match.
  #
  # The room in ROM is 20 bytes a row -- packed, unlike the 32-wide map -- so
  # the cell is `base + (y/8) * 20 + x/8`. Twenty is sixteen plus four, two
  # runs of doublings and an add; the product reaches 340 and lives in HL.
  #
  # Before any room has been shown the pointer is the zero the init left, and
  # the answer is "touching nothing": flags forced to NZ and out. A game that
  # asks before it shows gets a walkable void, not a wall of accidents.
  defp touching do
    [
      {:label, :touching},
      {:ld, :b, :a},
      {:ld, :a, {:mem, @current_room}},
      {:ld, :l, :a},
      {:ld, :a, {:mem, @current_room + 1}},
      {:ld, :h, :a},
      {:or, :a, :l},
      {:jr, :nz, {:label, :touch_room}},
      {:or, :a, 1},
      {:ret},
      {:label, :touch_room},
      {:push, :hl},
      {:ld, :a, :b},
      {:srl, :a},
      {:srl, :a},
      {:srl, :a},
      {:ld, :l, :a},
      {:ld, :h, 0},
      {:add, :hl, :hl},
      {:add, :hl, :hl},
      {:ld, :d, :h},
      {:ld, :e, :l},
      {:add, :hl, :hl},
      {:add, :hl, :hl},
      {:add, :hl, :de},
      {:ld, :a, :c},
      {:srl, :a},
      {:srl, :a},
      {:srl, :a},
      {:ld, :c, :a},
      {:ld, :b, 0},
      {:add, :hl, :bc},
      {:pop, :de},
      {:add, :hl, :de},
      {:ld, :a, {:mem, :hl}},
      {:ld, :b, :a},
      {:ld, :a, {:mem, @probe}},
      {:cp, :a, :b},
      {:ret}
    ]
  end

  # A byte of noise, answered in A.
  #
  # The state is one cell walked through a rotation and an odd step, and stirred
  # on every draw with DIV -- the counter the hardware advances 16384 times a
  # second whether anyone is looking or not. Between two frames DIV moves by
  # 274 increments, 18 after the wrap, so *when* a draw happens decides what it
  # says: the player's timing is the seed, which is where every small generator
  # on this console got its numbers. Nothing runs per frame -- a game that never
  # asks pays twelve bytes of ROM and no time at all.
  #
  # It is a stirred counter, not a proven generator: plenty to pick a direction,
  # and unfit for anything that would mind the difference.
  defp random do
    [
      {:label, :random},
      {:ld, :hl, @rng},
      {:ldh, :a, {:high, @div}},
      {:add, :a, {:mem, :hl}},
      {:rlca},
      {:add, :a, 41},
      {:ld, {:mem, :hl}, :a},
      {:ret}
    ]
  end

  # The divide the processor does not have: restoring division, one bit a step.
  # D is the dividend on the way in and the quotient on the way out -- SLA
  # vacates its bottom bit exactly when INC needs it -- A collects the
  # remainder, C is the divisor, B counts the eight steps.
  #
  # The textbook routine carries a ninth-bit check after the RLA, for the
  # remainder that doubles past 255. Byte in, byte out, it cannot happen: the
  # remainder entering step k is a (k-1)-bit number -- it is a prefix of the
  # dividend, reduced -- so it is at most 127 before any doubling. Verified
  # against Elixir's `div` and `rem` over all 65280 pairs: zero mismatches,
  # zero carries. The branch would be dead weight in the frame's budget.
  defp divide do
    [
      {:label, :divide},
      {:xor, :a, :a},
      {:ld, :b, 8},
      {:label, :divide_step},
      {:sla, :d},
      {:rla},
      {:cp, :a, :c},
      {:jr, :c, {:label, :divide_skip}},
      {:sub, :a, :c},
      {:inc, :d},
      {:label, :divide_skip},
      {:dec, :b},
      {:jr, :nz, {:label, :divide_step}},
      {:ret}
    ]
  end

  # What the vibrato needs from a note: the frequency it was struck at, and a
  # phase back at the start of the table -- so every note is struck in tune and
  # walks into the wobble the same way.
  defp remember(pitch, phase) do
    [
      {:ld, :a, :c},
      {:ld, {:mem, pitch}, :a},
      {:ld, :a, :b},
      {:ld, {:mem, pitch + 1}, :a},
      {:xor, :a, :a},
      {:ld, {:mem, phase}, :a},
      {:ret}
    ]
  end

  # One pulse voice's wobble, a frame at a time. The frequency is rewritten with
  # the trigger bit clear, which changes the pitch of the note already sounding
  # rather than starting it again -- that distinction is the whole feature.
  defp vibrato(label, pitch, phase, {lo_reg, hi_reg}) do
    [
      {:label, label},

      # No table, no wobble.
      {:ld, :a, {:mem, @wobble}},
      {:ld, :b, :a},
      {:ld, :a, {:mem, @wobble + 1}},
      {:or, :a, :b},
      {:ret, :z},

      # Nothing struck: a rest cleared the high byte, trigger bit and all.
      {:ld, :a, {:mem, pitch + 1}},
      {:and, :a, 0x80},
      {:ret, :z},

      # One step round the sixteen.
      {:ld, :a, {:mem, phase}},
      {:inc, :a},
      {:and, :a, 0x0F},
      {:ld, {:mem, phase}, :a},

      # HL = table + phase, and A the deviation it holds.
      {:ld, :l, :a},
      {:ld, :h, 0},
      {:ld, :a, {:mem, @wobble}},
      {:ld, :c, :a},
      {:ld, :a, {:mem, @wobble + 1}},
      {:ld, :b, :a},
      {:add, :hl, :bc},
      {:ld, :a, {:mem, :hl}},

      # DE = that deviation, sign-extended: doubling sets carry from bit 7, and
      # subtracting with borrow turns it into 0x00 or 0xFF.
      {:ld, :e, :a},
      {:add, :a, :a},
      {:sbc, :a, :a},
      {:ld, :d, :a},

      # HL = the note's own frequency, without the trigger, plus the deviation.
      {:ld, :a, {:mem, pitch}},
      {:ld, :l, :a},
      {:ld, :a, {:mem, pitch + 1}},
      {:and, :a, 0x07},
      {:ld, :h, :a},
      {:add, :hl, :de},
      {:ld, :a, :l},
      {:ldh, {:high, lo_reg}, :a},
      {:ld, :a, :h},
      {:and, :a, 0x07},
      {:ldh, {:high, hi_reg}, :a},
      {:ret}
    ]
  end

  # The 32 nibbles the wave channel steps, into its own sixteen bytes at 0xFF30.
  # A loop and a label, like the font and the art -- unrolled it was thirty-two
  # instructions where this is eight, and the init's length is not free: it runs
  # between the vblank it waits for and the one the first frame catches, so
  # every instruction in here can push that first frame a whole frame later.
  defp wave_table do
    [
      {:ld, :hl, {:label, :wave_data}},
      {:ld, :de, @wave},
      {:ld, :b, 16},
      {:label, :copy_wave},
      {:ld, :a, {:mem, :hl_inc}},
      {:ld, {:mem, :de}, :a},
      {:inc, :de},
      {:dec, :b},
      {:jr, :nz, {:label, :copy_wave}}
    ]
  end

  defp letters do
    [
      {:ld, :hl, {:label, :letter_data}},
      {:ld, :de, @vram + @alphabet * 16},
      {:ld, :bc, byte_size(letter_bytes())},
      {:label, :copy_letters},
      {:ld, :a, {:mem, :hl_inc}},
      {:ld, {:mem, :de}, :a},
      {:inc, :de},
      {:dec, :bc},
      {:ld, :a, :b},
      {:or, :a, :c},
      {:jr, :nz, {:label, :copy_letters}}
    ]
  end

  # The APU, powered on and routed, once.
  #
  # On an ordinary boot all three of these write what was already there: the DMG
  # leaves NR52 at 0xF1 and NR50 at 0x77 after its boot ROM, and NR51 at 0xF3
  # already sends channel 2 to both ears. Removing the block changes nothing a
  # test could see, which is exactly why the test that pins it switches the APU
  # off first -- it earns its place against a cartridge that was reached through
  # something else, not against a cold start.
  #
  # NR52 first, and that ordering is load-bearing: with the power bit clear every
  # other sound register ignores writes, so a volume set before it would be a
  # volume set into nothing.
  defp sound_on do
    [
      {:ld, :a, 0x80},
      {:ldh, {:high, @nr52}, :a},
      {:ld, :a, 0x77},
      {:ldh, {:high, @nr50}, :a},
      {:ld, :a, 0xFF},
      {:ldh, {:high, @nr51}, :a}
    ]
  end

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
      {:call, {:label, :play_music}},
      {:call, {:label, :play_harmony}},
      {:call, {:label, :play_bass}},
      {:call, {:label, :vibrato_lead}},
      {:call, {:label, :vibrato_harmony}},
      calls,
      {:jr, {:label, :main_loop}}
    ]
    |> List.flatten()
  end
end
