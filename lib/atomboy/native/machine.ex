defmodule Atomboy.Native.Machine do
  @moduledoc """
  The machine loop, generated: 154 scanlines that turn a CPU into a Game Boy.

  `Atomboy.Native.Interp` runs SM83 code until a cycle budget runs out. That is a
  processor, not a console. What makes a console is the cadence around it: LY
  advancing at 0xFF44 so a polling loop can see the frame move, the vblank flag
  rising in IF at line 144 so an interrupt handler gets called, the timer
  catching up with the cycles that just went by. This module is that cadence, and
  it is the native equivalent of `Atomboy.Screen.step_line/4` and
  `Atomboy.Screen.frame/4` -- clause for clause, deliberately, because the Elixir
  side is the oracle the tests compare against.

  ## Why the scanline, and not the cycle

  A faithful emulator advances the PPU, the timer and the CPU in lockstep, cycle
  by cycle. That costs a hardware step per CPU cycle, and on an ESP32-C6 it is
  the difference between a game that runs and one that stutters. The scanline is
  the coarsest granularity at which games still work: 456 T-cycles of CPU, then
  the hardware moves up a notch. It is coarse enough that a timer interrupt lands
  up to 456 cycles late, and fine enough that LY reads correctly, that vblank
  arrives once per frame, and that a game's frame pacing is exact. `Screen` made
  that trade first; this module inherits it rather than re-deciding it, because
  two emulators that round differently cannot be compared.

  ## What is modelled, and what is not

  Exactly what `Screen.step_line/4` models, and nothing more:

    * LY at 0xFF44, and LY frozen at zero with the screen off -- the PPU stops
      generating when LCDC bit 7 is clear, which is why no vblank fires then;
    * the vblank request, IF bit 0, at line 144;
    * the LY=LYC coincidence: STAT bit 2, and the STAT interrupt (IF bit 1) when
      the game armed STAT bit 6;
    * DIV, TIMA, TMA and TAC exactly as `Atomboy.Timer.advance/2` applies them,
      including the overflow that reloads from TMA and requests IF bit 2.

  Not modelled, and each absence is a choice `Screen` already made or a
  deliberate limit of this stage: the STAT mode bits (0-1), because no game the
  project runs reads them and `Screen` does not maintain them either; pixel
  rendering, which is `Atomboy.PPU`'s business and one day the native PPU's;
  double speed, since `KEY1` is a Game Boy Color register and this loop is DMG;
  the GBC video DMAs (GDMA/HDMA) and the link cable, for the same reason.

  ## Composing with the interpreter rather than copying it

  The 500 opcode handlers are not rewritten here: they come from
  `Atomboy.Native.Emit.body/1` and `Atomboy.Native.ALU.routines/0`, the same
  generators `Interp` feeds on. What this module does re-emit is the dispatch
  skeleton -- the fetch, the slow path, the interrupt service, the jump tables --
  because `Interp` exposes only `image/3`, and an image is a finished binary with
  its exit already welded to `materialise`. The machine loop needs that exit to
  land on *its* code, once per scanline, 154 times per frame. Given the choice
  between editing `interp.ex` and re-emitting sixty instructions whose semantics
  are pinned by `Atomboy.CPU.Loop.fetch/17` and by the equivalence tests, this
  stage re-emits. The skeleton is small; the handlers, which are not, are shared.

  ## The memory seam: where a write stops being a store

  `Atomboy.Native.Bus` writes bytes into a flat 64 KB space. That is the right
  contract for the CPU, and the wrong one for a console: on real hardware some
  addresses *do* something when written. `Atomboy.CPU.CartLoop` intercepts them
  in `ram_write/3`, and the three interceptions a DMG game cannot live without
  are reproduced here, in `mmio_write`:

    * **0xFF00, the joypad.** The game writes which of the two matrix rows it
      wants, and reads the lines back in the low nibble, active low. Storing the
      written byte as-is would report every button on the selected row as held
      down -- Tetris reads its soft-reset combo there and reboots forever. The
      composition happens on the write, exactly as `Atomboy.Joypad.write/2` does
      it, so a game that writes 0xFF00 and reads it back two instructions later
      sees what the hardware would show. All keys are released in this stage: the
      lines are `0x0F`, so a write of `sel` reads back as `0xC0 ||| sel ||| 0x0F`.
    * **0xFF46, the OAM DMA.** The write copies 160 bytes from page `A` into OAM.
      Without it OAM stays empty and every sprite is invisible -- which is to say
      the game runs and shows nothing.
    * **0xFF04, DIV.** Any write resets the counter *and* its sub-counter to
      zero. Potion's own kernel does this on its second instruction.

  Writes below 0x8000 are dropped rather than stored: they are MBC registers on
  hardware, and in a flat memory they would rewrite the cartridge under the
  program's feet.

  Only the three store forms that address memory absolutely go through the seam
  -- `LDH (a8), A`, `LD (C), A`, `LD (a16), A` -- because those are the forms
  games use for registers, and routing every write would put a branch on the
  hot path of `LD (HL), r`. A write to an I/O register through `(HL)` therefore
  lands as a plain byte. It is a known hole, not an oversight; closing it means
  giving `Bus.write/2` a hook, which is a change to a file this stage does not
  own.

  ## The protocol

  `Interp`'s, unchanged: state, frame count and 64 KB baked into the image; a
  24-byte record followed by the final 64 KB coming back over the serial port.
  The `cycles` field carries the total across every line of every frame, not the
  last line's, which is the only number a caller could want. The timer's
  sub-counters start at zero and are not returned, so an image runs whole frames
  from a known state -- chaining two runs to make one is exact for the CPU and
  the memory, and loses at most 455 cycles of timer phase.
  """

  import Bitwise

  alias Atomboy.CPU.Insn
  alias Atomboy.CPU.State
  alias Atomboy.CPU.Table
  alias Atomboy.Native.ALU
  alias Atomboy.Native.Asm
  alias Atomboy.Native.Bus
  alias Atomboy.Native.Emit
  alias Atomboy.Native.Image
  alias Atomboy.Native.Interp
  alias Atomboy.Native.Qemu
  alias Atomboy.Native.Regs
  alias Atomboy.Native.RV32

  @ime Regs.control_bits().ime
  @halted Regs.control_bits().halted
  @pending Regs.control_bits().pending

  # The cadence, from `Atomboy.Screen`. Same names, same values -- a divergence
  # here would be a divergence nobody reads.
  @line_cycles 456
  @visible 144
  @lines 154

  @joyp 0xFF00
  @div 0xFF04
  @tima 0xFF05
  @tma 0xFF06
  @tac 0xFF07
  @irq_if 0xFF0F
  @lcdc 0xFF40
  @stat 0xFF41
  @ly 0xFF44
  @lyc 0xFF45
  @dma 0xFF46

  # The four TIMA rates in T-cycles, in TAC's bit order -- `Atomboy.Timer`'s
  # tuple, as a word table the guest indexes.
  @periods [1024, 16, 64, 256]

  @memory 0x10000
  @instret 0xC02

  # The three store forms routed through the I/O seam: `LDH (a8), A`,
  # `LD (C), A`, `LD (a16), A`.
  @routed [0xE0, 0xE2, 0xEA]

  # The machine's own state, in a word block the CPU slice cannot reach: the
  # scanline, the frames left to run, the timer's two sub-counters and the cycle
  # total. It lives in memory rather than in registers because the interpreter
  # owns almost all of them, and the one that is left points here.
  @ms_ly 0
  @ms_frames 4
  @ms_div 8
  @ms_tima 12
  @ms_total 16
  @ms_size 20

  @state_pointer :s11

  @doc "The number of scanlines in a frame, vblank included."
  @spec lines() :: 154
  def lines, do: @lines

  @doc "The T-cycles of CPU one scanline is worth."
  @spec line_cycles() :: 456
  def line_cycles, do: @line_cycles

  @doc "The first scanline of the vblank -- the line that raises IF bit 0."
  @spec visible() :: 144
  def visible, do: @visible

  @doc """
  Assembles an image running `frames` complete frames from `state` over `memory`.

  `memory` is the flat 64 KB address space: ROM in the low half, the rest as the
  caller wants it read. The image runs `frames` × 154 scanlines and then reports.
  """
  @spec image(binary(), State.t(), pos_integer()) :: Asm.assembled()
  def image(memory, %State{} = state, frames)
      when byte_size(memory) == @memory and is_integer(frames) and frames > 0 do
    Image.build(
      [
        driver(),
        scanline(),
        line_done(),
        fetch(),
        slow_fetch(),
        exits(),
        mmio(),
        handlers(),
        ALU.routines()
      ],
      data(memory, state, frames)
    )
  end

  @typedoc "What the guest reports at the end of the last frame."
  @type result :: %{
          state: State.t(),
          memory: binary(),
          cycles: non_neg_integer(),
          status: :ok | :unknown_opcode,
          opcode: 0..0xFF,
          instret: non_neg_integer(),
          duration_us: non_neg_integer(),
          size: non_neg_integer()
        }

  @doc """
  Runs `frames` frames under qemu and decodes what came back.

  Same shape as `Atomboy.Native.Run.run/4`, one level up: the budget is a number
  of frames, not of cycles, and the hardware advances in between.
  """
  @spec run(binary(), State.t(), pos_integer(), keyword()) :: {:ok, result()} | {:error, term()}
  def run(memory, %State{} = state, frames, opts \\ []) do
    image = image(memory, state, frames)

    case Qemu.run(image.code, opts) do
      %{status: :timeout, duration_us: us} ->
        {:error, {:timeout, us}}

      %{status: :ok, serial: serial, duration_us: us} ->
        decode(serial, us, image.size)
    end
  end

  @doc "The same run, raising on a harness failure -- a looping qemu is not a result."
  @spec run!(binary(), State.t(), pos_integer(), keyword()) :: result()
  def run!(memory, state, frames, opts \\ []) do
    case run(memory, state, frames, opts) do
      {:ok, result} -> result
      {:error, reason} -> raise "the guest returned nothing usable: #{inspect(reason)}"
    end
  end

  # ══ The driver ═══════════════════════════════════════════════════════════════
  #
  # `Interp`'s driver, plus the machine's own state: the pointer to the word
  # block, the frame count out of the header, and the sub-counters at zero.

  defp driver do
    [
      Asm.label(:driver),
      Asm.la(Regs.dispatch(), :table_base),
      Asm.la(Regs.mem(), :memory_gb),
      Asm.la(@state_pointer, :machine_state),
      RV32.li(Regs.mask16(), 0xFFFF),
      RV32.li(Regs.cycles(), 0),
      Asm.la(:t2, :initial_state),
      RV32.lbu(Regs.a(), :t2, 0),
      RV32.lbu(Regs.f(), :t2, 1),
      RV32.lbu(Regs.b(), :t2, 2),
      RV32.lbu(Regs.c(), :t2, 3),
      RV32.lbu(Regs.d(), :t2, 4),
      RV32.lbu(Regs.e(), :t2, 5),
      # H and L arrive split in the header and join here, as in `Interp`.
      RV32.lbu(:t0, :t2, 6),
      RV32.lbu(:t1, :t2, 7),
      RV32.slli(:t0, :t0, 8),
      RV32.or_(Regs.hl(), :t0, :t1),
      RV32.lhu(Regs.sp(), :t2, 8),
      RV32.lhu(Regs.pc(), :t2, 10),
      RV32.lbu(Regs.control(), :t2, 12),
      RV32.lw(:t0, :t2, 16),
      RV32.sw(:t0, @state_pointer, @ms_frames),
      RV32.sw(:zero, @state_pointer, @ms_div),
      RV32.sw(:zero, @state_pointer, @ms_tima),
      RV32.sw(:zero, @state_pointer, @ms_total),
      # The retired-instruction baseline. Exact only under `-icount shift=0`,
      # which is why the measurement asks for it.
      RV32.csrrs(:s9, @instret, :zero),
      Asm.label(:frame_loop),
      RV32.sw(:zero, @state_pointer, @ms_ly)
    ]
  end

  # ══ The scanline ═════════════════════════════════════════════════════════════
  #
  # `Screen.ppu_line/3`, in order: LY, then the vblank request, then the
  # coincidence. The order is observable -- a handler entered at line 144 reads
  # LY, and it must read 144.
  #
  # One pointer serves the whole block. LCDC, STAT, LY and LYC sit within five
  # bytes of each other, and IF is 49 below: every register in the block is one
  # displacement off `t0`, which is what keeps a `li` out of the per-line path.

  defp scanline do
    [
      Asm.label(:line_loop),
      RV32.li(:t0, @lcdc),
      RV32.add(:t0, Regs.mem(), :t0),
      RV32.lbu(:t1, :t0, 0),
      RV32.andi(:t1, :t1, 0x80),
      RV32.lw(:t2, @state_pointer, @ms_ly),
      Asm.beqz(:t1, :lcd_off),

      # Screen on: LY follows the scanline.
      RV32.sb(:t2, :t0, @ly - @lcdc),
      RV32.li(:t3, @visible),
      Asm.bne(:t2, :t3, :no_vblank),
      RV32.lbu(:t4, :t0, @irq_if - @lcdc),
      RV32.ori(:t4, :t4, 0x01),
      RV32.sb(:t4, :t0, @irq_if - @lcdc),
      Asm.label(:no_vblank),

      # The LY=LYC coincidence: STAT bit 2 reflects it, and STAT bit 6 turns it
      # into an interrupt -- the tool of raster effects.
      RV32.lbu(:t3, :t0, @stat - @lcdc),
      RV32.lbu(:t4, :t0, @lyc - @lcdc),
      Asm.bne(:t2, :t4, :no_coincidence),
      RV32.ori(:t5, :t3, 0x04),
      RV32.sb(:t5, :t0, @stat - @lcdc),
      RV32.andi(:t5, :t3, 0x40),
      Asm.beqz(:t5, :line_run),
      RV32.lbu(:t5, :t0, @irq_if - @lcdc),
      RV32.ori(:t5, :t5, 0x02),
      RV32.sb(:t5, :t0, @irq_if - @lcdc),
      Asm.j(:line_run),
      Asm.label(:no_coincidence),
      RV32.andi(:t3, :t3, 0xFB),
      RV32.sb(:t3, :t0, @stat - @lcdc),
      Asm.j(:line_run),

      # Screen off: the generator stops. LY stays at zero, no vblank, no
      # coincidence -- and that is not a detail. A game that turns the screen off
      # to reload VRAM keeps calling its sound engine with interrupts open; a
      # phantom vblank would re-enter that engine on top of itself.
      Asm.label(:lcd_off),
      RV32.sb(:zero, :t0, @ly - @lcdc),
      RV32.lbu(:t1, :t0, @stat - @lcdc),
      RV32.andi(:t1, :t1, 0xF8),
      RV32.sb(:t1, :t0, @stat - @lcdc),

      # The CPU's slice. The budget is a fresh 456 every line: the last
      # instruction of a line may overshoot, and `Atomboy.CPU.Loop` does not
      # carry the overshoot forward either -- it is the timer that sees it.
      Asm.label(:line_run),
      RV32.li(Regs.cycles(), 0),
      RV32.li(Regs.budget(), @line_cycles),
      Asm.j(:fetch)
    ]
  end

  # ══ The end of the line ══════════════════════════════════════════════════════
  #
  # Where the interpreter's budget check lands, 154 times per frame. Everything
  # here is `Atomboy.Timer.advance/2` with the cycles the slice actually
  # consumed, overshoot included.

  defp line_done do
    [
      Asm.label(:line_done),
      RV32.lw(:t0, @state_pointer, @ms_total),
      RV32.add(:t0, :t0, Regs.cycles()),
      RV32.sw(:t0, @state_pointer, @ms_total),
      divider(),
      counter(),
      Asm.label(:line_next),
      RV32.lw(:t0, @state_pointer, @ms_ly),
      RV32.addi(:t0, :t0, 1),
      RV32.sw(:t0, @state_pointer, @ms_ly),
      RV32.li(:t1, @lines),
      Asm.bltu(:t0, :t1, :line_loop),

      # The frame is over. One less to run.
      RV32.lw(:t0, @state_pointer, @ms_frames),
      RV32.addi(:t0, :t0, -1),
      RV32.sw(:t0, @state_pointer, @ms_frames),
      Asm.bnez(:t0, :frame_loop),

      # The record reports the total, not the last line's count.
      RV32.lw(Regs.cycles(), @state_pointer, @ms_total),
      Asm.j(:materialise)
    ]
  end

  # DIV beats at one 256th of the crystal: the sub-counter takes the cycles, its
  # high bits are the increments, and DIV wraps in a byte -- which `sb` does for
  # free.
  defp divider do
    [
      RV32.lw(:t0, @state_pointer, @ms_div),
      RV32.add(:t0, :t0, Regs.cycles()),
      RV32.srli(:t1, :t0, 8),
      RV32.andi(:t0, :t0, 0xFF),
      RV32.sw(:t0, @state_pointer, @ms_div),
      Asm.beqz(:t1, :tima_start),
      RV32.li(:t2, @div),
      RV32.add(:t2, Regs.mem(), :t2),
      RV32.lbu(:t3, :t2, 0),
      RV32.add(:t3, :t3, :t1),
      RV32.sb(:t3, :t2, 0)
    ]
  end

  # TIMA counts at TAC's rate, and only if TAC bit 2 is set. The increments come
  # from repeated subtraction rather than a division: RV32I has no divider, and
  # at 456 cycles per line the shortest period gives twenty-nine turns.
  #
  # `t2` points at TAC for the whole block: TIMA is two bytes below, TMA one, and
  # IF eight above.
  defp counter do
    [
      Asm.label(:tima_start),
      RV32.li(:t2, @tac),
      RV32.add(:t2, Regs.mem(), :t2),
      RV32.lbu(:t3, :t2, 0),
      RV32.andi(:t4, :t3, 0x04),
      Asm.beqz(:t4, :line_next),
      RV32.andi(:t3, :t3, 0x03),
      RV32.slli(:t3, :t3, 2),
      Asm.la(:t4, :tima_periods),
      RV32.add(:t4, :t4, :t3),
      RV32.lw(:t4, :t4, 0),
      RV32.lw(:t5, @state_pointer, @ms_tima),
      RV32.add(:t5, :t5, Regs.cycles()),
      Asm.label(:tima_loop),
      Asm.bltu(:t5, :t4, :tima_done),
      RV32.sub(:t5, :t5, :t4),
      RV32.lbu(:t6, :t2, @tima - @tac),
      RV32.addi(:t6, :t6, 1),
      RV32.li(:t0, 0x100),
      Asm.bne(:t6, :t0, :tima_store),

      # Overflow: TIMA reloads from TMA and the timer interrupt is requested.
      RV32.lbu(:t6, :t2, @tma - @tac),
      RV32.lbu(:t1, :t2, @irq_if - @tac),
      RV32.ori(:t1, :t1, 0x04),
      RV32.sb(:t1, :t2, @irq_if - @tac),
      Asm.label(:tima_store),
      RV32.sb(:t6, :t2, @tima - @tac),
      Asm.j(:tima_loop),
      Asm.label(:tima_done),
      RV32.sw(:t5, @state_pointer, @ms_tima)
    ]
  end

  # ══ The fetch ════════════════════════════════════════════════════════════════
  #
  # `Interp`'s, with one difference and only one: the exhausted budget lands on
  # `line_done` instead of `materialise`. That single edge is the whole reason
  # this skeleton is re-emitted here.

  defp fetch do
    [
      Asm.label(:fetch),
      Asm.bgeu(Regs.cycles(), Regs.budget(), :to_line_done),
      Asm.bnez(Regs.control(), :to_slow),
      Asm.label(:fast),
      RV32.add(:t0, Regs.mem(), Regs.pc()),
      RV32.lbu(Regs.opcode(), :t0, 0),
      RV32.addi(Regs.pc(), Regs.pc(), 1),
      RV32.and_(Regs.pc(), Regs.pc(), Regs.mask16()),
      RV32.slli(:t0, Regs.opcode(), 2),
      RV32.add(:t0, Regs.dispatch(), :t0),
      RV32.lw(:t0, :t0, 0),
      RV32.jr(:t0),

      # The trampolines sit behind the `jr`, which never falls into them: a
      # conditional branch reaches ±4 KB, and the handlers occupy far more.
      Asm.label(:to_line_done),
      Asm.j(:line_done),
      Asm.label(:to_slow),
      Asm.j(:slow_fetch)
    ]
  end

  # ══ The slow path ════════════════════════════════════════════════════════════
  #
  # `Atomboy.CPU.Loop.fetch/17`'s order, clause for clause: promoting an armed
  # EI, then HALT, then the interrupt service, then dispatch. Any permutation
  # diverges from the oracle on a program arming an EI just before an interrupt
  # lands, and the differential test is what would say so, much later.

  defp slow_fetch do
    [
      Asm.label(:slow_fetch),
      RV32.andi(:t0, Regs.control(), @pending),
      Asm.beqz(:t0, :slow_halt),
      RV32.ori(Regs.control(), Regs.control(), @ime),
      RV32.andi(Regs.control(), Regs.control(), bnot(@pending)),
      Asm.j(:fetch),

      # HALT sleeps in 4 T steps. Waking does not depend on IME -- only the
      # service does.
      Asm.label(:slow_halt),
      RV32.andi(:t0, Regs.control(), @halted),
      Asm.beqz(:t0, :slow_irq),
      Asm.call(:pending_irq),
      Asm.bnez(:t1, :slow_wake),
      RV32.addi(Regs.cycles(), Regs.cycles(), 4),
      Asm.j(:fetch),
      Asm.label(:slow_wake),
      RV32.andi(Regs.control(), Regs.control(), bnot(@halted)),
      Asm.j(:fetch),
      Asm.label(:slow_irq),
      Asm.call(:pending_irq),
      Asm.beqz(:t1, :fast),
      service(),
      pending_irq()
    ]
  end

  # The service: the vector's address is 0x40 + 8 × the lowest armed bit's index,
  # PC goes onto the stack, IME falls, 20 T. IF is sampled **before** the pushes,
  # as in the oracle: a stack landing on 0xFF0F masks the earlier value.
  defp service do
    [
      RV32.sub(:t4, :zero, :t1),
      RV32.and_(:t4, :t1, :t4),
      RV32.lbu(:t6, :t0, 0),
      RV32.li(:a0, 0x40),
      RV32.mv(:a1, :t4),
      Asm.label(:vector_loop),
      RV32.andi(:t3, :a1, 1),
      Asm.bnez(:t3, :vector_ready),
      RV32.srli(:a1, :a1, 1),
      RV32.addi(:a0, :a0, 8),
      Asm.j(:vector_loop),
      Asm.label(:vector_ready),
      Bus.move_stack(-2),
      Bus.write16(Regs.sp(), Regs.pc()),
      RV32.li(:t0, @irq_if),
      RV32.add(:t0, Regs.mem(), :t0),
      RV32.xori(:t1, :t4, 0xFF),
      RV32.and_(:t1, :t6, :t1),
      RV32.sb(:t1, :t0, 0),
      RV32.andi(Regs.control(), Regs.control(), bnot(@ime)),
      RV32.mv(Regs.pc(), :a0),
      RV32.addi(Regs.cycles(), Regs.cycles(), 20),
      Asm.j(:fetch)
    ]
  end

  # `t1`: the armed and enabled sources. `t0` keeps IF's address, which the
  # service reuses. IE reads off the same pointer, displaced by 0xF0.
  defp pending_irq do
    [
      Asm.label(:pending_irq),
      RV32.li(:t0, @irq_if),
      RV32.add(:t0, Regs.mem(), :t0),
      RV32.lbu(:t1, :t0, 0),
      RV32.lbu(:t2, :t0, 0xFFFF - @irq_if),
      RV32.and_(:t1, :t1, :t2),
      RV32.andi(:t1, :t1, 0x1F),
      RV32.ret()
    ]
  end

  # ══ The I/O seam ═════════════════════════════════════════════════════════════
  #
  # `a0` the guest address, `t0` the byte. Clobbers t0-t6, a0 and ra; every SM83
  # register survives, the opcode in `a1` included.

  defp mmio do
    [
      Asm.label(:mmio_write),

      # Below 0x8000 the cartridge answers, not memory: an MBC register, or
      # nothing at all. Storing there would rewrite the program.
      RV32.li(:t1, 0x8000),
      Asm.bltu(:a0, :t1, :mmio_done),

      # 0xFF00: the matrix recomposed, as `Atomboy.Joypad.write/2` does it. Bits
      # 7-6 read high, the selection is kept, and the four lines of the selected
      # rows come back active low -- all released here, hence 0x0F.
      RV32.li(:t1, @joyp),
      Asm.bne(:a0, :t1, :mmio_div),
      RV32.andi(:t0, :t0, 0x30),
      RV32.ori(:t0, :t0, 0xCF),
      Asm.j(:mmio_store),

      # 0xFF04: any write resets DIV and its sub-counter.
      Asm.label(:mmio_div),
      RV32.li(:t1, @div),
      Asm.bne(:a0, :t1, :mmio_dma),
      RV32.li(:t0, 0),
      RV32.sw(:zero, @state_pointer, @ms_div),
      Asm.j(:mmio_store),

      # 0xFF46: the OAM DMA. 160 bytes from page `A` into OAM, on the spot --
      # the hardware takes 160 machine cycles and games count them by hand, so
      # nothing observes the difference. A page below 0x80 is not a transfer the
      # oracle handles either: the byte is merely stored.
      Asm.label(:mmio_dma),
      RV32.li(:t1, @dma),
      Asm.bne(:a0, :t1, :mmio_store),
      RV32.li(:t1, 0x80),
      Asm.bltu(:t0, :t1, :mmio_store),
      RV32.add(:t1, Regs.mem(), :a0),
      RV32.sb(:t0, :t1, 0),
      RV32.slli(:t2, :t0, 8),
      RV32.add(:t2, Regs.mem(), :t2),
      RV32.li(:t3, 0xFE00),
      RV32.add(:t3, Regs.mem(), :t3),
      RV32.li(:t4, 0xA0),
      Asm.label(:dma_loop),
      Asm.beqz(:t4, :mmio_done),
      RV32.lbu(:t5, :t2, 0),
      RV32.sb(:t5, :t3, 0),
      RV32.addi(:t2, :t2, 1),
      RV32.addi(:t3, :t3, 1),
      RV32.addi(:t4, :t4, -1),
      Asm.j(:dma_loop),
      Asm.label(:mmio_store),
      RV32.add(:t1, Regs.mem(), :a0),
      RV32.sb(:t0, :t1, 0),
      Asm.label(:mmio_done),
      RV32.ret()
    ]
  end

  # ══ The exits ════════════════════════════════════════════════════════════════

  defp exits do
    [
      Asm.label(:materialise),
      RV32.li(:t2, Interp.statuses().ok),
      Asm.j(:report),
      Asm.label(:unknown_opcode),
      RV32.li(:t2, Interp.statuses().unknown_opcode),
      report(),
      dump()
    ]
  end

  # `Interp`'s record, byte for byte -- `t2` carries the status, `a1` the opcode,
  # and `putc` only clobbers t0 and t1.
  defp report do
    [
      Asm.label(:report),
      RV32.csrrs(:s10, @instret, :zero),
      RV32.sub(:s10, :s10, :s9),
      byte_out(RV32.li(:a0, Interp.magic())),
      byte_out(RV32.mv(:a0, Regs.a())),
      byte_out(RV32.mv(:a0, Regs.f())),
      byte_out(RV32.mv(:a0, Regs.b())),
      byte_out(RV32.mv(:a0, Regs.c())),
      byte_out(RV32.mv(:a0, Regs.d())),
      byte_out(RV32.mv(:a0, Regs.e())),
      byte_out(RV32.srli(:a0, Regs.hl(), 8)),
      byte_out(RV32.andi(:a0, Regs.hl(), 0xFF)),
      byte_out(RV32.mv(:a0, Regs.sp())),
      byte_out(RV32.srli(:a0, Regs.sp(), 8)),
      byte_out(RV32.mv(:a0, Regs.pc())),
      byte_out(RV32.srli(:a0, Regs.pc(), 8)),
      byte_out(RV32.mv(:a0, Regs.control())),
      byte_out(RV32.mv(:a0, Regs.cycles())),
      byte_out(RV32.srli(:a0, Regs.cycles(), 8)),
      byte_out(RV32.srli(:a0, Regs.cycles(), 16)),
      byte_out(RV32.srli(:a0, Regs.cycles(), 24)),
      byte_out(RV32.mv(:a0, :t2)),
      byte_out(RV32.mv(:a0, Regs.opcode())),
      byte_out(RV32.mv(:a0, :s10)),
      byte_out(RV32.srli(:a0, :s10, 8)),
      byte_out(RV32.srli(:a0, :s10, 16)),
      byte_out(RV32.srli(:a0, :s10, 24))
    ]
  end

  defp byte_out(load), do: [load, Asm.call(:putc)]

  defp dump do
    [
      Asm.label(:dump),
      RV32.mv(:t3, Regs.mem()),
      RV32.li(:t4, @memory),
      Asm.label(:dump_loop),
      Asm.beqz(:t4, :dump_done),
      RV32.lbu(:a0, :t3, 0),
      Asm.call(:putc),
      RV32.addi(:t3, :t3, 1),
      RV32.addi(:t4, :t4, -1),
      Asm.j(:dump_loop),
      Asm.label(:dump_done),
      Asm.j(:poweroff)
    ]
  end

  # ══ The handlers ═════════════════════════════════════════════════════════════
  #
  # `Emit`'s, unchanged, except the three store forms that go through the seam --
  # they keep their labels, so dispatch knows nothing about the difference.

  defp handlers do
    base =
      for %Insn{prefix: nil} = insn <- Table.base(),
          insn.opcode not in @routed,
          (body = Emit.body(insn)) != :unsupported do
        [Asm.label(label(insn.opcode)), body]
      end

    extended =
      for %Insn{prefix: :cb} = insn <- Table.extended(),
          (body = Emit.body(insn)) != :unsupported do
        [Asm.label(label_cb(insn.opcode)), body]
      end

    routed =
      for %Insn{prefix: nil} = insn <- Table.base(), insn.opcode in @routed do
        [Asm.label(label(insn.opcode)), store_body(insn)]
      end

    [prefix(), routed, base, extended]
  end

  # LDH (a8), A -- the immediate names a high-page register, which is exactly
  # where the seam matters.
  defp store_body(%Insn{opcode: 0xE0, cycles: cycles}) do
    Emit.read_immediate(:t0) ++
      Bus.high_page(:t0, :a0) ++
      [RV32.mv(:t0, Regs.a()), Asm.call(:mmio_write)] ++
      Emit.finish(cycles)
  end

  # LD (C), A -- the same page, addressed by a register. Potion's kernel copies
  # its DMA routine into HRAM through this form.
  defp store_body(%Insn{opcode: 0xE2, cycles: cycles}) do
    Bus.high_page(Regs.c(), :a0) ++
      [RV32.mv(:t0, Regs.a()), Asm.call(:mmio_write)] ++
      Emit.finish(cycles)
  end

  # LD (a16), A -- absolute, and the form assemblers produce for `ld ($FF46), a`.
  defp store_body(%Insn{opcode: 0xEA, cycles: cycles}) do
    Emit.read_immediate16(:a0) ++
      [RV32.mv(:t0, Regs.a()), Asm.call(:mmio_write)] ++
      Emit.finish(cycles)
  end

  # The 0xCB prefix reads another byte and jumps into the second table, reached
  # through a constant displacement of 1024 -- the two tables are contiguous.
  defp prefix do
    [
      Asm.label(:h_cb),
      RV32.add(:t0, Regs.mem(), Regs.pc()),
      RV32.lbu(:t0, :t0, 0),
      RV32.addi(Regs.pc(), Regs.pc(), 1),
      RV32.and_(Regs.pc(), Regs.pc(), Regs.mask16()),
      RV32.slli(:t0, :t0, 2),
      RV32.add(:t0, Regs.dispatch(), :t0),
      RV32.lw(:t0, :t0, 4 * 256),
      RV32.jr(:t0)
    ]
  end

  # ══ The data ═════════════════════════════════════════════════════════════════

  defp data(memory, state, frames) do
    [
      {:align, 4},
      Asm.label(:table_base),
      table_base(),
      # No alignment in between: the prefix relies on a displacement of exactly
      # 1024.
      Asm.label(:table_cb),
      table_cb(),
      {:align, 4},
      Asm.label(:initial_state),
      header(state, frames),
      Asm.label(:machine_state),
      {:space, @ms_size},
      Asm.label(:tima_periods),
      for(period <- @periods, do: <<period::32-little>>),
      {:align, 4},
      Asm.label(:memory_gb),
      memory
    ]
  end

  defp table_base do
    covered = covered(nil)

    for opcode <- 0..0xFF do
      cond do
        opcode == Emit.cb_prefix() and Emit.prefix_covered?() -> {:addr, :h_cb}
        MapSet.member?(covered, opcode) -> {:addr, label(opcode)}
        true -> {:addr, :unknown_opcode}
      end
    end
  end

  defp table_cb do
    covered = covered(:cb)

    for opcode <- 0..0xFF do
      if MapSet.member?(covered, opcode) do
        {:addr, label_cb(opcode)}
      else
        {:addr, :unknown_opcode}
      end
    end
  end

  defp covered(prefix) do
    MapSet.new(for {^prefix, opcode} <- Emit.coverage(), do: opcode)
  end

  defp label(opcode), do: :"h_#{Integer.to_string(opcode, 16)}"
  defp label_cb(opcode), do: :"cb_#{Integer.to_string(opcode, 16)}"

  # `Interp`'s header, with the last word carrying frames instead of a cycle
  # budget: one level up, the unit of time is the frame.
  defp header(%State{} = state, frames) do
    control = state.ime + if(state.halted, do: 2, else: 0) + state.ime_pending * 4

    <<state.a, state.f, state.b, state.c, state.d, state.e, state.h, state.l, state.sp::16-little,
      state.pc::16-little, control, 0, 0, 0, frames::32-little>>
  end

  # ══ The record, read back ════════════════════════════════════════════════════

  defp decode(serial, duration_us, size) do
    magic = Interp.magic()

    case serial do
      <<^magic, a, f, b, c, d, e, h, l, sp::16-little, pc::16-little, control, cycles::32-little,
        status, opcode, instret::32-little, memory::binary-size(@memory)>> ->
        {:ok,
         %{
           state: %State{
             a: a,
             f: f,
             b: b,
             c: c,
             d: d,
             e: e,
             h: h,
             l: l,
             sp: sp,
             pc: pc,
             ime: control &&& 1,
             halted: (control &&& 2) != 0,
             ime_pending: control >>> 2 &&& 1
           },
           memory: memory,
           cycles: cycles,
           status: status_name(status),
           opcode: opcode,
           instret: instret,
           duration_us: duration_us,
           size: size
         }}

      other ->
        {:error,
         {:unreadable_stream, byte_size(other), binary_part(other, 0, min(32, byte_size(other)))}}
    end
  end

  defp status_name(code) do
    Enum.find_value(Interp.statuses(), :unknown, fn {name, value} -> value == code && name end)
  end
end
