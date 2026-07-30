defmodule Atomboy.NativeMachineTest do
  @moduledoc """
  The native machine loop against `Atomboy.Screen` -- differential, per frame.

  The method is `native_interp_test.exs`'s, one level up. There, the unit of
  comparison was a cycle budget; here it is a frame, and what has to agree is no
  longer just the CPU but the console around it: LY, the vblank request, the
  timer's four registers, the joypad's matrix, the OAM after a DMA.

  ## The two memory models, made to meet

  `Atomboy.Screen` runs on `Atomboy.CPU.CartLoop`: a ROM binary plus a map of
  writes, where an address never written reads back 0xFF and a handful of
  registers do something when written. The native side runs on a flat 64 KB
  array. The two only agree if they start from the same bytes, and the map's
  defaults are not always the ones the CPU would read -- `Atomboy.Timer` treats an
  absent TAC as zero, where the CPU reading the same absent key gets 0xFF and a
  running timer. So the boot I/O state is written out explicitly, in `seed/0`,
  and both sides receive it: the oracle as map entries, the guest as bytes. That
  is not a concession to the harness, it is the post-boot state a real DMG hands
  the cartridge, which neither model bakes in.

  ## What is not compared, and why

    * **0x0000-0x7FFF** is compared to the ROM itself rather than to the oracle:
      the point is that the guest did not write there. A flat memory has no MBC
      to swallow a bank-select write, so a program writing to 0x2000 would rewrite
      its own code -- `mmio_write` drops those writes, and this is the assertion
      that says so.
    * **0xA000-0xBFFF**, the cartridge RAM, sits behind the MBC's enable latch on
      the oracle side and is plain memory natively. No program here has SRAM.
    * **0xE000-0xFDFF**, the WRAM echo, is rewired to 0xC000 by the oracle and is
      ordinary memory natively. Reads would need the same rewiring in
      `Atomboy.Native.Bus`, which this stage does not own; nothing here reads
      through the mirror.
  """

  use ExUnit.Case, async: true

  import Bitwise

  alias Atomboy.CPU.CartLoop
  alias Atomboy.CPU.State
  alias Atomboy.Native.Machine
  alias Atomboy.Screen
  alias Potion.ROM

  @moduletag :qemu
  # One qemu launch, a 64 KB dump per run, and ten frames of a real game.
  @moduletag timeout: 600_000

  # The regions where the two models must agree byte for byte.
  @regions [
    {0x8000, 0x9FFF},
    {0xC000, 0xDFFF},
    {0xFE00, 0xFEFF},
    {0xFF00, 0xFFFF}
  ]

  # ══ The cadence ══════════════════════════════════════════════════════════════

  describe "the cadence" do
    test "a frame is 154 scanlines of 456 T-cycles" do
      # A memory of NOPs: 4 T each, so the budget is met exactly and the total is
      # the arithmetic itself. Any drift in the line count or the budget shows up
      # here as a round number that is not the right one.
      result = Machine.run!(:binary.copy(<<0x00>>, 0x10000), %State{pc: 0x100}, 1)

      assert result.status == :ok
      assert result.cycles == 154 * 456
    end

    test "three frames cost three times as much" do
      result = Machine.run!(:binary.copy(<<0x00>>, 0x10000), %State{pc: 0x100}, 3)

      assert result.cycles == 3 * 154 * 456
    end

    test "with the screen off LY stays at zero and no vblank is requested" do
      # LCDC bit 7 clear: the PPU stops generating. `Atomboy.Screen` models this
      # deliberately -- a game that turns the screen off to reload VRAM keeps its
      # interrupts open, and a phantom vblank would re-enter its sound engine on
      # top of itself.
      result = Machine.run!(sleeper(%{0xFF40 => 0x00, 0xFF41 => 0xFF}), %State{pc: 0x100}, 1)

      assert result.status == :ok
      assert :binary.at(result.memory, 0xFF44) == 0, "LY moved with the screen off"
      assert :binary.at(result.memory, 0xFF0F) == 0, "vblank requested with the screen off"
      assert :binary.at(result.memory, 0xFF41) == 0xF8, "the STAT mode bits were not cleared"
    end

    test "a frame with the screen on requests the vblank and ends on line 153" do
      # Which line raised the flag is not visible from here -- IF is read once, at
      # the end of the frame. The line itself is pinned in the differential test
      # whose handler records LY as it runs.
      result = Machine.run!(sleeper(%{0xFF40 => 0x91}), %State{pc: 0x100}, 1)

      assert result.status == :ok
      assert :binary.at(result.memory, 0xFF44) == 153, "LY ends on the last scanline"
      assert band(:binary.at(result.memory, 0xFF0F), 0x01) != 0
    end

    test "the LY=LYC coincidence fires the STAT interrupt only when it is armed" do
      # LYC 100, STAT bit 6 set: bit 2 reflects the coincidence and IF bit 1 is
      # requested. This is the tool of raster effects, and the one PPU behaviour
      # `Screen` models beyond LY itself.
      armed = sleeper(%{0xFF41 => 0x40, 0xFF45 => 100})
      idle = sleeper(%{0xFF41 => 0x00, 0xFF45 => 100})

      armed_if = :binary.at(Machine.run!(armed, %State{pc: 0x100}, 1).memory, 0xFF0F)
      idle_if = :binary.at(Machine.run!(idle, %State{pc: 0x100}, 1).memory, 0xFF0F)

      assert band(armed_if, 0x02) != 0, "STAT bit 6 was armed and no interrupt was requested"
      assert band(idle_if, 0x02) == 0, "a STAT interrupt fired without being armed"
    end
  end

  # ══ The I/O seam ═════════════════════════════════════════════════════════════

  describe "the I/O seam" do
    test "reading the joypad back gives the matrix, not the byte that was written" do
      # `ld a, 0x20; ldh (0x00), a; ldh a, (0x00)` -- the gesture every game makes
      # twice per frame. Returning 0x20 would report the four buttons of the
      # selected row as held down: Tetris reads its soft-reset combo there.
      memory =
        memory(
          %{
            0x100 => 0x3E,
            0x101 => 0x20,
            0x102 => 0xE0,
            0x103 => 0x00,
            0x104 => 0xF0,
            0x105 => 0x00,
            0x106 => 0x76
          },
          %{}
        )

      result = Machine.run!(memory, %State{pc: 0x100}, 1)

      assert result.state.a == 0xEF, "the buttons row must read as released"
      assert :binary.at(result.memory, 0xFF00) == 0xEF
    end

    test "a write to DIV resets the counter and its sub-counter" do
      # Potion's kernel does this on its second instruction. Without the reset the
      # sub-counter keeps its phase and DIV drifts by one for the rest of the run.
      # `ld a, 0xAB; ldh (0x04), a; halt`
      memory =
        memory(%{0x100 => 0x3E, 0x101 => 0xAB, 0x102 => 0xE0, 0x103 => 0x04, 0x104 => 0x76}, %{})

      result = Machine.run!(memory, %State{pc: 0x100}, 1)

      # The write lands in line 0, before the first advance: what DIV shows at the
      # end is 154 lines of 456 cycles counted from zero.
      assert :binary.at(result.memory, 0xFF04) == band(div(154 * 456, 256), 0xFF)
    end

    test "a write to 0xFF46 copies the page into OAM" do
      # `ld a, 0xC0; ldh (0x46), a; halt` with a marked page at 0xC000.
      page = for offset <- 0..0xFF, into: %{}, do: {0xC000 + offset, offset}

      memory =
        memory(
          %{0x100 => 0x3E, 0x101 => 0xC0, 0x102 => 0xE0, 0x103 => 0x46, 0x104 => 0x76},
          page
        )

      result = Machine.run!(memory, %State{pc: 0x100}, 1)

      copied = for offset <- 0..0x9F, do: :binary.at(result.memory, 0xFE00 + offset)
      assert copied == Enum.to_list(0..0x9F)
      assert :binary.at(result.memory, 0xFEA0) == 0xFF, "the copy stopped at 160 bytes"
    end

    test "a write into the ROM region does not rewrite the program" do
      # On hardware 0x2000 is a bank-select register. In a flat memory an
      # unguarded store would overwrite the running code.
      # `ld a, 0x01; ld (0x2000), a; halt`
      memory =
        memory(
          %{
            0x100 => 0x3E,
            0x101 => 0x01,
            0x102 => 0xEA,
            0x103 => 0x00,
            0x104 => 0x20,
            0x105 => 0x76
          },
          %{}
        )

      result = Machine.run!(memory, %State{pc: 0x100}, 1)

      assert :binary.at(result.memory, 0x2000) == :binary.at(memory, 0x2000)
    end
  end

  # ══ Differential frames ══════════════════════════════════════════════════════

  describe "differential frames against Screen" do
    test "a loop reading LY records the same scanlines on both sides" do
      # The most direct probe there is: the program samples LY as fast as it can
      # and writes what it sees into WRAM. Any disagreement about when the line
      # advances -- one cycle of budget, one line of count -- lands in that trace.
      rom =
        ROM.build(
          [
            {:label, :main},
            {:ld, :hl, 0xC000},
            {:label, :loop},
            {:ldh, :a, {:high, 0x44}},
            {:ld, {:mem, :hl_inc}, :a},
            {:jr, {:label, :loop}}
          ],
          title: "LYSCAN"
        )

      equivalence!(rom, 2)
    end

    test "a HALT waiting on the vblank counts exactly one frame per frame" do
      # HALT, the vblank interrupt, the service, RETI, and a counter in WRAM: the
      # whole chain a game's main loop depends on. The counter is the assertion --
      # if the native side raised two vblanks in a frame, or none, it says so as a
      # number.
      rom =
        ROM.build(
          [
            {:label, :main},
            {:di},
            {:ld, :sp, 0xDFFF},
            {:xor, :a, :a},
            {:ld, {:mem, 0xC000}, :a},
            {:ldh, {:high, 0x0F}, :a},
            {:ld, :a, 0x01},
            {:ldh, {:high, 0xFF}, :a},
            {:ei},
            {:label, :loop},
            {:halt},
            {:jr, {:label, :loop}},
            {:label, :handler},
            {:push, :af},
            # The scanline the interrupt was serviced on. Without this the test is
            # blind to *when* the vblank rose: a flag raised at line 145 instead of
            # 144 still gets serviced once per frame, the handler still finishes
            # long before the frame ends, and the state at the frame boundary is
            # identical. Verified by mutation -- shifting the line by one leaves
            # every other assertion here green.
            {:ldh, :a, {:high, 0x44}},
            {:ld, {:mem, 0xC001}, :a},
            {:ld, :a, {:mem, 0xC000}},
            {:inc, :a},
            {:ld, {:mem, 0xC000}, :a},
            {:pop, :af},
            {:reti}
          ],
          title: "VBLANK",
          vblank: :handler
        )

      result = equivalence!(rom, 4)

      assert :binary.at(result.memory, 0xC000) == 4, "one vblank per frame, no more, no less"
      assert :binary.at(result.memory, 0xC001) == 144, "the vblank was serviced on the wrong line"
    end

    test "an armed timer overflows the same number of times on both sides" do
      # TAC 0x05: enabled, one increment every 16 T. Over a frame that is 4389
      # increments, so seventeen overflows, each one reloading from TMA and
      # requesting IF bit 2. The reload value is 0xF0 rather than zero so that a
      # side reloading with the wrong byte is visible in TIMA at the end.
      rom =
        ROM.build(
          [
            {:label, :main},
            {:di},
            {:xor, :a, :a},
            {:ldh, {:high, 0x05}, :a},
            {:ldh, {:high, 0x0F}, :a},
            {:ld, :a, 0xF0},
            {:ldh, {:high, 0x06}, :a},
            {:ld, :a, 0x05},
            {:ldh, {:high, 0x07}, :a},
            {:label, :loop},
            {:jr, {:label, :loop}}
          ],
          title: "TIMER"
        )

      result = equivalence!(rom, 1)

      assert band(:binary.at(result.memory, 0xFF0F), 0x04) != 0, "no timer interrupt requested"
    end

    test "the pad polled the way the hardware wants it agrees on both sides" do
      # Potion's `read_pad`: select a row, read it twice -- the lines are pull-up
      # resistors and the first read can lie on silicon -- invert, keep the low
      # nibble. The oracle composes the register on the write; so does the seam.
      rom =
        ROM.build(
          [
            {:label, :main},
            {:ld, :a, 0x20},
            {:ldh, {:high, 0x00}, :a},
            {:ldh, :a, {:high, 0x00}},
            {:ldh, :a, {:high, 0x00}},
            {:cpl},
            {:and, :a, 0x0F},
            {:ld, {:mem, 0xC000}, :a},
            {:ld, :a, 0x10},
            {:ldh, {:high, 0x00}, :a},
            {:ldh, :a, {:high, 0x00}},
            {:cpl},
            {:and, :a, 0x0F},
            {:ld, {:mem, 0xC001}, :a},
            {:label, :loop},
            {:jr, {:label, :loop}}
          ],
          title: "PAD"
        )

      result = equivalence!(rom, 1)

      assert :binary.at(result.memory, 0xC000) == 0x00, "no button is pressed in this stage"
      assert :binary.at(result.memory, 0xC001) == 0x00
    end
  end

  # ══ The crown ════════════════════════════════════════════════════════════════

  describe "games/hero.gb" do
    @tag timeout: 900_000
    test "the first Potion game runs ten frames identically on both sides" do
      # Everything at once: the init that spans two frames clearing VRAM, the
      # vblank handler entered through the vector, HALT as the only clock, the OAM
      # DMA out of HRAM, the pad read twice per row. If the two sides agree on the
      # CPU state and on every byte of VRAM, WRAM, OAM and I/O after ten frames,
      # the native core runs a real game.
      rom = Screen.load(Path.join([__DIR__, "..", "games", "hero.gb"]))

      result = equivalence!(rom, 10, Screen.boot_state(rom, true))

      # The kernel's own witnesses, named rather than counted: the frame flag is
      # consumed by the main loop, the pad cell is recomposed every frame, and
      # sprite 0 carries the hero's position -- 80 + 16, 72 + 8 with no key held.
      assert :binary.at(result.memory, 0xC0A0) == 0x00, "no key held"
      assert :binary.at(result.memory, 0xFE00) == 72 + 16, "sprite 0 Y"
      assert :binary.at(result.memory, 0xFE01) == 80 + 8, "sprite 0 X"
    end
  end

  # ══ The number that decides the C6 ═══════════════════════════════════════════

  describe "cost" do
    test "the generated code fits in the C6's instruction cache" do
      image = Machine.image(:binary.copy(<<0x00>>, 0x10000), %State{}, 1)

      # `table_base` opens the data section: everything before it is code.
      assert image.labels[:table_base] < 32 * 1024,
             "the code is #{image.labels[:table_base]} bytes -- the C6 cache is 32768"
    end

    @tag timeout: 900_000
    test "instructions retired per frame, running a real game" do
      # `-icount shift=0` is what makes the `instret` CSR exact. The average over
      # ten frames is dominated by hero's init -- clearing 8 KB of VRAM costs more
      # than any frame of play -- so the steady-state cost is read as a marginal
      # one: the difference between twenty frames and ten, over ten.
      rom = Screen.load(Path.join([__DIR__, "..", "games", "hero.gb"]))
      state = Screen.boot_state(rom, true)
      memory = memory(rom, seed())

      ten = Machine.run!(memory, state, 10, icount: true)
      twenty = Machine.run!(memory, state, 20, icount: true)

      steady = div(twenty.instret - ten.instret, 10)

      per_second = Float.round(steady * 60 / 1_000_000, 1)

      IO.puts("""

      hero.gb, native machine loop:
        ten frames      #{ten.instret} RV32 instructions, #{ten.cycles} T-cycles
        twenty frames   #{twenty.instret} RV32 instructions
        steady state    #{steady} RV32 instructions per frame
        that is         #{per_second} M instructions per second at 60 fps
      """)

      assert ten.status == :ok
      assert twenty.status == :ok
      assert steady > 0
    end
  end

  # ══ Equivalence, in one line ═════════════════════════════════════════════════

  # Runs `frames` frames of `rom` through `Atomboy.Screen` and through the
  # generated machine loop, and demands nothing tells them apart: the CPU state,
  # the ROM left untouched, and every byte of the compared regions. Returns the
  # native result so the caller can additionally name what it expects.
  defp equivalence!(rom, frames, state \\ nil) do
    state = state || Screen.boot_state(rom, true)
    ram = Map.merge(Screen.boot_ram(rom, true), seed())

    {expected, oracle_ram} = oracle(state, rom, ram, frames)
    result = Machine.run!(memory(rom, ram), state, frames)

    assert result.status == :ok,
           "the guest stopped on opcode #{inspect(result.opcode, base: :hex)}"

    # The budget is met or exceeded, never undershot: the last instruction of a
    # line may overshoot, and a line is never cut short. Anything outside that
    # window means a line was skipped or run twice.
    #
    # Note what this cannot see, and what nothing can: every SM83 instruction
    # costs a multiple of four T-cycles, so a per-line budget anywhere in 453..456
    # lets exactly the same instructions run and produces exactly the same totals.
    # Mutating 456 by one changes nothing observable; mutating it by four is caught
    # by seven of these tests.
    assert result.cycles >= frames * 154 * 456
    assert result.cycles < frames * 154 * (456 + 24)

    assert result.state == expected

    assert binary_part(result.memory, 0, 0x8000) == rom,
           "the guest wrote into the cartridge"

    divergences =
      for {from, to} <- @regions,
          address <- from..to,
          oracle_byte = CartLoop.peek(rom, oracle_ram, address),
          native_byte = :binary.at(result.memory, address),
          oracle_byte != native_byte,
          do: {address, oracle_byte, native_byte}

    assert divergences == [], """
    #{length(divergences)} bytes disagree, the first ten:
    #{divergences |> Enum.take(10) |> Enum.map_join("\n", fn {a, o, n} -> "  #{inspect(a, base: :hex)}: oracle #{o}, native #{n}" end)}
    """

    result
  end

  defp oracle(state, _rom, ram, 0), do: {state, ram}

  defp oracle(state, rom, ram, frames) do
    {_pixels, state, ram} = Screen.frame(state, rom, ram, false)
    oracle(state, rom, ram, frames - 1)
  end

  # ══ The shared boot state ════════════════════════════════════════════════════

  # The I/O registers the machine loop and the timer read, written out explicitly.
  #
  # This is what lets the two models start from the same bytes. `Atomboy.Timer`
  # reads an absent TAC as zero -- a timer at rest -- where the CPU reading the
  # same absent address gets 0xFF from the open bus, which is an *enabled* timer
  # at the slowest rate. One of the two is wrong about a register nobody wrote;
  # writing it removes the question. `Screen` has the same habit with LCDC, whose
  # default it spells 0x91 in `step_line/4`.
  defp seed do
    %{
      0xFF00 => 0xFF,
      0xFF04 => 0x00,
      0xFF05 => 0x00,
      0xFF06 => 0x00,
      0xFF07 => 0x00,
      0xFF0F => 0x00,
      0xFF40 => 0x91,
      0xFF41 => 0x00,
      0xFF44 => 0x00,
      0xFF45 => 0x00,
      0xFFFF => 0x00
    }
  end

  # The flat 64 KB the guest receives: the ROM below 0x8000, and above it exactly
  # what the oracle's map would read back -- 0xFF where nothing was written, which
  # is `CartLoop`'s open bus.
  defp memory(rom, ram) when is_binary(rom) do
    high = for address <- 0x8000..0xFFFF, into: <<>>, do: <<Map.get(ram, address, 0xFF)>>
    binary_part(rom, 0, 0x8000) <> high
  end

  # The same, for a hand-placed program rather than a cartridge: the low half is
  # 0xE3 -- an encoding the SM83 does not have -- so a run that leaves the
  # intended bytes stops and names the opcode instead of running through noise.
  defp memory(bytes, ram) when is_map(bytes) do
    low = for address <- 0..0x7FFF, into: <<>>, do: <<Map.get(bytes, address, 0xE3)>>
    memory(low, Map.merge(seed(), ram))
  end

  # A memory whose only instruction is `HALT`, with the given I/O registers on top
  # of the seed.
  #
  # A program that consumes a whole frame is not a detail of these tests, it is
  # what they rest on: with the 0xE3 filler and no instruction, the guest stops on
  # the first fetch, LY never advances and no vblank is ever requested -- which is
  # exactly the observation the screen-off test is looking for. The HALT makes the
  # frame really happen, and `status == :ok` is asserted alongside so that an
  # aborted run can never read as a quiet one. IE stays at zero in the seed, so
  # nothing wakes the processor.
  defp sleeper(registers) do
    memory(%{0x100 => 0x76}, registers)
  end
end
