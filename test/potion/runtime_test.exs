defmodule Potion.RuntimeTest do
  @moduledoc """
  The v0 kernel, checked where it counts: in the emulator, frames unrolled.

  No test reads back the bytes the kernel emits — an assembler that reads itself
  back proves nothing beyond its own consistency, and `Potion.AssemblerTest`
  already takes care of that across all 500 instructions. Here, the only question
  is: does the ROM run, and does it do what a game expects of a runtime? The
  screen lights up, the OAM gets published, a sprite appears in the right place,
  the pad moves it, and the actor runs exactly once per frame.

  The test actor fits entirely inside `actor/0`: it counts the frames, places
  itself at the centre, moves right when asked to, and publishes its OAM entry
  into the mirror. It is the game the v0 DSL will have to know how to write.

  ## The startup timetable

  The init is not instantaneous: waiting for the vblank takes up to one frame,
  clearing the VRAM takes another. The screen therefore lights up during the
  third frame, and the actor runs for the first time at its vblank. The sprite,
  published by the next frame's DMA, becomes visible at the fifth. The tests
  leave some slack, and the ones that count the actor's turns do so as a
  difference over a window — not as an absolute value since boot.
  """

  use ExUnit.Case, async: true

  alias Atomboy.Joypad
  alias Atomboy.Screen
  alias Potion.Runtime
  alias Potion.ROM

  # The test actor's state, inside the page the kernel leaves to it.
  @counter 0xC100
  @sprite_x 0xC101
  @installed 0xC102
  @sprite_y 0xC103

  # The sprite's starting point, in screen coordinates — the kernel knows only
  # the OAM, where the same position is written offset by 16 in Y and 8 in X.
  @start_x 80
  @start_y 72

  describe "the program" do
    test "the actor is framed by the kernel, and named by it" do
      addresses = Potion.Assembler.addresses(Runtime.program(actor()), origin: 0x0150)

      # The cartridge's entry point lands on the init.
      assert addresses.init == 0x0150
      # The two labels the rest of the world knows about. Slots are numbered,
      # because the kernel schedules positions -- it is the language above that
      # knows an actor is called `:ball`.
      assert Map.has_key?(addresses, :vblank)
      assert Map.has_key?(addresses, :actor_0)
      # The actors come last: the whole kernel precedes them.
      assert addresses.actor_0 > addresses.main_loop
      # And the test actor's state fits in the page the kernel promises.
      assert @counter == Runtime.actor_state()
    end

    test "several actors each get a slot, called in declaration order" do
      first = [{:ld, :a, 1}, {:ld, {:mem, 0xC1F0}, :a}, {:ret}]
      second = [{:ld, :a, 2}, {:ld, {:mem, 0xC1F1}, :a}, {:ret}]

      program = Runtime.program([first, second])
      addresses = Potion.Assembler.addresses(program, origin: 0x0150)

      assert addresses.actor_0 < addresses.actor_1

      calls =
        program
        |> Enum.drop_while(&(&1 != {:label, :main_loop}))
        |> Enum.filter(&match?({:call, _}, &1))

      # The music player is called between the pad and the actors: a tune the
      # game started last frame has already advanced by the time an actor looks
      # at anything.
      assert calls == [
               {:call, {:label, :read_pad}},
               {:call, {:label, :play_music}},
               {:call, {:label, :actor_0}},
               {:call, {:label, :actor_1}}
             ]
    end

    test "a single fragment is still a whole game" do
      # The hand-written actors predate the scheduler; passing one on its own
      # must keep meaning what it meant.
      addresses = Potion.Assembler.addresses(Runtime.program(actor()), origin: 0x0150)

      assert Map.has_key?(addresses, :actor_0)
      refute Map.has_key?(addresses, :actor_1)
    end

    test "an actor without a RET is refused at assembly, not at run time" do
      error =
        assert_raise ArgumentError, fn ->
          Runtime.program([{:ld, :a, 0x01}, {:ld, {:mem, 0xC000}, :a}])
        end

      assert error.message =~ "does not end with a RET"
    end

    test "the DMA routine is the hardware's own, assembled at its address" do
      # LD A, 0xC0 / LDH (0x46), A / LD A, 40 / DEC A / JR NZ, -3 / RET —
      # the canonical routine, ten bytes, written by the assembler and not by
      # hand.
      assert Runtime.dma_bytes() == <<0x3E, 0xC0, 0xE0, 0x46, 0x3E, 0x28, 0x3D, 0x20, 0xFD, 0xC9>>
    end
  end

  describe "the init" do
    test "the screen lights up, the palettes and the interrupt are set" do
      {_pixels, _state, ram} = run_frames(6)

      assert Map.get(ram, 0xFF40) == 0x93
      assert Map.get(ram, 0xFFFF) == 0x01
      assert Map.get(ram, 0xFF47) == 0xE4
      assert Map.get(ram, 0xFF48) == 0xE4
      # The background is recentred: a forgotten SCX would shift the whole map.
      assert Map.get(ram, 0xFF42) == 0x00
      assert Map.get(ram, 0xFF43) == 0x00
    end

    test "the VRAM is cleared, tile 0 solid, the background map empty" do
      {_pixels, _state, ram} = run_frames(6)

      # The sixteen bytes of tile 0: the solid square.
      assert for(i <- 0..15, do: Map.get(ram, 0x8000 + i)) == List.duplicate(0xFF, 16)
      # Tile 1 stayed the one the clearing left behind — it is the one the
      # background map points at, and that is what makes the sprite visible.
      assert for(i <- 0..15, do: Map.get(ram, 0x8010 + i)) == List.duplicate(0x00, 16)
      # The background map, from one end to the other.
      assert Map.get(ram, 0x9800) == 0x01
      assert Map.get(ram, 0x9BFF) == 0x01
      # And the end of the VRAM, which nothing has written since.
      assert Map.get(ram, 0x9FFF) == 0x00
    end

    test "the DMA routine really was copied into HRAM" do
      {_pixels, _state, ram} = run_frames(6)

      copied =
        for i <- 0..(byte_size(Runtime.dma_bytes()) - 1),
            into: <<>>,
            do: <<Map.get(ram, 0xFF80 + i)>>

      assert copied == Runtime.dma_bytes()
    end
  end

  describe "the DMA" do
    test "the real OAM reflects the mirror after a vblank" do
      {_pixels, _state, ram} = run_frames(6)

      mirror = for i <- 0..3, do: Map.get(ram, Runtime.oam_mirror() + i)

      assert mirror == [@start_y + 16, @start_x + 8, 0x00, 0x00]
      assert for(i <- 0..3, do: Map.get(ram, 0xFE00 + i)) == mirror
    end

    test "the other 39 entries get published too, and off screen" do
      {_pixels, _state, ram} = run_frames(6)

      # The actor only wrote entry 0; the rest of the mirror is the zero the
      # init laid down, and a Y of zero places the sprite at -16 — invisible.
      # The DMA copies all 160 bytes, not just the ones that changed.
      assert for(i <- 4..159, do: Map.get(ram, 0xFE00 + i)) == List.duplicate(0x00, 156)
    end
  end

  describe "the screen" do
    test "the sprite is an eight-by-eight square, in its place, on a white background" do
      {pixels, _state, _ram} = run_frames(6, render: true)

      assert byte_size(pixels) == 160 * 144

      # The box of non-white pixels is exactly the sprite's own.
      expected =
        for y <- @start_y..(@start_y + 7),
            x <- @start_x..(@start_x + 7),
            into: MapSet.new() do
          {x, y}
        end

      assert non_white(pixels) == expected

      # And the shade is the one colour 3 gets through OBP0: the darkest.
      assert :binary.at(pixels, @start_y * 160 + @start_x) == 3
    end
  end

  describe "the pad" do
    test "Right held moves the sprite forward, released stops it" do
      {_pixels, state, ram} = run_frames(5)

      assert Map.get(ram, @sprite_x) == @start_x

      # Right alone: the rows are active at zero on the hardware side, and it is
      # Joypad.set that speaks that language.
      {state, ram} = frames(state, Joypad.set(ram, 0x0F - 0x01, 0x0F), 4)

      assert Map.get(ram, @sprite_x) == @start_x + 4
      # The OAM follows — one frame behind, the DMA publishing what the actor
      # wrote at the previous vblank.
      assert Map.get(ram, 0xFE01) == @start_x + 3 + 8

      # Released: the position freezes.
      {_state, ram} = frames(state, Joypad.set(ram, 0x0F, 0x0F), 4)

      assert Map.get(ram, @sprite_x) == @start_x + 4
      assert Map.get(ram, 0xFE01) == @start_x + 4 + 8
    end

    test "the state byte is the right way round: d-pad low, buttons high" do
      {_pixels, state, ram} = run_frames(5)

      assert Map.get(ram, Runtime.pad()) == 0x00

      # Start is bit 3 of the buttons row, hence bit 7 of the recomposed byte.
      {state, ram} = frames(state, Joypad.set(ram, 0x0F, 0x0F - 0x08), 2)
      assert Map.get(ram, Runtime.pad()) == 0x80

      # Up and A together: one key per row, two nibbles.
      {state, ram} = frames(state, Joypad.set(ram, 0x0F - 0x04, 0x0F - 0x01), 2)
      assert Map.get(ram, Runtime.pad()) == 0x14

      {_state, ram} = frames(state, Joypad.set(ram, 0x0F, 0x0F), 2)
      assert Map.get(ram, Runtime.pad()) == 0x00
      # The kernel puts both rows back down: the register reads all released.
      assert Map.get(ram, 0xFF00) == 0xFF
    end
  end

  describe "the heartbeat" do
    test "the actor runs exactly once per frame" do
      {_pixels, state, ram} = run_frames(5)

      before = Map.get(ram, @counter)
      {_state, ram} = frames(state, ram, 7)

      assert Map.get(ram, @counter) == before + 7
    end

    test "the flag is raised at the vblank and the loop consumes it" do
      {_pixels, state, ram} = run_frames(5)

      assert Map.get(ram, Runtime.frame_flag()) == 0x00
      counter = Map.get(ram, @counter)

      # One frame unrolled scanline by scanline, to catch the kernel at work.
      # By line 144 the interrupt has fired, the handler has raised the flag and
      # started the DMA — but the main loop, still inside the RETI, has not
      # consumed it.
      {state, ram} =
        Enum.reduce(0..144, {state, ram}, fn ly, {state, ram} ->
          Screen.step_line(state, rom(), ram, ly)
        end)

      assert Map.get(ram, Runtime.frame_flag()) == 0x01
      assert Map.get(ram, @counter) == counter

      # The rest of the vblank: the loop wakes up, consumes the flag and calls
      # the actor — once.
      {_state, ram} =
        Enum.reduce(145..153, {state, ram}, fn ly, {state, ram} ->
          Screen.step_line(state, rom(), ram, ly)
        end)

      assert Map.get(ram, Runtime.frame_flag()) == 0x00
      assert Map.get(ram, @counter) == counter + 1
    end

    test "the processor sleeps between two frames instead of burning the loop" do
      {_pixels, state, ram} = run_frames(6)

      # One more frame necessarily stops inside the HALT: the main loop only
      # lasts a few hundred cycles, while the frame counts 70,000. PC is
      # therefore just after the HALT, and the halted state is that of a
      # processor waiting for the vblank.
      {_pixels, state, _ram} = Screen.frame(state, rom(), ram, false)

      assert state.halted
      assert state.ime == 1
    end
  end

  # ══ The harness ══════════════════════════════════════════════════════════════

  # The ROM of the kernel and the test actor.
  defp rom, do: ROM.build(Runtime.program(actor()), vblank: :vblank, title: "KERNEL")

  # `count` frames since boot; the last one rendered if asked for.
  defp run_frames(count, opts \\ []) do
    rom = rom()
    render? = Keyword.get(opts, :render, false)

    Enum.reduce(1..count, {<<>>, Screen.boot_state(rom), Screen.boot_ram(rom)}, fn n,
                                                                                   {_p, state,
                                                                                    ram} ->
      Screen.frame(state, rom, ram, render? and n == count)
    end)
  end

  # Further frames from a state in flight. The map passed in is the one the
  # outside world may just have touched — the keys, here.
  defp frames(state, ram, count) do
    rom = rom()

    Enum.reduce(1..count, {state, ram}, fn _n, {state, ram} ->
      {_pixels, state, ram} = Screen.frame(state, rom, ram, false)
      {state, ram}
    end)
  end

  defp non_white(pixels) do
    for i <- 0..(byte_size(pixels) - 1),
        :binary.at(pixels, i) != 0,
        into: MapSet.new(),
        do: {rem(i, 160), div(i, 160)}
  end

  # ── The test actor ──────────────────────────────────────────────────────────

  # A thirty-instruction game: count the frames, place itself on the first turn,
  # move right while the key is held, publish its sprite into the mirror. It fits
  # inside the 0xC100 page the kernel leaves to it — and counts on the zero the
  # init laid there to know that it is not installed yet.
  defp actor do
    oam = Runtime.oam_mirror()

    [
      {:ld, :a, {:mem, @counter}},
      {:inc, :a},
      {:ld, {:mem, @counter}, :a},
      {:ld, :a, {:mem, @installed}},
      {:and, :a, :a},
      {:jr, :nz, {:label, :actor_update}},
      {:ld, :a, 0x01},
      {:ld, {:mem, @installed}, :a},
      {:ld, :a, @start_x},
      {:ld, {:mem, @sprite_x}, :a},
      {:ld, :a, @start_y},
      {:ld, {:mem, @sprite_y}, :a},
      {:label, :actor_update},
      {:ld, :a, {:mem, Runtime.pad()}},
      {:bit, 0, :a},
      {:jr, :z, {:label, :actor_publish}},
      {:ld, :a, {:mem, @sprite_x}},
      {:inc, :a},
      {:ld, {:mem, @sprite_x}, :a},
      # Entry 0 of the OAM mirror: the hardware offset is the actor's business,
      # the kernel knows nothing but OAM bytes.
      {:label, :actor_publish},
      {:ld, :a, {:mem, @sprite_y}},
      {:add, :a, 16},
      {:ld, {:mem, oam}, :a},
      {:ld, :a, {:mem, @sprite_x}},
      {:add, :a, 8},
      {:ld, {:mem, oam + 1}, :a},
      {:xor, :a, :a},
      {:ld, {:mem, oam + 2}, :a},
      {:ld, {:mem, oam + 3}, :a},
      {:ret}
    ]
  end
end
