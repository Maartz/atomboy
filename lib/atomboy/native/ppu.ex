defmodule Atomboy.Native.PPU do
  @moduledoc """
  The DMG scanline renderer in RISC-V -- the mirror of `Atomboy.PPU`.

  One routine, one scanline: 160 bytes out, one shade 0..3 per pixel, exactly
  what `Atomboy.PPU.render_line/3` produces in DMG mode. The differential bench
  (`Atomboy.Native.PPUBench`) compares the two byte for byte inside the guest,
  and that comparison is the only reason to keep the two shapes so close.

  ## Why the scanline, and not the frame

  The frame is the wrong unit twice over. On hardware the scroll registers are
  read *at the scanline* -- a game that changes SCX every line gets a distorted
  picture, which is the point -- so a frame-granular renderer would have to be
  handed 144 register snapshots. And on the C6 the frame does not fit anywhere
  convenient: 23 KB of framebuffer against 512 KB of SRAM is affordable, but the
  DMA to the panel wants a line at a time anyway. The scanline is where both
  constraints agree.

  ## The calling convention

      a5   the 64 KB space's base (`Regs.mem()`)   read, never written
      a0   LY, the scanline to draw, 0..143
      t0   the window's internal line counter, on entry
      t1   the destination buffer's address, 160 bytes, any alignment
      ---
      a0   the window's internal line counter, on exit
      ra   the return

  The two inputs that are not `a0` travel in `t0` and `t1` deliberately. Every
  other register in the low half is an SM83 carrier -- `a1` is the opcode, `a2`
  is HL, `a4` is PC (see `Atomboy.Native.Regs`) -- and the machine loop will
  call this between two scanlines with all of them live. The `t` registers are
  scratch everywhere in this project, so a caller has nothing to spill.

  Everything except `a0` and `t0`-`t6` comes back untouched. The routine needs
  twelve live values across the pixel loop, which is more than the free set, so
  it opens a stack frame and saves the callee-saved registers plus the four
  argument registers it uses internally. Thirty-six instructions of prologue and
  epilogue against some five thousand of rendering: the composability is free.

  ## Three passes, and why not two

  The destination buffer is written twice. Pass one fills it with the *raw*
  background colour 0..3, before any palette; pass two draws the sprite layer
  into a 160-byte scratch buffer; pass three resolves the two and applies BGP.

  The tempting shortcut -- palette the background immediately, then draw sprites
  straight over it in increasing priority order -- is wrong, and wrong in a way
  no simple test catches. A sprite carrying the "behind the background" flag
  yields to background colours 1-3; if a *lower*-priority sprite has already
  painted that pixel, the yielding sprite must reveal the **background**, not
  the sprite underneath. Only a sprite layer that keeps the single
  highest-priority non-transparent pixel per column reproduces that. Hence the
  buffer, and hence the marker byte: bit 7 says a sprite is there at all, bit 6
  carries its priority flag, bits 1-0 the shade.

  ## Runs, not pixels

  `Atomboy.PPU` recomputes a tile address for each of the 160 pixels. In Elixir
  that is the right trade -- the clarity is worth more than the work -- but here
  it would triple the cost of the layer: one tilemap read and two tile-data
  reads per pixel instead of per eight. `ppu_fill_run` therefore walks *runs*: it
  fetches a tile, emits the pixels of that tile that fall inside the run, moves
  to the next column. The two shift registers are pre-aligned so the current
  pixel is bit 31, which makes a pixel ten instructions with no masking.

  This splits the line at the window's left edge instead of testing `x >= wx` per
  pixel, and the split is exact: `win_start` is `max(WX - 7, 0)` when the window
  shows on this line and 160 when it does not, so one call covers the background
  and one covers the window.

  ## The DMG rules, and where the oracle surprised us

  Copied from `Atomboy.PPU` because it is the oracle, not because they are
  obvious:

    * **Background off (LCDC bit 0) does not mean white.** The raw layer becomes
      all-zero, and the combine still runs BGP over colour 0. A game with
      `BGP = 0xE1` gets shade 1 across the line, not shade 0.

    * **Background off freezes the window counter.** `background_raw/4` returns
      before the window is even looked at, so a line with BG disabled does not
      advance the internal counter even if WY and WX would have shown a window.

    * **`WX - 7` is signed.** `WX = 0` puts the window's left edge at -7: the
      window covers the whole line and its first *seven* pixels are off-screen,
      so column 0 of the window map starts at fine offset 7. `WX >= 167` turns
      the window off for the line; `WX = 166` leaves exactly one pixel.

    * **Ten sprites per line, in OAM order, then priority.** The cut to ten
      happens *before* the priority sort: an eleventh sprite with a small X does
      not displace a tenth with a large one. Among the ten, the smallest X wins
      and the lowest OAM index breaks the tie -- so they are drawn from lowest
      priority to highest, each overwriting.

    * **8x16 ignores bit 0 of the tile index**, and does so *after* the vertical
      flip, so a flipped 8x16 sprite reads rows 15..0 of the pair.

    * **Sprite colour 0 is transparent whatever the palette says.** The palette
      is applied to colours 1-3 only; there is no way to draw the shade OBP0
      holds in its first slot.

  ## Not going through `Atomboy.Native.Bus`

  Every other native module reads memory through `Bus`, the seam where the
  cartridge will graft its banks. The PPU does not, and that is deliberate on
  both sides of the analogy: on hardware the PPU has its own port into VRAM and
  OAM and never touches the CPU's bus, and here the run emitter holds a *host*
  pointer across eight pixels where `Bus.read/2` would re-add the base every
  time. Nothing the PPU reads -- VRAM, OAM, six I/O registers -- is ever banked.

  ## What it costs, and what is left on the table

  Measured on a real dmg-acid2 frame under `qemu -icount shift=0`, 144
  scanlines:

      per scanline   2,954 lowest / 4,872 mean / 7,433 highest
      per frame      701,666 retired instructions
      at 60 fps      42 M instructions per second
      code           1,192 bytes, plus 200 bytes of scratch

  Against a 160 MHz C6 that is roughly a quarter of the core for the rendering
  alone: viable, and not comfortable. The instruction-cache budget that is this
  campaign's whole reason for being is untroubled -- under 4% of 32 KB.

  The next three optimisations, in the order their return justifies them:
  unrolling the eight-pixel body, which drops the loop bookkeeping and about a
  fifth of the layer; folding the combine pass into the run emitter when no
  sprite touches the line at all, which is the common case; and keeping the
  sprite layer in registers rather than in memory for lines carrying one or two
  sprites. None of them changes the contract above, which is why the
  differential bench comes first.
  """

  import Bitwise

  alias Atomboy.Native.Asm
  alias Atomboy.Native.Regs
  alias Atomboy.Native.RV32

  @width 160
  @oam 0xFE00
  @io_page 0xFF00
  @sprite_limit 10

  # The registers the routine saves. `ra` because it calls its own helpers,
  # `a1`-`a4` because they are the helpers' arguments *and* SM83 carriers, and
  # every `s` because the working set does not fit anywhere else.
  @saved [
    :ra,
    :a1,
    :a2,
    :a3,
    :a4,
    :s0,
    :s1,
    :s2,
    :s3,
    :s4,
    :s5,
    :s6,
    :s7,
    :s8,
    :s9,
    :s10,
    :s11
  ]

  # 17 words, rounded up to a multiple of 16: the RISC-V ABI wants the stack
  # aligned, and nothing here is worth being the first place to find out that
  # something downstream cares.
  @frame 80

  @doc "The DMG scanline's width, in pixels and in bytes."
  @spec width() :: 160
  def width, do: @width

  @doc "How many sprites a scanline shows -- the hardware's limit, in OAM order."
  @spec sprite_limit() :: 10
  def sprite_limit, do: @sprite_limit

  @doc "The routine's entry label."
  @spec label() :: :ppu_render_line
  def label, do: :ppu_render_line

  @doc """
  Every routine, to be placed once in an image.

  Like `Atomboy.Native.ALU.routines/0`, they cost only their size: nothing runs
  unless `:ppu_render_line` is called.
  """
  @spec routines() :: [Asm.item()]
  def routines do
    [
      render_line(),
      fill_run(),
      draw_sprite(),
      zero()
    ]
  end

  @doc """
  The scratch the routine needs, to be placed in an image's **data** section.

  160 bytes of sprite layer followed by ten words of OAM candidates, contiguous
  and in that order: the routine holds one pointer and reaches the candidates at
  offset 160 from it. Both must land after all the code -- see
  `Atomboy.Native.Image.build/2` on why data in the middle of the code puts
  branches out of range.
  """
  @spec data() :: [Asm.item()]
  def data do
    [
      {:align, 4},
      Asm.label(:ppu_sprite_layer),
      {:space, @width},
      {:space, 4 * @sprite_limit}
    ]
  end

  # ══ The scanline ═════════════════════════════════════════════════════════════
  #
  # s0  destination buffer          s6   WX - 7, signed
  # s1  sprite layer                s7   the window's first column, 160 if none
  # s2  LCDC                        s8   sprite height, 8 or 16
  # s3  BGP                         s9   how many sprites the line selected
  # s4  the window line counter     s10  the I/O page, mem + 0xFF00
  # s5  LY                          s11  signed tile addressing?

  defp render_line do
    [
      Asm.label(:ppu_render_line),
      prologue(),
      RV32.mv(:s5, :a0),
      RV32.mv(:s4, :t0),
      RV32.mv(:s0, :t1),
      Asm.la(:s1, :ppu_sprite_layer),

      # The six registers the PPU reads all live in the top page: one base, then
      # loads at a constant offset. `0xFF40` would not fit a load's immediate on
      # its own.
      RV32.li(:t0, @io_page),
      RV32.add(:s10, Regs.mem(), :t0),
      RV32.lbu(:s2, :s10, 0x40),

      # A screen that is off renders shade 0 everywhere -- not BGP's colour 0,
      # shade 0 -- and the window counter does not move.
      RV32.andi(:t0, :s2, 0x80),
      Asm.bnez(:t0, :ppu_lcd_on),
      RV32.mv(:a1, :s0),
      RV32.li(:a2, @width),
      Asm.call(:ppu_zero),
      Asm.j(:ppu_return),
      Asm.label(:ppu_lcd_on),
      RV32.lbu(:s3, :s10, 0x47),
      background(),
      sprites(),
      combine(),
      Asm.label(:ppu_return),
      RV32.mv(:a0, :s4),
      epilogue(),
      RV32.ret()
    ]
  end

  defp prologue do
    [
      RV32.addi(:sp, :sp, -@frame),
      @saved |> Enum.with_index() |> Enum.map(fn {reg, i} -> RV32.sw(reg, :sp, 4 * i) end)
    ]
  end

  defp epilogue do
    [
      @saved |> Enum.with_index() |> Enum.map(fn {reg, i} -> RV32.lw(reg, :sp, 4 * i) end),
      RV32.addi(:sp, :sp, @frame)
    ]
  end

  # ══ The background and the window ════════════════════════════════════════════

  defp background do
    [
      # LCDC bit 0 down: the raw layer is all zeros, and the combine will still
      # run BGP over colour 0. The window is not even looked at, so its counter
      # stays put -- that is `background_raw/4`'s early return, and a real quirk.
      RV32.andi(:t0, :s2, 0x01),
      Asm.bnez(:t0, :ppu_bg_on),
      RV32.mv(:a1, :s0),
      RV32.li(:a2, @width),
      Asm.call(:ppu_zero),
      Asm.j(:ppu_sprites),
      Asm.label(:ppu_bg_on),
      window_edge(),

      # Signed addressing survives both runs, hence an `s` register: LCDC bit 4
      # down means the tile index is signed against 0x9000.
      RV32.andi(:t0, :s2, 0x10),
      RV32.sltiu(:s11, :t0, 1),
      background_run(),
      window_run()
    ]
  end

  # Where the window's left edge falls, or 160 when it does not show. `WX - 7`
  # is signed: WX below 7 puts the edge off-screen to the left, the window then
  # covering the whole line with its first pixels cut off.
  defp window_edge do
    [
      RV32.lbu(:t0, :s10, 0x4A),
      RV32.lbu(:s6, :s10, 0x4B),
      RV32.addi(:s6, :s6, -7),
      RV32.li(:s7, @width),
      RV32.andi(:t1, :s2, 0x20),
      Asm.beqz(:t1, :ppu_window_edge_done),
      Asm.blt(:s5, :t0, :ppu_window_edge_done),
      RV32.li(:t1, @width),
      Asm.bge(:s6, :t1, :ppu_window_edge_done),
      RV32.mv(:s7, :s6),
      Asm.bge(:s7, :zero, :ppu_window_edge_done),
      RV32.li(:s7, 0),
      Asm.label(:ppu_window_edge_done)
    ]
  end

  # Pixels 0 to win_start-1. A count of zero is a legitimate call -- the window
  # can start at column 0 -- and `ppu_fill_run` returns immediately on it.
  defp background_run do
    [
      # y = (LY + SCY) & 0xFF: the map wraps vertically at 256 pixels.
      RV32.lbu(:t0, :s10, 0x42),
      RV32.add(:t0, :t0, :s5),
      RV32.andi(:t0, :t0, 0xFF),
      map_row(:t0, 0x08),
      RV32.lbu(:t0, :s10, 0x43),
      RV32.andi(:t3, :t0, 7),
      RV32.srli(:t2, :t0, 3),
      RV32.mv(:t4, :s11),
      RV32.mv(:a1, :s0),
      RV32.mv(:a2, :s7),
      Asm.call(:ppu_fill_run)
    ]
  end

  defp window_run do
    [
      RV32.li(:t0, @width),
      Asm.bge(:s7, :t0, :ppu_sprites),
      map_row(:s4, 0x40),

      # The window's own pixel index at win_start: win_start - (WX - 7). Zero
      # when the edge is on-screen, 1..7 when WX cut the left of the window off.
      RV32.sub(:t0, :s7, :s6),
      RV32.andi(:t3, :t0, 7),
      RV32.srli(:t2, :t0, 3),
      RV32.mv(:t4, :s11),
      RV32.add(:a1, :s0, :s7),
      RV32.li(:t0, @width),
      RV32.sub(:a2, :t0, :s7),
      Asm.call(:ppu_fill_run),

      # The counter only advances on the lines where the window actually showed
      # up -- the quirk dmg-acid2 checks by toggling LCDC bit 5 mid-frame.
      RV32.addi(:s4, :s4, 1)
    ]
  end

  # a3 = map base + (line >> 3) * 32, a4 = (line & 7) * 2. `select` is the LCDC
  # bit choosing between the two 32x32 maps: bit 3 for the background, bit 6 for
  # the window.
  defp map_row(line, select) do
    [
      RV32.li(:t1, 0x9800),
      RV32.andi(:t2, :s2, select),
      Asm.beqz(:t2, :"ppu_map_#{select}"),
      RV32.li(:t1, 0x9C00),
      Asm.label(:"ppu_map_#{select}"),
      RV32.srli(:t2, line, 3),
      RV32.slli(:t2, :t2, 5),
      RV32.add(:a3, :t1, :t2),
      RV32.andi(:a4, line, 7),
      RV32.slli(:a4, :a4, 1)
    ]
  end

  # ── One run of background or window pixels ──────────────────────────────────
  #
  #   a1  destination, a host pointer     t2  the map column
  #   a2  how many pixels are left        t3  the first pixel's offset in the tile
  #   a3  the map row's base address      t4  signed tile addressing?
  #   a4  the tile line's offset, 0..14   t5/t6  the two bit planes
  #
  # Clobbers a0, a1, a2, t0 through t6. A leaf: `ra` is never saved.
  defp fill_run do
    [
      Asm.label(:ppu_fill_run),
      Asm.beqz(:a2, :ppu_run_done),
      Asm.label(:ppu_run_tile),
      RV32.add(:t0, :a3, :t2),
      RV32.add(:t1, Regs.mem(), :t0),
      RV32.lbu(:t0, :t1, 0),
      Asm.bnez(:t4, :ppu_run_signed),
      RV32.slli(:t1, :t0, 4),
      RV32.li(:t0, 0x8000),
      RV32.add(:t0, :t0, :t1),
      Asm.j(:ppu_run_line),

      # The signed mode's index runs -128..127 against 0x9000. Two shifts do the
      # sign extension `Atomboy.PPU` writes as `tile - bsl(bsr(tile, 7), 8)`.
      Asm.label(:ppu_run_signed),
      RV32.slli(:t1, :t0, 24),
      RV32.srai(:t1, :t1, 24),
      RV32.slli(:t1, :t1, 4),
      RV32.li(:t0, 0x9000),
      RV32.add(:t0, :t0, :t1),
      Asm.label(:ppu_run_line),
      RV32.add(:t0, :t0, :a4),
      RV32.add(:t1, Regs.mem(), :t0),
      RV32.lbu(:t5, :t1, 0),
      RV32.lbu(:t6, :t1, 1),

      # This tile contributes min(8 - first pixel, what is left).
      RV32.li(:t0, 8),
      RV32.sub(:t0, :t0, :t3),
      Asm.bge(:a2, :t0, :ppu_run_span),
      RV32.mv(:t0, :a2),
      Asm.label(:ppu_run_span),
      RV32.sub(:a2, :a2, :t0),

      # Both planes shifted so the pixel to draw is bit 31: the loop then reads a
      # colour with two shifts and no mask, and advancing is one shift each.
      RV32.addi(:t1, :t3, 24),
      RV32.sll(:t5, :t5, :t1),
      RV32.sll(:t6, :t6, :t1),
      RV32.li(:t3, 0),
      Asm.label(:ppu_run_pixel),
      RV32.srli(:a0, :t6, 31),
      RV32.slli(:a0, :a0, 1),
      RV32.srli(:t1, :t5, 31),
      RV32.or_(:a0, :a0, :t1),
      RV32.sb(:a0, :a1, 0),
      RV32.slli(:t5, :t5, 1),
      RV32.slli(:t6, :t6, 1),
      RV32.addi(:a1, :a1, 1),
      RV32.addi(:t0, :t0, -1),
      Asm.bnez(:t0, :ppu_run_pixel),

      # The background's column wraps at 32 because its X is masked to eight
      # bits; the window's never reaches 32 -- (159 + 7) >> 3 is 20 -- so the
      # same mask serves both.
      RV32.addi(:t2, :t2, 1),
      RV32.andi(:t2, :t2, 31),
      Asm.bnez(:a2, :ppu_run_tile),
      Asm.label(:ppu_run_done),
      RV32.ret()
    ]
  end

  # ══ The sprites ══════════════════════════════════════════════════════════════

  defp sprites do
    [
      Asm.label(:ppu_sprites),

      # The layer is cleared with word stores: it is ours, and aligned.
      RV32.mv(:t0, :s1),
      RV32.li(:t1, div(@width, 4)),
      Asm.label(:ppu_clear_loop),
      RV32.sw(:zero, :t0, 0),
      RV32.addi(:t0, :t0, 4),
      RV32.addi(:t1, :t1, -1),
      Asm.bnez(:t1, :ppu_clear_loop),
      RV32.andi(:t0, :s2, 0x02),
      Asm.beqz(:t0, :ppu_combine),
      RV32.li(:s8, 8),
      RV32.andi(:t0, :s2, 0x04),
      Asm.beqz(:t0, :ppu_height_done),
      RV32.li(:s8, 16),
      Asm.label(:ppu_height_done),
      scan_oam(),
      select_sprites()
    ]
  end

  # The line's first ten sprites, in OAM order. The cut happens here, before any
  # priority is considered: that is the hardware's rule and the oracle's
  # `Enum.take(10)`.
  #
  # A candidate is one word: the OAM X byte shifted left six, the OAM index
  # underneath. Sorting on that single integer sorts on X first and on the index
  # second, which is exactly the DMG's display priority.
  defp scan_oam do
    [
      RV32.li(:s9, 0),
      RV32.li(:t3, 0),
      RV32.addi(:t5, :s10, @oam - @io_page),
      Asm.label(:ppu_scan_loop),
      RV32.lbu(:t0, :t5, 0),
      RV32.addi(:t0, :t0, -16),
      RV32.sub(:t0, :s5, :t0),

      # One unsigned comparison covers both ends: a sprite above the line gives a
      # negative row, which reads as enormous.
      Asm.bgeu(:t0, :s8, :ppu_scan_next),
      RV32.lbu(:t0, :t5, 1),
      RV32.slli(:t0, :t0, 6),
      RV32.or_(:t0, :t0, :t3),
      RV32.slli(:t1, :s9, 2),
      RV32.add(:t1, :s1, :t1),
      RV32.sw(:t0, :t1, @width),
      RV32.addi(:s9, :s9, 1),
      RV32.li(:t0, @sprite_limit),
      Asm.beq(:s9, :t0, :ppu_scan_done),
      Asm.label(:ppu_scan_next),
      RV32.addi(:t3, :t3, 1),
      RV32.addi(:t5, :t5, 4),
      RV32.li(:t0, 40),
      Asm.blt(:t3, :t0, :ppu_scan_loop),
      Asm.label(:ppu_scan_done),
      Asm.beqz(:s9, :ppu_combine)
    ]
  end

  # Drawing order is decreasing priority, so each sprite overwrites the ones
  # behind it. A selection sort rather than a real one: ten entries at most, and
  # a consumed slot becomes -1, which no key can beat.
  defp select_sprites do
    [
      Asm.label(:ppu_select),
      RV32.li(:t0, -1),
      RV32.li(:t1, -1),
      RV32.li(:t2, 0),
      Asm.label(:ppu_select_scan),
      RV32.slli(:t3, :t2, 2),
      RV32.add(:t3, :s1, :t3),
      RV32.lw(:t4, :t3, @width),
      Asm.bge(:t0, :t4, :ppu_select_next),
      RV32.mv(:t0, :t4),
      RV32.mv(:t1, :t2),
      Asm.label(:ppu_select_next),
      RV32.addi(:t2, :t2, 1),
      Asm.blt(:t2, :s9, :ppu_select_scan),
      Asm.blt(:t1, :zero, :ppu_combine),
      RV32.slli(:t3, :t1, 2),
      RV32.add(:t3, :s1, :t3),
      RV32.li(:t4, -1),
      RV32.sw(:t4, :t3, @width),
      RV32.andi(:a1, :t0, 0x3F),
      RV32.slli(:a1, :a1, 2),
      RV32.addi(:t0, :s10, @oam - @io_page),
      RV32.add(:a1, :a1, :t0),
      RV32.mv(:a2, :s8),
      Asm.call(:ppu_draw_sprite),
      Asm.j(:ppu_select)
    ]
  end

  # ── One sprite, into the layer ──────────────────────────────────────────────
  #
  #   a1  the OAM entry, a host pointer   a3  X - 8, signed
  #   a2  the sprite's height, 8 or 16    a4  the flags byte
  #
  # Reads s1 and s5, clobbers a0 through a4 and t0 through t6.
  defp draw_sprite do
    [
      Asm.label(:ppu_draw_sprite),
      RV32.lbu(:t1, :a1, 0),
      RV32.lbu(:a3, :a1, 1),
      RV32.lbu(:t2, :a1, 2),
      RV32.lbu(:a4, :a1, 3),
      RV32.addi(:a3, :a3, -8),

      # OAM Y is biased by 16, so a sprite can hang off the top of the screen.
      RV32.addi(:t1, :t1, -16),
      RV32.sub(:t1, :s5, :t1),
      RV32.andi(:t0, :a4, 0x40),
      Asm.beqz(:t0, :ppu_sprite_rows),
      RV32.addi(:t0, :a2, -1),
      RV32.sub(:t1, :t0, :t1),
      Asm.label(:ppu_sprite_rows),

      # 8x16 ignores bit 0 of the index -- two tiles stacked -- and it does so
      # *after* the flip, so a flipped tall sprite reads rows 15 down to 0.
      RV32.li(:t0, 16),
      Asm.bne(:a2, :t0, :ppu_sprite_tile),
      RV32.andi(:t2, :t2, 0xFE),
      Asm.label(:ppu_sprite_tile),
      RV32.slli(:t2, :t2, 4),
      RV32.slli(:t1, :t1, 1),
      RV32.add(:t2, :t2, :t1),
      RV32.li(:t0, 0x8000),
      RV32.add(:t2, :t2, :t0),
      RV32.add(:t0, Regs.mem(), :t2),
      RV32.lbu(:t5, :t0, 0),
      RV32.lbu(:t6, :t0, 1),

      # OBP0 or OBP1, flags bit 4.
      RV32.andi(:t0, :a4, 0x10),
      Asm.beqz(:t0, :ppu_sprite_obp0),
      RV32.lbu(:t4, :s10, 0x49),
      Asm.j(:ppu_sprite_palette),
      Asm.label(:ppu_sprite_obp0),
      RV32.lbu(:t4, :s10, 0x48),
      Asm.label(:ppu_sprite_palette),

      # Mirroring is one exclusive-or on the bit number: pixel i reads bit 7-i
      # normally, bit i mirrored.
      RV32.li(:a1, 7),
      RV32.andi(:t0, :a4, 0x20),
      Asm.beqz(:t0, :ppu_sprite_bits),
      RV32.li(:a1, 0),
      Asm.label(:ppu_sprite_bits),
      RV32.li(:t3, 0),
      RV32.mv(:t2, :a3),
      Asm.label(:ppu_sprite_pixel),
      Asm.blt(:t2, :zero, :ppu_sprite_next),
      RV32.li(:t0, @width),
      Asm.bge(:t2, :t0, :ppu_sprite_done),
      RV32.xor_(:t0, :t3, :a1),
      RV32.srl(:t1, :t6, :t0),
      RV32.andi(:t1, :t1, 1),
      RV32.slli(:a0, :t1, 1),
      RV32.srl(:t1, :t5, :t0),
      RV32.andi(:t1, :t1, 1),
      RV32.or_(:a0, :a0, :t1),

      # Colour 0 is transparent whatever OBP says of it.
      Asm.beqz(:a0, :ppu_sprite_next),
      RV32.slli(:t1, :a0, 1),
      RV32.srl(:t1, :t4, :t1),
      RV32.andi(:t1, :t1, 3),
      RV32.ori(:t1, :t1, 0x80),
      RV32.andi(:t0, :a4, 0x80),
      Asm.beqz(:t0, :ppu_sprite_store),
      RV32.ori(:t1, :t1, 0x40),
      Asm.label(:ppu_sprite_store),
      RV32.add(:t0, :s1, :t2),
      RV32.sb(:t1, :t0, 0),
      Asm.label(:ppu_sprite_next),
      RV32.addi(:t3, :t3, 1),
      RV32.addi(:t2, :t2, 1),
      RV32.li(:t0, 8),
      Asm.blt(:t3, :t0, :ppu_sprite_pixel),
      Asm.label(:ppu_sprite_done),
      RV32.ret()
    ]
  end

  # ══ Resolving the two layers ═════════════════════════════════════════════════

  defp combine do
    [
      Asm.label(:ppu_combine),
      RV32.mv(:t2, :s0),
      RV32.mv(:t3, :s1),
      RV32.li(:t4, @width),
      Asm.label(:ppu_combine_loop),
      RV32.lbu(:t0, :t3, 0),
      RV32.lbu(:t1, :t2, 0),
      Asm.beqz(:t0, :ppu_combine_bg),
      RV32.andi(:t5, :t0, 0x40),
      Asm.beqz(:t5, :ppu_combine_obj),

      # "Behind the background" yields to colours 1-3 and only to those: over
      # colour 0 the sprite shows through.
      Asm.bnez(:t1, :ppu_combine_bg),
      Asm.label(:ppu_combine_obj),
      RV32.andi(:t0, :t0, 3),
      RV32.sb(:t0, :t2, 0),
      Asm.j(:ppu_combine_next),

      # The palette applies here and not in the run emitter: the priority test
      # above needs the *raw* colour, which is what "background colour 0" means.
      Asm.label(:ppu_combine_bg),
      RV32.slli(:t1, :t1, 1),
      RV32.srl(:t0, :s3, :t1),
      RV32.andi(:t0, :t0, 3),
      RV32.sb(:t0, :t2, 0),
      Asm.label(:ppu_combine_next),
      RV32.addi(:t2, :t2, 1),
      RV32.addi(:t3, :t3, 1),
      RV32.addi(:t4, :t4, -1),
      Asm.bnez(:t4, :ppu_combine_loop)
    ]
  end

  # ── Zeroing a buffer ────────────────────────────────────────────────────────
  #
  # a1 the address, a2 the count. Byte stores, not words: the destination is the
  # caller's, and demanding four-byte alignment of it would buy 500 instructions
  # on a path -- the screen off, or the background off -- that is not the hot
  # one.
  defp zero do
    [
      Asm.label(:ppu_zero),
      Asm.beqz(:a2, :ppu_zero_done),
      Asm.label(:ppu_zero_loop),
      RV32.sb(:zero, :a1, 0),
      RV32.addi(:a1, :a1, 1),
      RV32.addi(:a2, :a2, -1),
      Asm.bnez(:a2, :ppu_zero_loop),
      Asm.label(:ppu_zero_done),
      RV32.ret()
    ]
  end

  # ══ The shades, seen from Elixir ═════════════════════════════════════════════

  @doc """
  The marker byte the sprite layer holds for one pixel, as the routine builds it.

  Exposed for the bench, which reconstructs a divergence without re-running
  anything: bit 7 means a sprite is present, bit 6 carries "behind the
  background", bits 1-0 the shade.
  """
  @spec sprite_marker(0..3, boolean()) :: 0..255
  def sprite_marker(shade, behind?) do
    0x80 ||| if(behind?, do: 0x40, else: 0) ||| (shade &&& 3)
  end
end
