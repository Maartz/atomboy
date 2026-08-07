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

  Almost what `Screen.step_line/4` models -- see the STAT mode below for the
  one place the two machines have parted company:

    * LY at 0xFF44, and LY frozen at zero with the screen off -- the PPU stops
      generating when LCDC bit 7 is clear, which is why no vblank fires then;
    * the vblank request, IF bit 0, at line 144;
    * the LY=LYC coincidence: STAT bit 2, and the STAT interrupt (IF bit 1) when
      the game armed STAT bit 6;
    * DIV, TIMA, TMA and TAC exactly as `Atomboy.Timer.advance/2` applies them,
      including the overflow that reloads from TMA and requests IF bit 2.

  Pixels are modelled too, on request -- see "The pixels" below.

  Not modelled: double speed, since `KEY1` is a Game Boy Color register and this
  loop is DMG; the GBC video DMAs (GDMA/HDMA) and the link cable, for the same
  reason.

  And one absence that is no longer a shared choice but a **divergence**: the
  STAT mode bits (0-1). `Screen` used to leave them where the guest last wrote
  them, and this loop was built to match. It no longer does: `Screen` now cuts
  the scanline into its phases -- 80 dots of OAM scan, 172 of drawing, 204 of
  HBlank -- and runs the CPU one phase at a time, so a program that polls STAT
  sees the mode move. This loop still runs the line as one block.

  The consequence is not academic. A game that waits for the mode to leave zero
  before firing a VRAM DMA -- which is precisely what the Gen-2 Pokémon do, and
  the reason Crystal showed nothing but a black screen until `Screen` learned
  the phases -- runs there and hangs here. `NativeMachineTest` masks those two
  bits to keep the rest of the differential honest; the mask is a marker, not a
  verdict. Giving this loop the same phases is the work that removes it.

  ## Composing with the interpreter

  Nothing about dispatch is written here. The 500 opcode handlers come from
  `Atomboy.Native.Emit.body/1` and `Atomboy.Native.ALU.routines/0`; the fetch, the
  slow path and the interrupt service come from
  `Atomboy.Native.Interp.routines/1`, the jump tables from
  `Atomboy.Native.Interp.tables/0`, the record and the exits from
  `Atomboy.Native.Interp.exits/1` -- with the one edge this loop needs different
  handed over as an argument: an exhausted budget lands on `line_done` instead of
  on the interpreter's exit, once per scanline, 154 times per frame.

  That argument is recent. This module used to re-emit some sixty instructions
  whose semantics are pinned by `Atomboy.CPU.Loop.fetch/17`, because `Interp`
  exposed only a finished image with its exit already welded on. Two copies of a
  hardware contract are two things to get wrong independently, and the equivalence
  tests would only have said which one much later.

  ## The memory seam: where a write stops being a store

  `Atomboy.Native.Bus` writes bytes into a flat 64 KB space. That is the right
  contract for the CPU, and the wrong one for a console: on real hardware some
  addresses *do* something when written. `Atomboy.CPU.CartLoop` intercepts them
  in `ram_write/3`, and the interceptions a DMG game cannot live without are
  reproduced here, in the routine `Bus.seam/0` names:

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

    * **Anything below 0x8000, the cartridge.** Nothing is stored -- those are MBC
      registers on hardware, and in a flat memory a store would rewrite the
      cartridge under the program's feet. With a `:rom` given, the write is a
      bank select and `Atomboy.Native.Cart` acts on it; without one it is
      dropped, which is what this loop did with it before banking existed.

  **Every** store form reaches this routine, and it took a hook in `Bus` to make
  that true. While only the three forms addressing memory absolutely were routed
  -- `LDH (a8), A`, `LD (C), A`, `LD (a16), A` -- a game asking for an OAM DMA
  through `LD HL, $FF46 / LD (HL), A` laid down a plain byte and got no transfer.
  See `Atomboy.Native.Bus` for the shape of the check and what it costs.

  ## The pixels

  With `render: true` the loop calls `Atomboy.Native.PPU` once per visible
  scanline and a frame comes back with the memory. The call sits where
  `Atomboy.Screen.frame/4` puts it -- after the line's CPU slice and after the
  timer -- and that position is not free to choose: the scroll registers a game
  writes during a line have to show in the pixels of the line it wrote them on,
  which is how a raster effect is built. The renderer costs nothing to arrange,
  which is its own doing: it saves every `s` register and `a1`-`a4`, so the whole
  SM83 state survives a call made between two scanlines with nothing spilled here.

  Two counters live across the lines of a frame and reset at the frame: the
  window's internal line counter, which counts the lines the window actually
  showed on rather than the scanlines, and the destination, which walks the
  framebuffer from the top. Every frame overwrites the last, so what comes back is
  the frame a panel would be showing.

  The framebuffer -- `Atomboy.Native.PPU.frame_bytes/0` bytes, one shade per
  pixel -- sits in the image's data, **outside** the 64 KB. Outside is the point
  rather than a convenience: a DMG has no framebuffer anywhere in its address
  space, the panel is fed a line at a time as the PPU produces it, and a buffer
  the game could address would be an invention this emulator would then have to
  keep. It exists here only because the pixels must survive until the run ends and
  cross a serial port; on the C6 it is what the DMA to the real panel will read
  from.

  Rendering is off by default, and the default earns its keep twice: a run that
  only has to agree on memory does not pay 144 scanlines per frame, and the two
  regimes measured apart are what turn one number into two. Measured on hero.gb
  under `qemu -icount shift=0`, marginal cost per frame in steady state:

      CPU and cadence      339,443 RV32 instructions
      with the renderer    976,181       -- the PPU is 636,738 of them
      code                 16,808 bytes, against the C6's 32 KB of icache

  Routing every store through the seam instead of only the three absolute forms
  cost 768 bytes of code and, on this game, *saved* 74 instructions per frame:
  the forms that used to call the seam unconditionally now compare two registers
  first, and hero writes more I/O registers absolutely than it writes bytes
  through `(HL)`.

  ## The protocol

  `Interp`'s, extended by appending rather than by changing: state, frame count,
  the timer's phase and 64 KB baked into the image; a 24-byte record followed by
  the final 64 KB coming back over the serial port, then the frame if one was
  drawn, then the timer's phase again. A reader that knows only the record and the
  memory finds both exactly where they were, and one that also knows about pixels
  finds those unmoved too -- appending is the only extension that keeps that true,
  which is why the timer went last and not into the record.

  The `cycles` field carries the total across every line of every frame, not the
  last line's, which is the only number a caller could want.

  The timer's sub-counters -- the fractions of a DIV and a TIMA period that no
  register shows -- travel in both directions. Feeding the phase a run reports
  back into the next image is what makes chaining exact: ten frames run as one
  image and ten run as ten now agree on the timer as well as on the CPU and the
  memory. They used to start at zero on every image, which lost up to 455 cycles
  of phase per boundary.
  """

  import Bitwise

  alias Atomboy.CPU.State
  alias Atomboy.Native.ALU
  alias Atomboy.Native.APU
  alias Atomboy.Native.APUBench
  alias Atomboy.Native.Asm
  alias Atomboy.Native.Bus
  alias Atomboy.Native.Blob
  alias Atomboy.Native.Cart
  alias Atomboy.Native.Image
  alias Atomboy.Native.Interp
  alias Atomboy.Native.PPU
  alias Atomboy.Native.Qemu
  alias Atomboy.Native.Regs
  alias Atomboy.Native.RV32

  # The cadence, from `Atomboy.Screen`. Same names, same values -- a divergence
  # here would be a divergence nobody reads. The visible height is the renderer's
  # to own: it is the frame's, not the loop's.
  @line_cycles 456
  @visible PPU.height()
  @lines 154

  @joyp 0xFF00
  @div 0xFF04
  @tima 0xFF05
  @tma 0xFF06
  @tac 0xFF07
  @irq_if 0xFF0F
  # The four NRx4 registers, five bytes apart: bit 7 of any of them triggers its
  # channel. Only the ends are named -- the arithmetic in `apu_trigger/1` finds
  # the two in between.
  @nr14 0xFF14
  @nr44 0xFF23

  @lcdc 0xFF40
  @stat 0xFF41
  @ly 0xFF44
  @lyc 0xFF45
  @dma 0xFF46

  # The four TIMA rates in T-cycles, in TAC's bit order -- `Atomboy.Timer`'s
  # tuple, as a word table the guest indexes.
  @periods [1024, 16, 64, 256]

  @memory 0x10000

  # The machine's own state, in a word block the CPU slice cannot reach: the
  # scanline, the frames left to run, the timer's two sub-counters, the cycle
  # total, and the two the renderer needs. It lives in memory rather than in
  # registers because the interpreter owns almost all of them, and the one that is
  # left points here.
  #
  # The two sub-counters are adjacent on purpose: the run reports them as one
  # eight-byte region rather than as two fields, so there is one offset to keep
  # right instead of two.
  @ms_ly 0
  @ms_frames 4
  @ms_div 8
  @ms_tima 12
  @ms_total 16
  @ms_window 20
  @ms_pixels 24
  @ms_size 28
  @ms_timer_size 8

  @frame_bytes PPU.frame_bytes()

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

  @doc "The bytes of one rendered frame -- `Atomboy.Native.PPU.frame_bytes/0`."
  @spec frame_bytes() :: 23040
  def frame_bytes, do: @frame_bytes

  @doc """
  Assembles an image running `frames` complete frames from `state` over `memory`.

  `memory` is the flat 64 KB address space: ROM in the low half, the rest as the
  caller wants it read. The image runs `frames` × 154 scanlines and then reports.

  Options:

    * `:render` -- call `Atomboy.Native.PPU` on every visible scanline and send
      the last frame's pixels back after the memory. Off by default, and the
      default is not laziness: a run that only has to agree on memory should not
      pay for 144 scanlines of rendering per frame, and keeping the two regimes
      apart is what makes the two cost measurements mean anything. With rendering
      off the PPU's routines are not even assembled into the image.
    * `:timer` -- the divider's and TIMA's sub-counters to start from, as
      `{div, tima}`. Zero by default, which is a fresh console; handing back what
      a previous run reported is what makes two chained runs exact.
  """
  @spec image(binary(), State.t(), pos_integer(), keyword()) :: Asm.assembled()
  def image(memory, %State{} = state, frames, opts \\ [])
      when byte_size(memory) == @memory and is_integer(frames) and frames > 0 do
    render? = Keyword.get(opts, :render, false)
    audio? = Keyword.get(opts, :audio, false)
    rom = Keyword.get(opts, :rom)

    Image.build(
      [
        driver(render?, rom, true),
        scanline(),
        line_done(render?, audio?),
        Interp.routines(budget_exit: :line_done),
        exits(render?, audio?),
        seam(rom, audio?),
        Interp.handlers(),
        ALU.routines(),
        if(render?, do: PPU.routines(), else: []),
        if(audio?, do: APU.routines(), else: [])
      ],
      data(memory, state, frames, render?, audio?, Keyword.get(opts, :timer, {0, 0}), rom)
    )
  end

  @typedoc """
  What the guest reports at the end of the last frame.

  `pixels` is the last frame rendered, or `nil` when the image ran without a
  renderer. `timer` is the phase the two sub-counters stopped on, ready to be
  handed to the next `image/4` as `:timer`.
  """
  @type result :: %{
          state: State.t(),
          memory: binary(),
          pixels: binary() | nil,
          samples: binary() | nil,
          apu: Atomboy.APU.t() | nil,
          cycles: non_neg_integer(),
          timer: {non_neg_integer(), non_neg_integer()},
          status: :ok | :unknown_opcode,
          opcode: 0..0xFF,
          instret: non_neg_integer(),
          duration_us: non_neg_integer(),
          size: non_neg_integer()
        }

  @doc """
  Runs `frames` frames under qemu and decodes what came back.

  Same shape as `Atomboy.Native.Run.run/4`, one level up: the budget is a number
  of frames, not of cycles, and the hardware advances in between. `:render` and
  `:timer` go to `image/4`; everything else goes to `Atomboy.Native.Qemu.run/2`.
  """
  @spec run(binary(), State.t(), pos_integer(), keyword()) :: {:ok, result()} | {:error, term()}
  def run(memory, %State{} = state, frames, opts \\ []) do
    render? = Keyword.get(opts, :render, false)
    audio? = Keyword.get(opts, :audio, false)

    image =
      image(memory, state, frames,
        render: render?,
        audio: audio?,
        timer: Keyword.get(opts, :timer, {0, 0}),
        rom: Keyword.get(opts, :rom)
      )

    case Qemu.run(image.code, opts) do
      %{status: :timeout, duration_us: us} ->
        {:error, {:timeout, us}}

      %{status: :ok, serial: serial, duration_us: us} ->
        decode(serial, us, image.size, render?, audio?)
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
  # `Interp`'s preamble, plus what only a console has: the console's write bounds,
  # the pointer to the machine's word block, the frame count out of the header,
  # and the timer's phase -- also out of the header, which is what lets a run
  # continue another one rather than restart it.

  defp driver(render?, rom, instret?) do
    header = Interp.header_offsets()

    [
      Interp.prologue(),
      Cart.install(rom),
      Bus.bounds(:console),
      Asm.la(@state_pointer, :machine_state),
      RV32.lw(:t0, :t2, header.word),
      RV32.sw(:t0, @state_pointer, @ms_frames),
      RV32.lbu(:t0, :t2, header.div),
      RV32.sw(:t0, @state_pointer, @ms_div),
      RV32.lhu(:t0, :t2, header.tima),
      RV32.sw(:t0, @state_pointer, @ms_tima),
      RV32.sw(:zero, @state_pointer, @ms_total),
      # Only under qemu. `instret` is CSR 0xC02, an optional user-level counter
      # the C6 does not implement -- reading it there is an illegal instruction,
      # and it took a Guru Meditation on the board to find out. Nothing on
      # silicon wants it anyway: the host times the call in CPU cycles.
      if(instret?, do: Interp.instret_baseline(), else: []),
      Asm.label(:frame_loop),
      RV32.sw(:zero, @state_pointer, @ms_ly),

      # Both renderer counters are per-frame, and both for the same reason: the
      # frame is the unit `Atomboy.Screen.frame/4` resets them at. The window's
      # internal line counter starts each frame at zero -- it counts the lines the
      # window actually showed on, not the scanlines -- and the destination walks
      # the framebuffer from the top. Every frame overwrites the previous one, so
      # what comes back is the last frame drawn, which is what a panel would be
      # showing.
      if render? do
        [
          RV32.sw(:zero, @state_pointer, @ms_window),
          Asm.la(:t0, :framebuffer),
          RV32.sw(:t0, @state_pointer, @ms_pixels)
        ]
      else
        []
      end
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

  defp line_done(render?, audio?) do
    [
      Asm.label(:line_done),
      RV32.lw(:t0, @state_pointer, @ms_total),
      RV32.add(:t0, :t0, Regs.cycles()),
      RV32.sw(:t0, @state_pointer, @ms_total),
      divider(),
      counter(),
      render(render?),
      Asm.label(:line_next),
      RV32.lw(:t0, @state_pointer, @ms_ly),
      RV32.addi(:t0, :t0, 1),
      RV32.sw(:t0, @state_pointer, @ms_ly),
      RV32.li(:t1, @lines),
      Asm.bltu(:t0, :t1, :line_loop),

      # The frame is over, and the sound of it is generated here rather than per
      # scanline. `Atomboy.APU.frame/2` does the same, and for the same reason:
      # a game lays its notes down at vblank, so one frame of granularity is the
      # time scale music is written on. It also means the registers are read once
      # for 549 samples instead of 154 times for three and a half.
      #
      # The position is after the last line's timer, which is where the renderer
      # would be if there were a 155th line -- everything the frame did has
      # happened before a byte of its sound exists.
      apu_frame(audio?),

      # One less frame to run.
      RV32.lw(:t0, @state_pointer, @ms_frames),
      RV32.addi(:t0, :t0, -1),
      RV32.sw(:t0, @state_pointer, @ms_frames),
      Asm.bnez(:t0, :frame_loop),

      # The record reports the total, not the last line's count.
      RV32.lw(Regs.cycles(), @state_pointer, @ms_total),
      Asm.j(:materialise)
    ]
  end

  defp apu_frame(false), do: []

  defp apu_frame(true) do
    [
      Asm.la(:t0, :apu_buffer),
      Asm.call(APU.label())
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
  #
  # A disabled timer leaves through `line_render`, not `line_next`. That is not
  # cosmetic: while the renderer sat behind `line_next`, this one branch skipped it
  # on every line of every game that does not arm its timer -- which is most of
  # them, hero.gb included. The label exists so the early exit cannot silently
  # bypass a later stage of the line again.
  defp counter do
    [
      Asm.label(:tima_start),
      RV32.li(:t2, @tac),
      RV32.add(:t2, Regs.mem(), :t2),
      RV32.lbu(:t3, :t2, 0),
      RV32.andi(:t4, :t3, 0x04),
      Asm.beqz(:t4, :line_render),
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

  # ══ The pixels ═══════════════════════════════════════════════════════════════
  #
  # One scanline of `Atomboy.Native.PPU`, at the point in the line where
  # `Atomboy.Screen.frame/4` calls `Atomboy.PPU.render_line/3`: **after** the CPU
  # has run its 456 cycles and after the timer has caught up.
  #
  # That position is the whole fidelity question, and it is observable. A game that
  # rewrites SCX or SCY during a line -- which is how a raster effect is built --
  # must have those writes visible in the pixels of the line it wrote them on.
  # Rendering before the slice would show the previous line's registers; the oracle
  # renders after, so this renders after.
  #
  # The call itself costs nothing to arrange, which is the PPU's doing rather than
  # ours: it saves every `s` register and `a1`-`a4`, so the whole SM83 state --
  # HL, PC, the opcode, and the pointer to this block -- survives a call made
  # between two scanlines with no spill on our side.
  defp render(false), do: [Asm.label(:line_render)]

  defp render(true) do
    [
      Asm.label(:line_render),
      RV32.lw(:a0, @state_pointer, @ms_ly),
      RV32.li(:t2, @visible),

      # The vblank lines have no pixels. `bgeu` rather than a subtraction: LY is
      # 0..153 and the renderer's contract is 0..143.
      Asm.bgeu(:a0, :t2, :line_next),
      RV32.lw(:t0, @state_pointer, @ms_window),
      RV32.lw(:t1, @state_pointer, @ms_pixels),
      Asm.call(PPU.label()),

      # `a0` comes back carrying the window's counter, and `t1` is gone -- the
      # destination is re-read to be advanced.
      RV32.sw(:a0, @state_pointer, @ms_window),
      RV32.lw(:t0, @state_pointer, @ms_pixels),
      RV32.addi(:t0, :t0, PPU.width()),
      RV32.sw(:t0, @state_pointer, @ms_pixels)
    ]
  end

  # ══ The I/O seam ═════════════════════════════════════════════════════════════
  #
  # Where `Atomboy.Native.Bus` sends a store whose address falls outside the range
  # a store is only a store in. `a0` the guest address, `t0` the byte -- and the
  # byte has **already** been written when the address is at or above 0xFF00, which
  # is what keeps the check off the fast path. Anything this routine has to do
  # differently, it does by writing again.
  #
  # Clobbers t0-t4, a0 and ra; every SM83 register survives, the opcode in `a1`
  # included.
  #
  # Nothing here guards the cartridge: a store below 0x8000 never reaches this
  # routine, because `Bus` drops it before the store rather than after -- which is
  # the only order that works, there being no way to un-write a byte.

  defp seam(rom, audio?) do
    [
      Asm.label(Bus.seam()),

      # Below 0x8000 nothing was stored and nothing is going to be: this is the
      # cartridge being spoken to, and only `Atomboy.Native.Cart` knows what it
      # was told.
      Asm.bltu(:a0, Regs.rom_top(), :cart_write),

      # 0xFF00: the matrix recomposed, as `Atomboy.Joypad.write/2` does it. Bits
      # 7-6 read high, the selection is kept, and the four lines of the selected
      # rows come back active low -- all released here, hence 0x0F.
      RV32.li(:t1, @joyp),
      Asm.bne(:a0, :t1, :mmio_div),
      RV32.andi(:t0, :t0, 0x30),
      Asm.la(:t2, :pad_state),
      RV32.lw(:t2, :t2, 0),
      RV32.li(:t3, 0x0F),

      # P14 clear selects the directions, P15 the buttons, and a game may select
      # both at once -- the lines are then the two rows together, which is why
      # this masks twice into one accumulator instead of choosing a branch.
      RV32.andi(:t4, :t0, 0x10),
      Asm.bnez(:t4, :pad_buttons),
      RV32.andi(:t4, :t2, 0x0F),
      RV32.xori(:t4, :t4, -1),
      RV32.and_(:t3, :t3, :t4),
      Asm.label(:pad_buttons),
      RV32.andi(:t4, :t0, 0x20),
      Asm.bnez(:t4, :pad_done),
      RV32.srli(:t4, :t2, 4),
      RV32.andi(:t4, :t4, 0x0F),
      RV32.xori(:t4, :t4, -1),
      RV32.and_(:t3, :t3, :t4),
      Asm.label(:pad_done),
      RV32.ori(:t0, :t0, 0xC0),
      RV32.or_(:t0, :t0, :t3),
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
      Asm.bne(:a0, :t1, :mmio_apu),
      RV32.li(:t1, 0x80),
      Asm.bltu(:t0, :t1, :mmio_done),
      RV32.slli(:t2, :t0, 8),
      RV32.add(:t2, Regs.mem(), :t2),
      RV32.li(:t3, 0xFE00),
      RV32.add(:t3, Regs.mem(), :t3),
      RV32.li(:t4, 0xA0),
      Asm.label(:dma_loop),
      Asm.beqz(:t4, :mmio_done),
      RV32.lbu(:t1, :t2, 0),
      RV32.sb(:t1, :t3, 0),
      RV32.addi(:t2, :t2, 1),
      RV32.addi(:t3, :t3, 1),
      RV32.addi(:t4, :t4, -1),
      Asm.j(:dma_loop),
      apu_trigger(audio?),
      Asm.label(:mmio_store),
      RV32.add(:t1, Regs.mem(), :a0),
      RV32.sb(:t0, :t1, 0),
      Asm.label(:mmio_done),
      RV32.ret(),
      Cart.handle(rom, :mmio_done)
    ]
  end

  # NRx4 with bit 7 set: a channel is being triggered. `Atomboy.CPU.CartLoop`
  # captures the same four addresses and puts the channel on a list the APU
  # replays; here it sets one of four bits, which is the same thing said shorter
  # -- see `Atomboy.Native.APU` on why order and repetition are not observable.
  #
  # The byte itself has already been stored, as it has for every address at or
  # above 0xFF00, and it stays readable exactly as written. That is what the
  # hardware does not do -- bit 7 never reads back on a DMG -- and what the
  # oracle does, so it is what happens here.
  #
  # The arithmetic is `div(addr - 0xFF14, 5)`, which is `CartLoop`'s own
  # expression rather than four comparisons that would drift from it. The four
  # NRx4 registers are five bytes apart and nothing else in the window is, so a
  # remainder of zero identifies them.
  defp apu_trigger(false), do: [Asm.label(:mmio_apu)]

  defp apu_trigger(true) do
    offsets = APU.offsets()

    [
      Asm.label(:mmio_apu),
      RV32.andi(:t1, :t0, 0x80),
      Asm.beqz(:t1, :mmio_done),
      RV32.li(:t1, @nr14),
      Asm.bltu(:a0, :t1, :mmio_done),
      RV32.sub(:t1, :a0, :t1),
      RV32.li(:t2, @nr44 - @nr14),
      Asm.bltu(:t2, :t1, :mmio_done),
      RV32.li(:t2, 5),
      RV32.remu(:t3, :t1, :t2),
      Asm.bnez(:t3, :mmio_done),
      RV32.divu(:t1, :t1, :t2),
      RV32.li(:t2, 1),
      RV32.sll(:t1, :t2, :t1),
      Asm.la(:t2, :apu_state),
      RV32.lw(:t3, :t2, offsets.triggers),
      RV32.or_(:t3, :t3, :t1),
      RV32.sw(:t3, :t2, offsets.triggers),
      Asm.j(:mmio_done)
    ]
  end

  # ══ The exits ════════════════════════════════════════════════════════════════
  #
  # `Interp`'s record, then the regions, in the order they go on the wire. The
  # memory first because that is where it has always been, the frame after it, and
  # the timer's phase last -- appending is what lets a reader that knows only the
  # first region keep working.

  defp exits(render?, audio?) do
    pixels =
      if render? do
        [{:pixels, [Asm.la(:t3, :framebuffer)], @frame_bytes}]
      else
        []
      end

    # A whole frame's worth, always, whether the frame produced 548 samples or
    # 549. A region whose length depended on the run would have to be framed with
    # a count, and the count is already in the record's own trailing word -- the
    # reader trims. Fixed regions are what let a reader that knows only the first
    # one keep working.
    audio =
      if audio? do
        [
          {:samples, [Asm.la(:t3, :apu_buffer)], APU.max_bytes()},

          # And the channel state the frame stopped on. It is not there for the
          # caller -- nothing above this needs it -- but for the bench: when the
          # samples disagree after five hundred frames of accumulation, the
          # question is *which of thirty fields* drifted, and a stream that only
          # carries the output cannot answer it.
          {:apu_state, [Asm.la(:t3, :apu_state)], APU.state_bytes()}
        ]
      else
        []
      end

    Interp.exits(
      [{:memory, [Asm.la(:t3, :memory_gb)], @memory}] ++
        pixels ++
        [
          {:timer, [Asm.la(:t3, :machine_state), RV32.addi(:t3, :t3, @ms_div)], @ms_timer_size}
        ] ++ audio
    )
  end

  # status, opcode, cycles, framebuffer, memory, samples, sample count.
  @result_size 28

  @doc """
  The same machine, as a subroutine an ESP-IDF application calls.

  `image/4` builds something that boots, talks to a 16550 UART and powers the
  machine off; on an ESP32-C6 none of those exist and none of them is wanted.
  This emits the identical body -- the same driver, the same 501 handlers, the
  same renderer -- wrapped by `Atomboy.Native.Blob` and ending in a `ret`
  instead of a serial dump.

  Assembled at base 0 and position independent: the caller copies the bytes
  into executable memory and calls offset 0 as `uint32_t (*)(void *)`.

  What comes back in `a0` is the address of a five-word block:

      0   status      0 ok, 1 stopped on an opcode it does not know
      4   opcode      the byte it stopped on, when it stopped
      8   cycles      T-cycles run, the whole run
      12  framebuffer the last frame, one shade per pixel -- 0 without `:render`
      16  memory      the 64 KB, so a host can read OAM or a save
      20  samples     the last frame's stereo s16le -- 0 without `:audio`
      24  count       how many stereo samples of it are the frame's

  `count` is 548 or 549 and never both: 70,224 cycles over 128 leaves a fraction
  that accumulates, so a caller pushing `samples` at an I2S peripheral has to
  read the count rather than assume one. Assuming 548 forever drifts by a sample
  every eight frames, which is 8 Hz of pitch error and audible within a minute.

  The guest's state lives inside the blob, so the copy the caller keeps *is* the
  console: calling again continues where the last call stopped. What it must not
  do is call the pristine bytes twice -- see `Atomboy.Native.Blob.relocate/0`.
  """
  @spec blob(binary(), State.t(), pos_integer(), keyword()) :: Asm.assembled()
  def blob(memory, %State{} = state, frames, opts \\ [])
      when byte_size(memory) == @memory and is_integer(frames) and frames > 0 do
    render? = Keyword.get(opts, :render, true)
    audio? = Keyword.get(opts, :audio, true)
    rom = Keyword.get(opts, :rom)

    Blob.build(
      [
        # `a0` still holds what the caller passed and nothing has touched it:
        # the frame's buttons, one bit each, in Potion's order. The seam reads
        # this word every time the game strobes 0xFF00.
        Asm.la(:t0, :pad_state),
        RV32.sw(:a0, :t0, 0),
        driver(render?, rom, false),
        scanline(),
        line_done(render?, audio?),
        Interp.routines(budget_exit: :line_done),
        blob_exits(render?, audio?),
        seam(rom, audio?),
        Interp.handlers(),
        ALU.routines(),
        if(render?, do: PPU.routines(), else: []),
        if(audio?, do: APU.routines(), else: [])
      ],
      data(memory, state, frames, render?, audio?, Keyword.get(opts, :timer, {0, 0}), rom) ++
        [{:align, 4}, Asm.label(:blob_result), {:space, @result_size}]
    )
  end

  @doc "How many bytes the block `blob/4` returns a pointer to occupies."
  @spec result_size() :: pos_integer()
  def result_size, do: @result_size

  # The two exits an image sends over a serial port, answered instead. Both
  # labels have to exist under either regime: `unknown_opcode` is what 500 jump
  # table entries point at for a byte no handler covers.
  defp blob_exits(render?, audio?) do
    statuses = Interp.statuses()

    [
      Asm.label(:materialise),
      RV32.li(:t2, statuses.ok),
      Asm.j(:blob_report),
      Asm.label(:unknown_opcode),
      RV32.li(:t2, statuses.unknown_opcode),
      Asm.label(:blob_report),

      # The state written back where the prologue will read it. Without this a
      # second call would reload the boot registers and replay the same frames
      # over a memory that had already moved -- the console would stutter back
      # to its first instant while its RAM kept going. With it, the copy the
      # caller holds *is* the console, and calling again is simply time passing.
      Asm.la(:t1, :initial_state),
      RV32.sb(Regs.a(), :t1, 0),
      RV32.sb(Regs.f(), :t1, 1),
      RV32.sb(Regs.b(), :t1, 2),
      RV32.sb(Regs.c(), :t1, 3),
      RV32.sb(Regs.d(), :t1, 4),
      RV32.sb(Regs.e(), :t1, 5),
      RV32.srli(:t0, Regs.hl(), 8),
      RV32.sb(:t0, :t1, 6),
      RV32.sb(Regs.hl(), :t1, 7),
      RV32.sh(Regs.sp(), :t1, 8),
      RV32.sh(Regs.pc(), :t1, 10),
      RV32.sb(Regs.control(), :t1, 12),

      # And the timer's phase -- the fraction of a period neither register
      # shows. Chaining runs without it restarts the phase every call, which is
      # the one thing `image/4` already refused to do between frames.
      RV32.lw(:t0, @state_pointer, @ms_div),
      RV32.sb(:t0, :t1, 13),
      RV32.lw(:t0, @state_pointer, @ms_tima),
      RV32.sh(:t0, :t1, 14),
      Asm.la(:a0, :blob_result),
      RV32.sw(:t2, :a0, 0),
      RV32.sw(Regs.opcode(), :a0, 4),
      RV32.lw(:t0, @state_pointer, @ms_total),
      RV32.sw(:t0, :a0, 8),
      if render? do
        [Asm.la(:t0, :framebuffer)]
      else
        [RV32.li(:t0, 0)]
      end,
      RV32.sw(:t0, :a0, 12),
      Asm.la(:t0, :memory_gb),
      RV32.sw(:t0, :a0, 16),
      if audio? do
        [
          Asm.la(:t0, :apu_buffer),
          RV32.sw(:t0, :a0, 20),
          Asm.la(:t0, APU.count_label()),
          RV32.lw(:t0, :t0, 0),
          RV32.sw(:t0, :a0, 24)
        ]
      else
        [RV32.sw(:zero, :a0, 20), RV32.sw(:zero, :a0, 24)]
      end,
      Asm.j(Blob.return())
    ]
  end

  # ══ The data ═════════════════════════════════════════════════════════════════

  defp data(memory, state, frames, render?, audio?, timer, rom) do
    [
      Interp.tables(),
      Cart.data(rom),
      {:align, 4},
      Asm.label(:initial_state),
      Interp.header(state, frames, timer: timer),
      {:align, 4},
      Asm.label(:pad_state),
      {:space, 4},
      Asm.label(:machine_state),
      {:space, @ms_size},
      Asm.label(:tima_periods),
      for(period <- @periods, do: <<period::32-little>>),
      {:align, 4},
      Asm.label(:memory_gb),
      memory,

      # The framebuffer sits after the emulated memory, in the image's own data --
      # 23040 bytes of plain RAM outside the 64 KB the guest can address. Outside is
      # the point: a DMG has no framebuffer anywhere in its address space, the panel
      # is fed a line at a time as the PPU produces it, and a buffer the game could
      # reach would be an invention. Here it exists only because the pixels have to
      # survive until the run ends and cross a serial port; on the C6 this is where
      # the DMA to the real panel will read from instead.
      if render? do
        [
          PPU.data(),
          {:align, 4},
          Asm.label(:framebuffer),
          {:space, @frame_bytes}
        ]
      else
        []
      end,

      # And the sound, on the same terms as the pixels and for the same reason:
      # outside the 64 KB, because a DMG has no sample buffer in its address
      # space either. 2,196 bytes, the largest a frame can be.
      if audio? do
        [
          APU.data(),
          {:align, 4},
          Asm.label(:apu_buffer),
          {:space, APU.max_bytes()}
        ]
      else
        []
      end
    ]
  end

  # ══ The record, read back ════════════════════════════════════════════════════

  defp decode(serial, duration_us, size, render?, audio?) do
    magic = Interp.magic()
    pixels = if render?, do: @frame_bytes, else: 0
    sound = if audio?, do: APU.max_bytes(), else: 0
    apu_state = if audio?, do: APU.state_bytes(), else: 0

    case serial do
      <<^magic, a, f, b, c, d, e, h, l, sp::16-little, pc::16-little, control, cycles::32-little,
        status, opcode, instret::32-little, memory::binary-size(@memory),
        frame::binary-size(pixels), div_sub::32-little, tima_sub::32-little,
        samples::binary-size(sound), apu::binary-size(apu_state)>> ->
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
           pixels: if(render?, do: frame, else: nil),
           samples: if(audio?, do: samples, else: nil),
           apu: if(audio?, do: APUBench.decode_state(apu), else: nil),
           cycles: cycles,
           timer: {div_sub, tima_sub},
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
