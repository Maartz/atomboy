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
  @spec program([Assembler.element()], binary()) :: [Assembler.element()]
  def program(actors, art \\ <<>>) when is_list(actors) and is_binary(art) do
    fragments = fragments(actors)
    Enum.each(fragments, &check_actor!/1)
    art!(art)

    init(art) ++
      vblank() ++
      read_pad() ++
      main_loop(length(fragments)) ++
      [{:label, :dma_source}, {:bytes, dma_bytes()}] ++
      [{:label, :font_data}, {:bytes, font_bytes()}] ++
      [{:label, :letter_data}, {:bytes, letter_bytes()}] ++
      art_data(art) ++
      Enum.flat_map(Enum.with_index(fragments), fn {fragment, slot} ->
        [{:label, actor_label(slot)}] ++ fragment
      end)
  end

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
      sound() ++
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
  defp sound do
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
      calls,
      {:jr, {:label, :main_loop}}
    ]
    |> List.flatten()
  end
end
