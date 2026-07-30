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
  running timer. So the boot I/O state is written out explicitly, and both sides
  receive it: the oracle as map entries, the guest as bytes. It lives in
  `Atomboy.Native.Boot`, which is also where the reasons are written down; `seed/0`
  is just the local name for it.

  ## What is not compared, and why

    * **0x0000-0x7FFF** is compared to the ROM itself rather than to the oracle:
      the point is that the guest did not write there. A flat memory has no MBC
      to swallow a bank-select write, so a program writing to 0x2000 would rewrite
      its own code -- `Atomboy.Native.Bus` drops those writes before they land, and
      this is the assertion that says so.
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
  alias Atomboy.Native.Boot
  alias Atomboy.Native.Machine
  alias Atomboy.PPU
  alias Atomboy.Screen
  alias Potion.ROM

  @moduletag :qemu
  # One qemu launch, a 64 KB dump per run, and ten frames of a real game.
  @moduletag timeout: 600_000

  # hero.gb's tenth frame: a white screen with the hero's 8x8 square on it. Pinned
  # so that the pixel test cannot pass against a picture nobody recognises -- the
  # same guard `native_ppu_test` puts on dmg-acid2.
  @hero_crc 0x5AA2E5B7

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

    test "a register written through (HL) reaches the seam like any other" do
      # The hole this test was written to close. `LD (a16), A` is what an
      # assembler emits for `ld ($FF46), a`, and for a long while it was the only
      # store form the seam saw: a program that puts a register's address in HL
      # and writes through the pointer -- which is what a compiler does, and what
      # any loop over a table of registers does -- laid down a plain byte. No OAM
      # DMA, so no sprite anywhere; and a joypad selection stored raw, so every
      # button on the selected row read as held.
      #
      # Both are asked for here through `(HL)` and nothing else. Verified by
      # mutation: with the store forms routed one by one instead of through
      # `Atomboy.Native.Bus`, this test fails twice over -- OAM comes back empty
      # and the pad byte comes back as the 0x20 that was written rather than as
      # the matrix the hardware would show.
      rom =
        ROM.build(
          [
            {:label, :main},
            {:ld, :hl, 0xFF46},
            {:ld, :a, 0xC0},
            {:ld, {:mem, :hl}, :a},
            {:ld, :hl, 0xFF00},
            {:ld, :a, 0x20},
            {:ld, {:mem, :hl}, :a},
            {:ld, :a, {:mem, :hl}},
            {:ld, {:mem, 0xC0A0}, :a},
            {:label, :loop},
            {:jr, {:label, :loop}}
          ],
          title: "HLSEAM"
        )

      # The page the DMA is asked to copy: 0xC000-0xC09F, marked so a byte landing
      # at the wrong offset is visible. The pad's answer goes just past it.
      page = for offset <- 0..0x9F, into: %{}, do: {0xC000 + offset, offset}

      result = equivalence!(rom, 1, nil, page)

      copied = for offset <- 0..0x9F, do: :binary.at(result.memory, 0xFE00 + offset)
      assert copied == Enum.to_list(0..0x9F), "the DMA did not happen through (HL)"

      assert :binary.at(result.memory, 0xC0A0) == 0xEF,
             "the pad read back the byte that was written, not the matrix"
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

  # ══ Chaining one run onto another ════════════════════════════════════════════

  describe "the timer's phase across runs" do
    test "two runs of one frame equal one run of two, timer included" do
      # A frame is 70,224 T-cycles and a TIMA period at TAC 0x04 is 1024: the
      # frame leaves 592 cycles of phase that no register shows. Two frames run as
      # one image carry it across the boundary, because the sub-counter lives in
      # the image. Two frames run as two images used to drop it, and the second
      # frame then counted 68 increments where it owed 69 -- one TIMA short,
      # for ever, at every boundary a caller made.
      #
      # So the protocol now carries the phase both ways, and this is the test that
      # says what it buys: the same two frames, split, come out byte-identical.
      # The `refute` at the end is what makes that mean something -- without the
      # phase the split run really does differ.
      rom =
        ROM.build(
          [
            {:label, :main},
            {:di},
            {:xor, :a, :a},
            {:ldh, {:high, 0x05}, :a},
            {:ldh, {:high, 0x06}, :a},
            {:ldh, {:high, 0x0F}, :a},
            {:ld, :a, 0x04},
            {:ldh, {:high, 0x07}, :a},
            {:label, :loop},
            {:jr, {:label, :loop}}
          ],
          title: "PHASE"
        )

      # Two frames in one image, checked against the oracle on the way past: the
      # Elixir timer keeps its own sub-counter in the memory map, so it chains
      # across frames without being asked and is the reference for what chaining
      # should produce.
      whole = equivalence!(rom, 2)

      refute whole.timer == {0, 0}, "the phase is zero, so this test proves nothing"

      first =
        Machine.run!(memory(rom, Map.merge(Screen.boot_ram(rom, true), seed())), state(rom), 1)

      chained = Machine.run!(first.memory, first.state, 1, timer: first.timer)
      restarted = Machine.run!(first.memory, first.state, 1)

      assert chained.state == whole.state
      assert chained.timer == whole.timer
      assert chained.memory == whole.memory, "a chained run diverged from an uninterrupted one"

      refute restarted.memory == whole.memory,
             "dropping the phase changed nothing -- the test cannot see the bug it guards"

      assert :binary.at(restarted.memory, 0xFF05) + 1 == :binary.at(whole.memory, 0xFF05),
             "the frame that lost its phase should owe exactly one TIMA increment"
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

  # ══ The pixels ═══════════════════════════════════════════════════════════════

  describe "pixels" do
    @tag timeout: 900_000
    test "hero.gb draws the same frame on both cores, pixel for pixel" do
      # The one that matters. Everything the memory comparison proved is a
      # precondition; this is the output a player would see, 23040 bytes of it,
      # produced by generated RISC-V calling a generated renderer inside a
      # generated machine loop.
      rom = hero()
      state = Screen.boot_state(rom, true)
      ram = Map.merge(Screen.boot_ram(rom, true), seed())

      # The oracle renders only its last frame, as `Screen.run/3` does; the guest
      # renders all ten, as a console would. They agree because the renderer's
      # state is per-frame -- the window counter resets, the destination rewinds --
      # and because it writes nothing the CPU can reach. The next test is the one
      # that holds that second claim down.
      expected = oracle_pixels(state, rom, ram, 10)
      result = Machine.run!(memory(rom, ram), state, 10, render: true)

      assert result.status == :ok
      assert byte_size(result.pixels) == Machine.frame_bytes()
      assert divergent_pixels(expected, result.pixels) == []
      assert result.pixels == expected

      # A frame nobody recognises is not a passing test. The CRC pins the image
      # itself, the way `native_ppu_test` pins dmg-acid2's.
      assert :erlang.crc32(result.pixels) == @hero_crc,
             "the frame changed: crc #{inspect(:erlang.crc32(result.pixels), base: :hex)}"

      # And the image, described rather than hashed: hero draws one solid 8x16
      # tile-half at the position the actor holds, on an empty background. Sprite 0
      # sits at OAM (88, 88), which is screen (80, 72) once the hardware's offsets
      # of 8 and 16 come off.
      dark =
        for {shade, i} <- Enum.with_index(:binary.bin_to_list(result.pixels)),
            shade == 3,
            do: {rem(i, 160), div(i, 160)}

      assert length(dark) == 64, "the hero is 8 by 8"
      assert Enum.min_max(Enum.map(dark, &elem(&1, 0))) == {80, 87}, "the hero's columns"
      assert Enum.min_max(Enum.map(dark, &elem(&1, 1))) == {72, 79}, "the hero's rows"

      assert result.pixels |> :binary.bin_to_list() |> Enum.uniq() |> Enum.sort() == [0, 3],
             "hero's palette only ever produces the lightest and the darkest shade"
    end

    test "a raster effect and a window pin when the registers are read" do
      # hero.gb cannot carry this test, and it took a mutation to notice: its
      # picture is static -- SCX and SCY never move, there is no window -- so
      # rendering a line before its CPU slice instead of after, or restarting the
      # window's counter every line, produces exactly the same ten frames. Both
      # mutations pass every other assertion in this file.
      #
      # So: a program that writes SCX = LY on a loop, which makes the scroll a
      # function of the scanline and nothing else, and a window switched on from
      # line 60 with its left edge at x 80. The background occupies the left half,
      # the window the right, and the tile is a diagonal -- a pattern with no
      # symmetry in either axis, so a shift of one line or one pixel shows.
      #
      # What each half proves: the left, that the renderer reads SCX as the CPU left
      # it at the *end* of the line it is drawing, which is where
      # `Atomboy.Screen.frame/4` renders; the right, that the window's internal
      # counter is carried from line to line and reset per frame. WY is 60 rather
      # than 64 on purpose -- 64 is a multiple of the tile height, which would make
      # the window's rows coincide with the background's and hide a frozen counter.
      rom =
        ROM.build(
          [
            {:label, :main},
            {:label, :loop},
            {:ldh, :a, {:high, 0x44}},
            {:ldh, {:high, 0x43}, :a},
            {:jr, {:label, :loop}}
          ],
          title: "RASTER"
        )

      extra = Map.merge(diagonal_tile(), %{0xFF40 => 0xB1, 0xFF4A => 60, 0xFF4B => 87})
      state = Screen.boot_state(rom, true)
      ram = Screen.boot_ram(rom, true) |> Map.merge(seed()) |> Map.merge(extra)

      result = pixel_equivalence!(rom, 2, extra)

      # Agreement only means something if the two plausible bugs would have
      # produced a *different* picture on this program. Both are rendered here on
      # the Elixir side, from the same ROM and the same VRAM, and the frame the
      # guest sent back has to differ from each of them. Without these two
      # assertions the test could not tell a correct integration from either
      # mutation -- checked by making both mutations and watching this fail.
      assert result.pixels != pixels_rendered_early(state, rom, ram, 2),
             "drawing a line before its CPU slice would give this same frame"

      assert result.pixels != pixels_window_frozen(state, rom, ram, 2),
             "restarting the window's counter every line would give this same frame"

      # And the picture is not a flat field, which would make any comparison
      # vacuous: both shades appear, and consecutive rows differ.
      assert result.pixels |> :binary.bin_to_list() |> Enum.uniq() |> Enum.sort() == [0, 3]
      assert frame_row(result.pixels, 100) != frame_row(result.pixels, 101)
    end

    @tag timeout: 900_000
    test "rendering leaves the CPU and its memory untouched" do
      # The renderer reads the 64 KB and never writes it, and it saves every
      # register the interpreter carries. Both claims are what let the call sit
      # between two scanlines; this is the test that would notice if either stopped
      # being true -- a clobbered HL or a stray byte in VRAM would show up as a
      # difference between the two regimes, on a real game, ten frames deep.
      rom = hero()
      state = Screen.boot_state(rom, true)
      memory = memory(rom, seed())

      without = Machine.run!(memory, state, 10)
      with_pixels = Machine.run!(memory, state, 10, render: true)

      assert with_pixels.state == without.state
      assert with_pixels.memory == without.memory
      assert with_pixels.cycles == without.cycles
      assert without.pixels == nil, "a run with no renderer must send no pixels"
    end

    test "a rendered frame with the screen off is uniformly shade zero" do
      # `Atomboy.PPU` returns shade 0 across the line when LCDC bit 7 is down --
      # not BGP's colour 0, shade 0. Reached here through the integration rather
      # than by calling the renderer directly, so the LY the machine loop passes and
      # the buffer it points at are part of what is checked.
      result =
        Machine.run!(sleeper(%{0xFF40 => 0x00}), %State{pc: 0x100}, 1, render: true)

      assert result.status == :ok
      assert result.pixels == :binary.copy(<<0>>, Machine.frame_bytes())
    end
  end

  # ══ The numbers that decide the C6 ═══════════════════════════════════════════

  describe "cost" do
    test "the generated code fits in the C6's instruction cache, renderer included" do
      memory = :binary.copy(<<0x00>>, 0x10000)
      without = Machine.image(memory, %State{}, 1)
      with_ppu = Machine.image(memory, %State{}, 1, render: true)

      # `table_base` opens the data section: everything before it is code.
      cpu = without.labels[:table_base]
      whole = with_ppu.labels[:table_base]

      assert whole < 32 * 1024,
             "CPU, machine loop and PPU come to #{whole} bytes -- the C6 cache is 32768"

      assert whole > cpu, "the renderer must actually be in the image"
    end

    @tag timeout: 1_800_000
    test "instructions retired per frame, with and without the renderer" do
      # `-icount shift=0` is what makes the `instret` CSR exact. The average over
      # ten frames is dominated by hero's init -- clearing 8 KB of VRAM costs more
      # than any frame of play -- so the steady-state cost is read as a marginal
      # one: the difference between twenty frames and ten, over ten.
      rom = hero()
      state = Screen.boot_state(rom, true)
      memory = memory(rom, seed())

      %{steady: bare} = marginal(memory, state, render: false)
      %{steady: drawn, ten: ten} = marginal(memory, state, render: true)

      code = Machine.image(memory, state, 1, render: true).labels[:table_base]

      # hero.gb spends its frame halted, waiting for VBlank, so it fetches a few
      # hundred opcodes and spends the rest of the frame in the halt path --
      # which is dearer per T-cycle than a fetch, hence a total *above* the
      # all-NOP one below. Its number is therefore nearly blind to what a fetch
      # costs, and that is what the second measurement is for: an all-NOP memory
      # where every one of the 17556 opcodes a frame allows is a fetch and
      # nothing else. Any change to the fetch path shows up there or nowhere.
      %{steady: fetching} = marginal(:binary.copy(<<0x00>>, 0x10000), %State{pc: 0x0100}, [])
      per_opcode = Float.round(fetching / div(154 * 456, 4), 2)

      IO.puts("""

      hero.gb, native machine loop, steady state per frame:
        CPU only        #{bare} RV32 instructions  (#{rate(bare)} M/s at 60 fps)
        with the PPU    #{drawn} RV32 instructions  (#{rate(drawn)} M/s at 60 fps)
        the renderer    #{drawn - bare} of those
        ten frames      #{ten.instret} instructions, #{ten.cycles} T-cycles
        code            #{code} bytes of the C6's 32768 byte cache

      all-NOP memory, the fetch-bound extreme:
        #{fetching} RV32 instructions per frame, #{per_opcode} per opcode
      """)

      assert bare > 0 and drawn > bare

      # The guard the page table earned. Fetching a NOP and dispatching it cost
      # 12.4 RV32 instructions when memory was flat and 16.4 once every read
      # went through a page table -- the whole price of a cartridge, paid here
      # and nowhere else. Twenty leaves room to breathe; it does not leave room
      # for a second indirection to slip in unmeasured.
      assert per_opcode < 20,
             "the fetch path costs #{per_opcode} RV32 instructions per opcode -- it was 16.37"
    end
  end

  # ══ Equivalence, in one line ═════════════════════════════════════════════════

  # Runs `frames` frames of `rom` through `Atomboy.Screen` and through the
  # generated machine loop, and demands nothing tells them apart: the CPU state,
  # the ROM left untouched, and every byte of the compared regions. Returns the
  # native result so the caller can additionally name what it expects.
  defp equivalence!(rom, frames, state \\ nil, extra \\ %{}) do
    state = state || Screen.boot_state(rom, true)
    ram = Screen.boot_ram(rom, true) |> Map.merge(seed()) |> Map.merge(extra)

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

  # `Screen.run/3`'s composition: N frames, rendered on the last one only.
  defp oracle_pixels(state, rom, ram, frames) do
    {pixels, _state, _ram} =
      Enum.reduce(1..frames, {<<>>, state, ram}, fn index, {_pixels, state, ram} ->
        Screen.frame(state, rom, ram, index == frames)
      end)

    pixels
  end

  # The same equivalence as `equivalence!/3`, plus the pixels. `extra` seeds I/O
  # registers and VRAM on both sides at once, which is how a test gets a picture
  # without writing an init routine in SM83.
  defp pixel_equivalence!(rom, frames, extra) do
    state = Screen.boot_state(rom, true)
    ram = Screen.boot_ram(rom, true) |> Map.merge(seed()) |> Map.merge(extra)

    {expected_state, oracle_ram} = oracle(state, rom, ram, frames)
    expected = oracle_pixels(state, rom, ram, frames)
    result = Machine.run!(memory(rom, ram), state, frames, render: true)

    assert result.status == :ok
    assert result.state == expected_state

    divergences = divergent_pixels(expected, result.pixels)

    assert divergences == [], """
    #{length(divergences)} pixels disagree, the first ten:
    #{divergences |> Enum.take(10) |> Enum.map_join("\n", fn {x, y, want, got} -> "  (#{x}, #{y}): oracle shade #{want}, native #{got}" end)}
    """

    # The memory has to agree too, or a pixel agreement could be two renderers
    # drawing the same wrong VRAM.
    memory_divergences =
      for {from, to} <- @regions,
          address <- from..to,
          oracle_byte = CartLoop.peek(rom, oracle_ram, address),
          native_byte = :binary.at(result.memory, address),
          oracle_byte != native_byte,
          do: {address, oracle_byte, native_byte}

    assert memory_divergences == []

    result
  end

  # One scanline out of a frame, as a list of shades.
  defp frame_row(pixels, y) do
    pixels |> binary_part(y * 160, 160) |> :binary.bin_to_list()
  end

  # The two frames the two plausible integration bugs would produce. Both are built
  # out of the same pieces `Screen.frame/4` composes -- `step_line/4` is public --
  # so neither reimplements anything that could drift from the oracle.
  #
  # Each line drawn *before* its CPU slice: the renderer then sees the scroll
  # registers the previous line left behind, which is the whole question of where
  # the call belongs in the cadence.
  defp pixels_rendered_early(state, rom, ram, frames) do
    last_frame(state, rom, ram, frames, fn state, ram, ly, window ->
      {line, window} = PPU.render_line(ram, ly, window)
      {state, ram} = Screen.step_line(state, rom, ram, ly)
      {line, state, ram, window}
    end)
  end

  # The window's counter handed over as zero on every line instead of carried: the
  # window would redraw its first row all the way down.
  defp pixels_window_frozen(state, rom, ram, frames) do
    last_frame(state, rom, ram, frames, fn state, ram, ly, window ->
      {state, ram} = Screen.step_line(state, rom, ram, ly)
      {line, _} = PPU.render_line(ram, ly, 0)
      {line, state, ram, window}
    end)
  end

  # `Screen.frame/4`'s loop with the visible line's step handed to `draw`, which
  # decides the order and what the renderer is told. Only the last frame is drawn,
  # as in `Screen.run/3`.
  defp last_frame(state, rom, ram, frames, draw) do
    {pixels, _state, _ram} =
      Enum.reduce(1..frames, {<<>>, state, ram}, fn index, {_pixels, state, ram} ->
        {pixels, state, ram, _window} =
          Enum.reduce(0..(Machine.lines() - 1), {<<>>, state, ram, 0}, fn ly, acc ->
            {pixels, state, ram, window} = acc

            if index == frames and ly < Machine.visible() do
              {line, state, ram, window} = draw.(state, ram, ly, window)
              {pixels <> line, state, ram, window}
            else
              {state, ram} = Screen.step_line(state, rom, ram, ly)
              {pixels, state, ram, window}
            end
          end)

        {pixels, state, ram}
      end)

    pixels
  end

  # Tile 0 as a diagonal, and a tilemap that uses it everywhere. A diagonal has no
  # symmetry in either axis, so a picture shifted by one line or one column cannot
  # look like the right one. Seeded straight into VRAM on both sides.
  defp diagonal_tile do
    tile = for row <- 0..7, into: %{}, do: {0x8000 + row * 2, 0x80 >>> row}
    high = for row <- 0..7, into: %{}, do: {0x8001 + row * 2, 0x80 >>> row}
    map = for cell <- 0..0x3FF, into: %{}, do: {0x9800 + cell, 0x00}

    tile |> Map.merge(high) |> Map.merge(map)
  end

  # Where two frames disagree, as {x, y, expected, actual} -- a pixel's coordinates
  # say far more than its offset when the picture is wrong.
  defp divergent_pixels(expected, actual) do
    for i <- 0..(byte_size(expected) - 1),
        want = :binary.at(expected, i),
        got = :binary.at(actual, i),
        want != got,
        do: {rem(i, 160), div(i, 160), want, got}
  end

  # The marginal cost of one frame: twenty frames minus ten, over ten. The
  # difference sheds hero's init, which no steady-state number should carry.
  defp marginal(memory, state, opts) do
    ten = Machine.run!(memory, state, 10, Keyword.put(opts, :icount, true))
    twenty = Machine.run!(memory, state, 20, Keyword.put(opts, :icount, true))

    %{ten: ten, twenty: twenty, steady: div(twenty.instret - ten.instret, 10)}
  end

  defp rate(per_frame), do: Float.round(per_frame * 60 / 1_000_000, 1)

  defp hero, do: Screen.load(Path.join([__DIR__, "..", "games", "hero.gb"]))

  defp state(rom), do: Screen.boot_state(rom, true)

  # ══ The shared boot state ════════════════════════════════════════════════════

  # The I/O registers the machine loop, the timer and the renderer read, written
  # out explicitly -- `Atomboy.Native.Boot` says which and why. It used to be a
  # literal here and another one inside `Atomboy.Native.PPUBench`, and a palette
  # spelled twice is a palette that will eventually be spelled two ways.
  defp seed, do: Boot.io_state()

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
