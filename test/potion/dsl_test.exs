defmodule Potion.DSLTest do
  @moduledoc """
  The language, checked at both ends: in the emulator, and in `mix compile`.

  A DSL that compiles down to hardware has two ways of lying. The first is to
  emit bytes that do not do what the game says: the only judge of that is the
  console, so the games in this file are *played* — booted in `Atomboy.Screen`,
  frames unrolled, pad simulated, pixels read back. The second is to accept a
  sentence it cannot translate, and translate it anyway, or halfway: the only
  judge of that is the compiler, so the refusals are tested by really compiling
  modules — `Code.compile_string`, not a direct call into the compiler — because
  that is where the programmer will meet them.

  The `Hero` game is word for word the one in `Potion`'s moduledoc. That is
  deliberate: the language's showcase is also its main test, and so it cannot
  rot.

  The startup timetable is the kernel's (see `Potion.RuntimeTest`): the init
  takes three frames, the actor runs for the first time at the fourth one's
  vblank, and the DMA publishes its OAM at the next. We unroll six frames before
  looking at the state, seven before looking at the screen.

  That was two frames until the wave channel's table joined the init. The
  timetable is not a promise the kernel makes — it is however long the init
  happens to be, measured between the vblank it waits for and the one the first
  `HALT` catches — so a test that counts frames is counting that, and adding
  work to the init moves it. Which is worth knowing before the numbers below
  look arbitrary.
  """

  use ExUnit.Case, async: true

  alias Atomboy.Joypad
  alias Atomboy.Screen
  alias Potion.Assembler

  doctest Potion.Compiler

  # The joypad rows, as `Atomboy.Joypad.set/3` wants them: one nibble per row,
  # at 1 = released. The hardware is active at zero, and it is the kernel that
  # puts the keys the right way round in its pad cell.
  @released 0x0F
  @right 0x0F - 0x01
  @left 0x0F - 0x02
  @up 0x0F - 0x04
  @down 0x0F - 0x08
  @start_key 0x0F - 0x08
  @a_key 0x0F - 0x01

  @start_x 80
  @start_y 72

  # ── The game of the fixed surface ───────────────────────────────────────────

  defmodule Hero do
    @moduledoc false
    use Potion

    defactor :hero do
      variables x: 80, y: 72

      every_frame do
        if pressed?(:right), do: x = x + 1
        if pressed?(:left), do: x = x - 1
        if pressed?(:up), do: y = y - 1
        if pressed?(:down), do: y = y + 1
        sprite(0, x: x, y: y, tile: 0)
      end
    end
  end

  # A second game, for the forms the hero does not exercise: a bare assignment, a
  # literal and a variable mixed inside one `sprite`, an OAM entry other than the
  # first, and an `if` block with several statements.
  defmodule Mixed do
    @moduledoc false
    use Potion

    defactor :mixed do
      variables width: 10, height: 20

      every_frame do
        width = 5

        if pressed?(:a) do
          width = width + 1
          height = height + 2
        end

        sprite(1, x: width, y: 40, tile: 3)
        sprite(2, x: 100, y: height, tile: 0)
      end
    end
  end

  # A ball that falls, hits a floor and climbs back: the smallest game that
  # cannot be written without comparisons. `going_down` is the direction, and
  # the `else` is what makes it a direction rather than a one-way trip.
  defmodule Bouncer do
    @moduledoc false
    use Potion

    defactor :ball do
      variables y: 60, going_down: 1

      every_frame do
        if going_down == 1 do
          y = y + 2
          if y > 100, do: going_down = 0
        else
          y = y - 2
          if y < 20, do: going_down = 1
        end

        sprite(0, x: 80, y: y, tile: 0)
      end
    end
  end

  describe "the game of the fixed surface" do
    test "the ROM boots and the sprite is a square in the middle of the screen" do
      {pixels, _state, _ram} = run_frames(Hero, 6, render: true)

      assert byte_size(pixels) == 160 * 144

      # An eight-by-eight square, whose top-left corner is exactly at the
      # position written in the game — that is the OAM's hardware offset, which
      # the compiler paid for us.
      assert non_white(pixels) == box(@start_x, @start_y)
      # Colour 3 through OBP0: the darkest of the four.
      assert :binary.at(pixels, @start_y * 160 + @start_x) == 3
    end

    test "Right moves the sprite, and the OAM follows" do
      {_pixels, state, ram} = run_frames(Hero, 5)
      addresses = Hero.addresses()

      {_state, ram} = frames(Hero, state, Joypad.set(ram, @right, @released), 4)

      assert Map.get(ram, addresses.x) == @start_x + 4
      assert Map.get(ram, addresses.y) == @start_y

      # The real OAM is one frame behind: the DMA publishes at the vblank what
      # the actor wrote into the mirror at the previous vblank.
      assert Map.get(ram, 0xFE01) == @start_x + 3 + 8
      assert Map.get(ram, 0xFE00) == @start_y + 16
    end

    test "Left, Up and Down move the sprite each in their own direction" do
      {_pixels, state, ram} = run_frames(Hero, 5)
      addresses = Hero.addresses()

      {state, ram} = frames(Hero, state, Joypad.set(ram, @left, @released), 3)
      assert position(ram, addresses) == {@start_x - 3, @start_y}

      {state, ram} = frames(Hero, state, Joypad.set(ram, @up, @released), 5)
      assert position(ram, addresses) == {@start_x - 3, @start_y - 5}

      {state, ram} = frames(Hero, state, Joypad.set(ram, @down, @released), 2)
      assert position(ram, addresses) == {@start_x - 3, @start_y - 3}

      # Released, nothing moves any more: each `if` is a JR over its block, not a
      # state held on to.
      {_state, ram} = frames(Hero, state, Joypad.set(ram, @released, @released), 4)
      assert position(ram, addresses) == {@start_x - 3, @start_y - 3}
    end

    test "the moved sprite is where the pad put it, on screen" do
      {_pixels, state, ram} = run_frames(Hero, 5)

      {state, ram} = frames(Hero, state, Joypad.set(ram, @right, @released), 6)
      {state, ram} = frames(Hero, state, Joypad.set(ram, @down, @released), 3)

      # Keys released, one beat frame: what the screen shows is two vblanks
      # behind the actor — the DMA publishes at the vblank what the actor had
      # written at the previous vblank, and a frame's visible lines come before
      # its vblank. On a still sprite it does not show; on a sprite that has just
      # moved, the pipe has to be let drain.
      {state, ram} = frames(Hero, state, Joypad.set(ram, @released, @released), 1)
      {pixels, _state, _ram} = Screen.frame(state, Hero.rom(), ram, true)

      assert non_white(pixels) == box(@start_x + 6, @start_y + 3)
    end
  end

  describe "the initial values" do
    test "the allocated cells carry 80 and 72, without anything being touched" do
      {_pixels, state, ram} = run_frames(Hero, 5)
      addresses = Hero.addresses()

      assert Map.get(ram, addresses.x) == @start_x
      assert Map.get(ram, addresses.y) == @start_y

      # And there they stay: the "installed" flag was raised on the first turn,
      # so the starting values are not laid down again on every frame — without
      # which no game could move.
      {_state, ram} = frames(Hero, state, ram, 10)

      assert Map.get(ram, addresses.x) == @start_x
      assert Map.get(ram, addresses.y) == @start_y
    end

    test "the allocation is the one the compiler promises" do
      # In declaration order, starting at the first address the kernel leaves to
      # the actor.
      assert Hero.addresses() == %{
               x: Potion.Runtime.actor_state(),
               y: Potion.Runtime.actor_state() + 1
             }

      # The flag comes after, and the game does not see it: it is not in
      # `addresses/0`, but it is indeed at 0xC102 and it is raised.
      {_pixels, _state, ram} = run_frames(Hero, 5)
      assert Map.get(ram, Potion.Runtime.actor_state() + 2) == 0x01
    end
  end

  describe "the generated program" do
    test "it is inspectable, and the kernel has named the actor in it" do
      program = Hero.program()

      assert is_list(program)
      assert {:label, :actor_0} in program

      addresses = Assembler.addresses(program, origin: 0x0150)

      assert addresses.init == 0x0150
      assert Map.has_key?(addresses, :actor_0)
      assert addresses.actor_0 > addresses.main_loop

      # The compiler's labels, all prefixed: one per `if`, plus the one for the
      # installation.
      assert Map.has_key?(addresses, :potion_0_installed)

      for n <- 0..3, do: assert(Map.has_key?(addresses, :"potion_0_end_#{n}"))

      # And the fragment ends with the RET the kernel demands.
      assert List.last(program) == {:ret}
    end

    test "the ROM is 32 KB and carries the module's name" do
      rom = Hero.rom()

      assert byte_size(rom) == 0x8000
      assert binary_part(rom, 0x134, 5) == "HERO" <> <<0>>
    end
  end

  describe "the compiler, without a macro" do
    test "a `quote` and an allocation are enough to obtain a fragment" do
      allocation = Potion.Compiler.allocate(x: 80)

      fragment =
        Potion.Compiler.compile(
          quote do
            if pressed?(:right), do: x = x + 1
          end,
          allocation
        )

      # The installation, the condition, the increment, the RET — with no
      # `defmodule`, no `use`, no host. The compiler is a function over trees,
      # and that is what makes it debuggable by hand.
      assert {:ld, :a, {:mem, allocation.installed}} == hd(fragment)
      assert {:label, :potion_installed} in fragment
      assert {:bit, 0, :a} in fragment
      assert {:add, :a, 1} in fragment
      assert List.last(fragment) == {:ret}
    end
  end

  describe "a literal and a variable in the same sprite" do
    test "both OAM entries carry what the game wrote" do
      {_pixels, state, ram} = run_frames(Mixed, 5)
      addresses = Mixed.addresses()

      # `width = 5` is a bare assignment: it overwrites the initial value, on
      # every frame.
      assert Map.get(ram, addresses.width) == 5
      assert Map.get(ram, addresses.height) == 20

      # Entry 1: x from a variable, y and tile from literals. The hardware
      # offsets are there, computed at compile time for the literals and at run
      # time for the variables.
      assert oam(ram, 1) == [40 + 16, 5 + 8, 3, 0]
      # Entry 2: the other way round — x a literal, y from a variable.
      assert oam(ram, 2) == [20 + 16, 100 + 8, 0, 0]
      # And entry 0, which this game does not write, stayed the init's zero.
      assert oam(ram, 0) == [0, 0, 0, 0]

      # An `if` block with two statements: both go through, or neither.
      {_state, ram} = frames(Mixed, state, Joypad.set(ram, @released, @released - 0x01), 3)

      assert Map.get(ram, addresses.width) == 6
      assert Map.get(ram, addresses.height) == 20 + 6
    end
  end

  # ══ The refusals, at compile time ════════════════════════════════════════════

  # The same ball, but its step is a variable rather than a literal -- which is
  # what `x = x + speed` buys, and what a Pong ball needs: a direction that is
  # data, not two branches of code.
  defmodule Drifter do
    @moduledoc false
    use Potion

    defactor :ball do
      variables x: 40, step: 3, limit: 120

      every_frame do
        x = x + step

        if x >= limit, do: step = 0

        sprite(0, x: x, y: 70, tile: 0)
      end
    end
  end

  # A ball that turns around: `vx` is a direction, and reversing it is the whole
  # of a bounce. This is the one game that would not compile without the sign --
  # the same `x = x + vx` has to walk both ways depending on a byte.
  defmodule Rebound do
    @moduledoc false
    use Potion

    defactor :ball do
      variables x: 100, vx: 1, facing: 0

      every_frame do
        x = x + vx

        if x > 120, do: vx = -vx
        if x < 20, do: vx = -vx

        if negative?(vx), do: facing = 1, else: facing = 0

        sprite(0, x: x, y: 72, tile: 0)
      end
    end
  end

  # Two actors in one game: each with its own cells, its own sprite, its own
  # pace. `follower` reads a cell `leader` wrote earlier in the same frame --
  # which only means anything because the kernel calls the slots in declaration
  # order, every frame, with nothing in between.
  defmodule Pair do
    @moduledoc false
    use Potion

    defactor :leader do
      variables leader_x: 20

      every_frame do
        leader_x = leader_x + 1
        sprite(0, x: leader_x, y: 40, tile: 0)
      end
    end

    defactor :follower do
      variables follower_x: 0

      every_frame do
        follower_x = leader_x - 8
        sprite(1, x: follower_x, y: 60, tile: 0)
      end
    end
  end

  # A score on the background layer: no sprite, no OAM entry, just a square of
  # the map pointed at a digit of the kernel's font.
  defmodule Scoreboard do
    @moduledoc false
    use Potion

    defactor :hud do
      variables score: 0, wait: 0

      every_frame do
        wait = wait + 1

        if wait == 4 do
          wait = 0
          score = score + 1
        end

        background(2, 1, digit: score)
      end
    end
  end

  # Five cells and five questions, between them every path an `and` or an `or`
  # can take. Three of them are load-bearing and were not obvious:
  #
  #   * `or` where only the *left* side holds, which is the fall-through into
  #     the body and the one shape this module had to invert a test for;
  #   * `and` whose *second* test fails, which is the only case that notices an
  #     `and` dropping its right operand — one whose first test fails is
  #     satisfied by the first alone, and a compiler that forgot the rest of the
  #     sentence would pass it;
  #   * `and` whose first test fails, for the plain short circuit.
  #
  # The middle one is here because it was missing, and its absence was found by
  # deleting the concatenation and watching every assertion still hold.
  defmodule Gate do
    @moduledoc false
    use Potion

    defactor :gate do
      variables a: 5, b: 3, both: 0, right_only: 0, left_only: 0, neither: 0, half: 0

      every_frame do
        if a == 5 and b == 3, do: both = 1
        if a == 9 or b == 3, do: right_only = 1
        if a == 5 or b == 9, do: left_only = 1
        if a == 9 and b == 3, do: neither = 1
        if a == 5 and b == 9, do: half = 1
      end
    end
  end

  # A game with a drawing. `shades.png` is the four-shade fixture from
  # `Potion.TilesTest`, two tiles wide, and the names are handed out in reading
  # order — so `:bands` is tile 0 of the sheet and `:split` tile 1.
  defmodule Painted do
    @moduledoc false
    use Potion

    tiles(from: "fixtures/shades.png", names: [:bands, :split])

    defactor :thing do
      variables x: 40

      every_frame do
        sprite(0, x: x, y: 20, tile: :bands)
        background(3, 4, tile: :split)
      end
    end
  end

  # Three screens and the two ways out of each: a key, and a count of frames.
  # `seen` and `played` count entries rather than frames, so they are what says
  # `on_enter` ran once per transition and not once per frame.
  defmodule Screens do
    @moduledoc false
    use Potion

    defactor :director do
      variables step: 0, seen: 0, played: 0

      state :title do
        on_enter do
          seen = seen + 1
          text(5, 6, "PRESS START")
        end

        every_frame do
          if pressed?(:start), do: become(:playing)
        end
      end

      state :playing do
        on_enter do
          played = played + 1
          step = 0
        end

        every_frame do
          step = step + 1
          if step == 3, do: fade(1)
          if step == 6, do: fade(2)
          if step >= 9, do: become(:title)
        end
      end
    end
  end

  # One state that becomes itself. `become` sets the entry marker to a number no
  # state answers to rather than leaving it alone, and this is the only shape
  # that can tell: every other transition goes somewhere else, where the marker
  # already differs and the entry would have run regardless.
  defmodule Restart do
    @moduledoc false
    use Potion

    defactor :thing do
      variables entries: 0

      state :only do
        on_enter do
          entries = entries + 1
        end

        every_frame do
          if pressed?(:a), do: become(:only)
        end
      end
    end
  end

  # One routine, called from two places that differ only in what they set first.
  # That is Pong's collision in miniature: the callers set `input`, the routine
  # reads it, and the parameter an argument would have carried is a cell — which
  # is what an argument would have compiled to anyway.
  defmodule Twice do
    @moduledoc false
    use Potion

    defactor :thing do
      variables input: 0, doubled: 0, calls: 0, left: 0, right: 0

      routine :double do
        doubled = input + input
        calls = calls + 1
      end

      every_frame do
        if left == 0 do
          input = 3
          double()
          left = doubled
        end

        if right == 0 do
          input = 5
          double()
          right = doubled
        end
      end
    end
  end

  # A game that says one note and never mentions it again.
  defmodule Beeper do
    @moduledoc false
    use Potion

    defactor :voice do
      variables t: 0

      every_frame do
        t = t + 1
        if t == 3, do: beep(:a4)
      end
    end
  end

  # A tune, and a game that starts it and can stop it.
  defmodule Tune do
    @moduledoc false
    use Potion

    music(:theme, "c4 e4 g4 -", beat: 4)

    defactor :voice do
      variables t: 0

      every_frame do
        t = t + 1
        if t == 3, do: play(:theme)
        if t == 30, do: silence()
      end
    end
  end

  # The same tune with nothing to stop it, for the one thing `Tune` cannot show:
  # a tune that reaches its end goes back to its beginning.
  defmodule Rounds do
    @moduledoc false
    use Potion

    music(:round, "c4 g4", beat: 4)

    defactor :voice do
      variables t: 0

      every_frame do
        t = t + 1
        if t == 3, do: play(:round)
      end
    end
  end

  # Four bullets in one array, walked by an index that lives in a cell. Nothing
  # here can be written with named cells: `bullets[n]` is a different address
  # every frame and the compiler does not know which.
  defmodule Volley do
    @moduledoc false
    use Potion

    defactor :guns do
      variables bullets: [10, 20, 30, 40], n: 0, seen: 0, total: 0

      every_frame do
        # Each frame moves one bullet and adds it up, round and round.
        bullets[n] = bullets[n] + 1
        total = total + bullets[n]

        n = n + 1
        if n > 3, do: n = 0

        # A literal index is an address the compiler works out itself.
        seen = bullets[2]

        sprite(0, x: bullets[0], y: bullets[1], tile: 0)
      end
    end
  end

  # Four bullets from one `defactor`. The body never says which one it is: `bx`
  # means this instance's `bx`, and the compiler puts the subscript in.
  #
  # The gun is a separate actor that reaches into the pool from outside, where
  # the same cells are an ordinary array — which is what makes a pool spawnable
  # at all.
  defmodule Volley2 do
    @moduledoc false
    use Potion

    defactor :gun do
      variables t: 0, fired: 0

      every_frame do
        t = t + 1

        # Not on the first turn. The pool lays its starting values down on its
        # own first turn, and it runs after this one -- a shot fired before that
        # would be tidied away by the very cells it wrote into.
        if t == 3 do
          if fired == 0 do
            fired = 1
            live[1] = 1
            bx[1] = 40
          end
        end
      end
    end

    defactor :bullet, count: 4 do
      variables bx: 10, live: 0

      every_frame do
        if live == 1, do: bx = bx + 2
        sprite(me, x: bx, y: 60, tile: 0)
      end
    end
  end

  describe "a pool of actors" do
    test "one declaration takes one cell per variable per instance" do
      addresses = Volley2.addresses()

      # `bx` and `live` are four cells each, laid consecutively, so the second
      # array starts four past the first.
      assert addresses.live == addresses.bx + 4
    end

    test "every instance starts alike" do
      # Two turns of the pool, before the gun fires: one `variables` line put 10
      # into all four.
      {_pixels, _state, ram} = run_frames(Volley2, 4)
      base = Volley2.addresses().bx

      assert for(i <- 0..3, do: Map.get(ram, base + i)) == [10, 10, 10, 10]
    end

    # The body runs once per instance and each run sees its own cells. A pool
    # that shared one set would move all four, and a loop that ran once would
    # move none but the first.
    test "the instance that was woken is the only one that moves" do
      {_pixels, _state, ram} = run_frames(Volley2, 10)
      base = Volley2.addresses().bx

      [zero, one, two, three] = for i <- 0..3, do: Map.get(ram, base + i)

      assert one > 44, "the woken bullet did not fly"
      assert [zero, two, three] == [10, 10, 10], "a sleeping bullet moved"
    end

    # `sprite(me, …)` gives each instance its own OAM entry, so four bullets are
    # four sprites rather than four writes to the same one.
    test "each instance writes its own OAM entry" do
      {_pixels, _state, ram} = run_frames(Volley2, 10)

      ys = for entry <- 0..3, do: Map.get(ram, 0xFE00 + 4 * entry)

      # All four are at y = 60 plus the hardware's sixteen.
      assert ys == [76, 76, 76, 76]

      xs = for entry <- 0..3, do: Map.get(ram, 0xFE01 + 4 * entry)
      assert Enum.count(xs, &(&1 == 18)) == 3
      assert Enum.any?(xs, &(&1 > 50)), "the flying bullet's sprite did not follow it"
    end

    test "a count that is not a number of instances is refused" do
      assert_raise Potion.CompileError, ~r/1 to 255/, fn ->
        Code.compile_string("""
        defmodule Pooled.Bad do
          use Potion

          defactor :thing, count: 0 do
            variables x: 0
            every_frame do
              x = x + 1
            end
          end
        end
        """)
      end
    end
  end

  describe "an array" do
    test "its cells are consecutive, and the game sees one name" do
      addresses = Volley.addresses()

      # One entry for the array, at its first cell. The four are not four names.
      assert Map.keys(addresses) |> Enum.sort() == [:bullets, :n, :seen, :total]
      assert addresses.n == addresses.bullets + 4
    end

    # Four frames is two turns of the actor, so bullets 0 and 1 have moved and 2
    # and 3 have not. That the untouched two still read 30 and 40 is the
    # assertion: one `variables` line laid down four different values.
    test "each cell gets its own starting value" do
      {_pixels, _state, ram} = run_frames(Volley, 5)
      base = Volley.addresses().bullets

      assert for(i <- 0..3, do: Map.get(ram, base + i)) == [11, 21, 30, 40]
    end

    # The index is a cell, so the address is worked out at run time. Four frames
    # walk the whole array, and nothing but a real sixteen-bit add gets all four
    # moved exactly once.
    test "an index held in a cell reaches every cell in turn" do
      # Six frames is four turns, which is once round. Every cell moved exactly
      # once, which is what says the address really followed `n` -- a broken add
      # would move one of them four times.
      {_pixels, _state, ram} = run_frames(Volley, 7)
      base = Volley.addresses().bullets

      assert for(i <- 0..3, do: Map.get(ram, base + i)) == [11, 21, 31, 41]
    end

    test "a literal index costs nothing at run time" do
      allocation = Potion.Compiler.allocate(bullets: [0, 0, 0, 0], n: 0)
      body = {:=, [], [{:seen, [], nil}, index(:bullets, 2)]}

      # `bullets[2]` is an address, so this is the same two instructions a plain
      # cell would have been -- no HL, no add.
      elements =
        Potion.Compiler.compile(body, %{
          allocation
          | cells: Map.put(allocation.cells, :seen, 0xC1F0)
        })

      refute Enum.any?(elements, &match?({:add, :hl, _}, &1))
      assert {:ld, :a, {:mem, allocation.cells.bullets + 2}} in elements
    end

    test "a cell index brings out the sixteen-bit add" do
      allocation = Potion.Compiler.allocate(bullets: [0, 0, 0, 0], n: 0, seen: 0)
      body = {:=, [], [{:seen, [], nil}, index(:bullets, {:n, [], nil})]}

      elements = Potion.Compiler.compile(body, allocation)

      assert {:add, :hl, :bc} in elements
      assert {:ld, :bc, allocation.cells.bullets} in elements
    end

    test "an index written past the end is refused, and the message counts" do
      allocation = Potion.Compiler.allocate(bullets: [0, 0, 0, 0], seen: 0)
      body = {:=, [], [{:seen, [], nil}, index(:bullets, 4)]}

      assert_raise Potion.CompileError, ~r/has 4 cells.*number 4.*last one is 3/s, fn ->
        Potion.Compiler.compile(body, allocation)
      end
    end

    test "indexing something that is not an array says so" do
      allocation = Potion.Compiler.allocate(x: 0, bullets: [0, 0])
      body = {:=, [], [{:x, [], nil}, index(:x, 0)]}

      assert_raise Potion.CompileError, ~r/:x is not an array.*:bullets/s, fn ->
        Potion.Compiler.compile(body, allocation)
      end
    end

    test "an array with nothing in it is refused" do
      assert_raise Potion.CompileError, ~r/no cells in it/, fn ->
        Potion.Compiler.allocate(bullets: [])
      end
    end
  end

  defp index(array, subscript) do
    {{:., [], [Access, :get]}, [], [{array, [], nil}, subscript]}
  end

  # A tune with both voices: a melody on the pulse and a bass under it on the
  # wave channel.
  defmodule Duet do
    @moduledoc false
    use Potion

    music :song,
          [lead: "c5 e5 g5 c6", harmony: "e4 g4 c5 e5", bass: "c2 . g1 ."],
          beat: 6,
          duty: :eighth

    defactor :voice do
      variables t: 0

      every_frame do
        t = t + 1
        if t == 3, do: play(:song)
      end
    end
  end

  # A tune with a harmony, and a beep fired into the middle of it.
  defmodule Interrupted do
    @moduledoc false
    use Potion

    music :song, [lead: "c5 e5 g5 c6", harmony: "e4 g4 c5 e5"], beat: 6

    defactor :voice do
      variables t: 0

      every_frame do
        t = t + 1
        if t == 3, do: play(:song)
        if t == 12, do: beep(:c6)
      end
    end
  end

  describe "three voices" do
    # Each channel's frequency register is read back on its own, because the
    # mixed samples cannot say which channel a sound came from — and "both are
    # playing" is the only thing this feature claims.
    test "the three play at once, each on its own channel" do
      heard = duet(Duet, 30)

      lead = heard |> Enum.map(&elem(&1, 0)) |> Enum.dedup() |> Enum.reject(&(&1 == 0))
      bass = heard |> Enum.map(&elem(&1, 2)) |> Enum.dedup() |> Enum.reject(&(&1 == 0))

      notes = Potion.Music.notes()
      wave = Potion.Music.wave_notes()

      harmony = heard |> Enum.map(&elem(&1, 1)) |> Enum.dedup() |> Enum.reject(&(&1 == 0))

      assert lead == [notes[:c5], notes[:e5], notes[:g5], notes[:c6]]
      assert harmony == [notes[:e4], notes[:g4], notes[:c5], notes[:e5]]
      assert bass == [wave[:c2], wave[:g1]]

      together = Enum.count(heard, fn {l, h, b} -> l != 0 and h != 0 and b != 0 end)
      assert together > 15, "the three voices barely overlapped: #{together} frames of 30"
    end

    # `beep` is on channel 2 and so is the harmony. A sound effect therefore
    # takes the harmony's voice for as long as it lasts, and the harmony comes
    # back at its next step. Nothing coordinates that — the next note writes over
    # the effect — and it is what a Game Boy game sounds like: four channels and
    # more than four things to say.
    test "a sound effect borrows the harmony's channel and gives it back" do
      rom = Beeper.rom()
      _ = rom

      heard = duet(Interrupted, 30)
      notes = Potion.Music.notes()

      channel_two = heard |> Enum.map(&elem(&1, 1)) |> Enum.dedup() |> Enum.reject(&(&1 == 0))

      assert notes[:c6] in channel_two, "the beep never reached channel 2"
      assert List.last(channel_two) != notes[:c6], "the harmony never came back"
    end

    # The wave channel counts its period twice as slowly, so the same note is a
    # different number there. Reading the bass against the lead's table would put
    # it an octave out, and both would still look like notes.
    # The duty travels in a kernel cell that `play` writes, because the player
    # rewrites NR11 on every note and would otherwise put a plain square there.
    test "the tune's duty reaches the channel" do
      rom = Duet.rom()

      {_state, _ram, nr11} =
        Enum.reduce(1..12, {Screen.boot_state(rom), Screen.boot_ram(rom), nil}, fn
          _n, {state, ram, seen} ->
            {_pixels, state, ram} = Screen.frame(state, rom, ram, false)
            {state, ram, seen || Map.get(ram, 0xFF11)}
        end)

      assert Bitwise.bsr(nr11, 6) == 0, "the lead is a plain square, not the eighth it asked for"
    end

    test "the bass is not the lead's numbers" do
      assert Potion.Music.wave_notes()[:c2] != Potion.Music.notes()[:c2]
    end
  end

  # The three frequency registers, frame by frame: channels 1, 2 and 3.
  defp duet(game, count) do
    rom = game.rom()

    {_state, _ram, _apu, heard} =
      Enum.reduce(1..count, {Screen.boot_state(rom), Screen.boot_ram(rom), %Atomboy.APU{}, []}, fn
        _n, {state, ram, apu, acc} ->
          {_pixels, state, ram} = Screen.frame(state, rom, ram, false)
          {_samples, ram, apu} = Atomboy.APU.frame(ram, apu)

          lead = Map.get(ram, 0xFF13, 0) + Bitwise.band(Map.get(ram, 0xFF14, 0), 0x07) * 256
          harmony = Map.get(ram, 0xFF18, 0) + Bitwise.band(Map.get(ram, 0xFF19, 0), 0x07) * 256
          bass = Map.get(ram, 0xFF1D, 0) + Bitwise.band(Map.get(ram, 0xFF1E, 0), 0x07) * 256

          {state, ram, apu, [{lead, harmony, bass} | acc]}
      end)

    Enum.reverse(heard)
  end

  describe "a tune" do
    # A length of zero is the terminator and sends the cursor back to the base
    # pointer, which is why `play` writes both. Without the reset the player
    # would walk off the end of the tune into whatever bytes follow it, so this
    # is the assertion that keeps a cartridge from playing its own font.
    test "it comes round again on its own" do
      heard = channel_one(Rounds, 40)
      notes = Potion.Music.notes()

      runs = heard |> Enum.map(&elem(&1, 0)) |> Enum.dedup() |> Enum.reject(&(&1 == 0))

      assert Enum.take(runs, 4) == [notes[:c4], notes[:g4], notes[:c4], notes[:g4]]
    end

    # The kernel reads a step a frame between the pad and the actors, so what a
    # game says once is heard for as long as it lasts. The frequency register is
    # read back rather than the samples, because it says which *note* -- a peak
    # would only say that something sounded.
    test "the notes come out in the order they were written" do
      heard = channel_one(Tune, 24)

      # Four frames a beat, and the first note lands on the frame after the one
      # that started it. Runs rather than exact frames: what is being pinned is
      # the order and the pitches, not the emulator's start-up timetable.
      runs = heard |> Enum.map(&elem(&1, 0)) |> Enum.dedup() |> Enum.reject(&(&1 == 0))
      notes = Potion.Music.notes()

      assert runs == [notes[:c4], notes[:e4], notes[:g4]]
    end

    # A rest carries no trigger; it takes the envelope to zero instead. That is
    # what makes it silence rather than a note nobody asked for, and the only
    # way to see it is that the channel goes quiet while its frequency register
    # still holds the note before.
    test "a rest silences without changing the note" do
      heard = channel_one(Tune, 24)

      # Only once a note has been in the register: before the tune starts the
      # channel is silent too, and for a duller reason.
      quiet = Enum.filter(heard, fn {x, loud} -> loud == 0 and x != 0 end)

      assert quiet != [], "the rest never silenced anything"
      assert Enum.all?(quiet, fn {x, _loud} -> x == Potion.Music.notes()[:g4] end)
    end

    test "`silence` stops it, and it stays stopped" do
      heard = channel_one(Tune, 45)
      after_stop = heard |> Enum.drop(33) |> Enum.map(&elem(&1, 1))

      assert Enum.max(after_stop) == 0, "the tune played on after `silence`"
    end

    test "a tune that was never declared is refused, with the ones that were" do
      allocation = Potion.Compiler.allocate([x: 0], tunes: [:theme, :hurry])

      assert_raise Potion.CompileError, ~r/no tune is called :them.*:hurry, :theme/s, fn ->
        Potion.Compiler.compile({:play, [], [:them]}, allocation)
      end
    end
  end

  # Channel 1, frame by frame: the eleven-bit frequency the register holds, and
  # whether anything was actually heard.
  defp channel_one(game, count) do
    rom = game.rom()

    {_state, _ram, _apu, heard} =
      Enum.reduce(1..count, {Screen.boot_state(rom), Screen.boot_ram(rom), %Atomboy.APU{}, []}, fn
        _n, {state, ram, apu, acc} ->
          {_pixels, state, ram} = Screen.frame(state, rom, ram, false)
          {samples, ram, apu} = Atomboy.APU.frame(ram, apu)

          x = Map.get(ram, 0xFF13, 0) + Bitwise.band(Map.get(ram, 0xFF14, 0), 0x07) * 256
          loud = for(<<v::little-signed-16 <- samples>>, do: abs(v)) |> Enum.max(fn -> 0 end)

          {state, ram, apu, [{x, loud} | acc]}
      end)

    Enum.reverse(heard)
  end

  # A game that knocks and beeps in the same breath, which is the point of there
  # being four channels: the knock is channel 4 and the note is channel 2, so
  # neither cuts the other.
  defmodule Knock do
    @moduledoc false
    use Potion

    defactor :hand do
      variables t: 0

      every_frame do
        t = t + 1

        if t == 3 do
          noise(:hit)
          beep(:c5)
        end
      end
    end
  end

  describe "a knock" do
    # Channel 4 has no pitch to read back, so what says the four names mean
    # something is how *coarse* each one is: a bright noise switches the output
    # many times a frame and a low one hardly at all. Measured rather than
    # asserted, because "it sounds different" is not a thing a test can hear.
    test "the four are a real continuum from bright to low" do
      coarseness = for kind <- [:tick, :hit, :thud, :boom], do: transitions(kind)

      assert coarseness == Enum.sort(coarseness, :desc),
             "the four noises do not get coarser in the order they are named: #{inspect(coarseness)}"

      [tick | _] = coarseness
      boom = List.last(coarseness)

      assert tick > boom * 10, "the brightest and the lowest are barely different"
    end

    test "a knock and a note sound together, on channels of their own" do
      {_pixels, _state, ram} = run_frames(Knock, 6)

      # Channel 2's frequency was written by `beep`, channel 4's shape by
      # `noise`, and both envelopes are live. One statement could not have done
      # both -- they are different registers on different channels.
      assert Map.get(ram, 0xFF18, 0) != 0, "the note never reached channel 2"
      assert Map.get(ram, 0xFF22, 0) != 0, "the knock never reached channel 4"
      assert Map.get(ram, 0xFF17, 0) != 0
      assert Map.get(ram, 0xFF21, 0) != 0
    end

    test "a name that is not one of the four is refused, with the four" do
      assert_raise Potion.CompileError,
                   ~r/no noise is called :crash.*:boom, :hit, :thud, :tick/s,
                   fn ->
                     Potion.Compiler.compile(
                       {:noise, [], [:crash]},
                       Potion.Compiler.allocate(x: 0)
                     )
                   end
    end
  end

  # How many times the mixed output changes value in the loudest frame of a
  # knock. It is a proxy for brightness and it is the only one the samples give
  # without a spectrum.
  defp transitions(kind) do
    [{module, _} | _] =
      Code.compile_string("""
      defmodule Knocking.#{kind |> Atom.to_string() |> String.capitalize()} do
        use Potion

        defactor :bang do
          variables t: 0

          every_frame do
            t = t + 1
            if t == 3, do: noise(:#{kind})
          end
        end
      end
      """)

    rom = module.rom()

    {_state, _ram, _apu, counts} =
      Enum.reduce(1..20, {Screen.boot_state(rom), Screen.boot_ram(rom), %Atomboy.APU{}, []}, fn
        _n, {state, ram, apu, acc} ->
          {_pixels, state, ram} = Screen.frame(state, rom, ram, false)
          {samples, ram, apu} = Atomboy.APU.frame(ram, apu)

          values = for <<value::little-signed-16 <- samples>>, do: value

          changes =
            values |> Enum.chunk_every(2, 1, :discard) |> Enum.count(fn [a, b] -> a != b end)

          {state, ram, apu, [changes | acc]}
      end)

    Enum.max(counts)
  end

  describe "a note" do
    # The only judge of a sound is the APU, so the game is played and the samples
    # are read. What the trace has to show is not merely that something was heard
    # but that it *stopped* -- the game writes four registers and never comes
    # back, so if the envelope did not end the note nothing would.
    test "it is heard, and it ends without the game ending it" do
      peaks = peaks(Beeper, 20)

      before = peaks |> Enum.take(4) |> Enum.max()
      assert before == 0, "something sounded before the game asked"

      loudest = Enum.max(peaks)
      assert loudest > 0, "the note was never heard"

      # From the peak onward it only ever falls, and reaches nothing. That is the
      # envelope stepping down on its own: fifteen steps of a fixed size, which
      # is what makes `beep` a statement rather than a thing to keep feeding.
      after_peak = Enum.drop_while(peaks, &(&1 < loudest))

      assert after_peak == Enum.sort(after_peak, :desc)
      assert List.last(peaks) == 0, "the note never stopped"
    end

    # The kernel powers the APU on, and this is the only test that can tell.
    # Both the console after its boot ROM and this emulator by default leave
    # NR52 already on, so on an ordinary boot that write lands on a bit that was
    # set — removing it changes nothing anybody would notice. It matters when
    # something ran first and left the APU off, which is what this arranges: with
    # the power bit clear, every other sound register ignores writes, so a `beep`
    # would be four stores into nothing.
    test "a beep is heard even when the APU was found switched off" do
      rom = Beeper.rom()
      silenced = Map.put(Screen.boot_ram(rom), 0xFF26, 0x00)

      {_state, _ram, _apu, peaks} =
        Enum.reduce(1..12, {Screen.boot_state(rom), silenced, %Atomboy.APU{}, []}, fn
          _n, {state, ram, apu, acc} ->
            {_pixels, state, ram} = Screen.frame(state, rom, ram, false)
            {samples, ram, apu} = Atomboy.APU.frame(ram, apu)
            peak = for(<<v::little-signed-16 <- samples>>, do: abs(v)) |> Enum.max(fn -> 0 end)
            {state, ram, apu, [peak | acc]}
        end)

      assert Enum.max(peaks) > 0, "the kernel left the APU off and the beep went nowhere"
    end

    test "a note the console cannot reach is refused rather than rounded" do
      assert_raise Potion.CompileError, ~r/no note is called :c0/, fn ->
        Potion.Compiler.compile({:beep, [], [:c0]}, Potion.Compiler.allocate(x: 0))
      end
    end

    # The table is the console's own formula run backwards, so the numbers are
    # checkable rather than chosen. 440 Hz is A4 by definition.
    test "the number a note becomes is the one the hardware formula asks for" do
      assert Potion.Compiler.notes()[:a4] == 2048 - round(131_072 / 440)
      assert Potion.Compiler.notes()[:a5] == 2048 - round(131_072 / 880)
    end
  end

  # One frame at a time, the APU advanced alongside, and the loudest sample of
  # each frame kept. Loudness rather than the samples themselves because the
  # shape of a square wave is the emulator's business and its envelope is ours.
  defp peaks(game, count) do
    rom = game.rom()

    {_state, _ram, _apu, peaks} =
      Enum.reduce(1..count, {Screen.boot_state(rom), Screen.boot_ram(rom), %Atomboy.APU{}, []}, fn
        _n, {state, ram, apu, acc} ->
          {_pixels, state, ram} = Screen.frame(state, rom, ram, false)
          {samples, ram, apu} = Atomboy.APU.frame(ram, apu)

          peak =
            for(<<value::little-signed-16 <- samples>>, do: abs(value))
            |> Enum.max(fn -> 0 end)

          {state, ram, apu, [peak | acc]}
      end)

    Enum.reverse(peaks)
  end

  describe "a routine written once and called twice" do
    test "both callers get the routine's work, on their own input" do
      addresses = Twice.addresses()
      {_pixels, _state, ram} = run_frames(Twice, 10)

      assert Map.get(ram, addresses.left) == 6
      assert Map.get(ram, addresses.right) == 10
    end

    # A `CALL` that never returned would run into whatever follows, and the
    # counter says the block ran twice rather than once and fallen through, or
    # twice on a frame that should have stopped after the first.
    test "the routine returns, so the caller carries on" do
      addresses = Twice.addresses()
      {_pixels, _state, ram} = run_frames(Twice, 10)

      assert Map.get(ram, addresses.calls) == 2
    end

    # A `CALL` pushes a return address that only the matching `RET` takes back,
    # so routines calling each other in a circle would grow the stack by two
    # bytes a lap until it reached the actor's own cells. The message names the
    # circle, because a stack that has quietly walked into `x` is a crash a long
    # way from its cause.
    test "routines that call each other in a circle are refused, and the circle is named" do
      error =
        assert_raise Potion.CompileError, fn ->
          Code.compile_string("""
          defmodule Circular.Routines do
            use Potion

            defactor :thing do
              variables x: 0

              routine :one do
                x = x + 1
                two()
              end

              routine :two do
                x = x + 1
                one()
              end

              every_frame do
                one()
              end
            end
          end
          """)
        end

      assert error.message =~ "circle"
      assert error.message =~ ":one"
      assert error.message =~ ":two"
    end

    test "a routine that was never declared is refused, with the ones that were" do
      allocation = Potion.Compiler.allocate([x: 0], routines: [:bounce, :serve])

      assert_raise Potion.CompileError, ~r/no routine is named :bonce.*:bounce, :serve/s, fn ->
        Potion.Compiler.compile({:bonce, [], []}, allocation)
      end
    end

    test "the block is in the ROM once, not once per call" do
      program = Twice.program()

      labels = Enum.filter(program, &match?({:label, :potion_0_do_double}, &1))
      calls = Enum.filter(program, &match?({:call, {:label, :potion_0_do_double}}, &1))

      assert length(labels) == 1
      assert length(calls) == 2
    end
  end

  describe "an actor made of states" do
    test "becoming the state already running enters it again" do
      addresses = Restart.addresses()
      {_pixels, state, ram} = run_frames(Restart, 12)

      assert Map.get(ram, addresses.entries) == 1

      {_state, ram} = frames(Restart, state, Joypad.set(ram, @released, @a_key), 2)

      assert Map.get(ram, addresses.entries) == 2
    end

    test "it wakes up in the first state, and enters it exactly once" do
      addresses = Screens.addresses()
      {_pixels, _state, ram} = run_frames(Screens, 20)

      # Twenty frames in the title screen, one entry. Anything that ran
      # `on_enter` per frame rather than per transition would read 18 here.
      assert Map.get(ram, addresses.seen) == 1
      assert Map.get(ram, addresses.played) == 0
    end

    test "a key changes the state, and the new one is entered" do
      addresses = Screens.addresses()
      {_pixels, state, ram} = run_frames(Screens, 5)

      {_state, ram} = frames(Screens, state, Joypad.set(ram, @released, @start_key), 2)

      assert Map.get(ram, addresses.played) == 1
      assert Map.get(ram, addresses.seen) == 1
    end

    # The whole round trip: title, start, nine frames of play, and back to the
    # title -- which has to be entered a second time. A machine that only ever
    # entered a state once would pass every assertion above this one.
    test "a state left and come back to is entered again" do
      addresses = Screens.addresses()
      {_pixels, state, ram} = run_frames(Screens, 5)

      {state, ram} = frames(Screens, state, Joypad.set(ram, @released, @start_key), 2)
      {_state, ram} = frames(Screens, state, Joypad.set(ram, @released, @released), 12)

      assert Map.get(ram, addresses.played) == 1
      assert Map.get(ram, addresses.seen) == 2
    end

    test "the fade rewrites the palette, and only once the count reaches it" do
      {_pixels, state, ram} = run_frames(Screens, 5)
      {state, ram} = frames(Screens, state, Joypad.set(ram, @released, @start_key), 2)

      # Two frames into `playing`, the count has not reached the first step.
      assert Map.get(ram, 0xFF47) == 0xE4

      {_state, ram} = frames(Screens, state, Joypad.set(ram, @released, @released), 4)
      assert Map.get(ram, 0xFF47) == 0xF9
    end

    # The title screen says PRESS START, painted in `on_enter`. Reading the map
    # back is what says the characters became the right tiles: P is the
    # sixteenth letter, the space is the empty tile the map was already full of,
    # and both have to land on consecutive squares of row 6.
    test "a string becomes tiles on the background map" do
      {_pixels, _state, ram} = run_frames(Screens, 10)

      row = 0x9800 + 6 * 32
      written = for i <- 0..10, do: Map.get(ram, row + 5 + i)

      alphabet = Potion.Runtime.alphabet()

      assert written == [
               alphabet + (?P - ?A),
               alphabet + (?R - ?A),
               alphabet + (?E - ?A),
               alphabet + (?S - ?A),
               alphabet + (?S - ?A),
               1,
               alphabet + (?S - ?A),
               alphabet + (?T - ?A),
               alphabet + (?A - ?A),
               alphabet + (?R - ?A),
               alphabet + (?T - ?A)
             ]
    end

    # The glyph a letter points at has to be the letter, not merely a distinct
    # number per character -- a mapping off by one would satisfy the test above
    # and spell QSFTT TUBSU on the glass.
    test "the tile a letter points at holds the letter's own bitmap" do
      {_pixels, _state, ram} = run_frames(Screens, 10)

      # P, the sixteenth letter: its sixteen bytes, read out of VRAM.
      start = 0x8000 + (Potion.Runtime.alphabet() + (?P - ?A)) * 16
      copied = for i <- 0..15, do: Map.get(ram, start + i, 0)

      expected = binary_part(Potion.Runtime.letter_bytes(), (?P - ?A) * 16, 16)
      assert :binary.list_to_bin(copied) == expected
    end

    test "the two cells the machine keeps are not in the game's own" do
      # `addresses/0` is what a game sees, and it sees what it declared. The
      # state and the entry marker are the compiler's, like the installed flag.
      assert Map.keys(Screens.addresses()) |> Enum.sort() == [:played, :seen, :step]
    end
  end

  describe "a drawing brought into the game" do
    # The whole chain in one assertion: a PNG on disk, cut while this file
    # compiled, laid into the cartridge, copied by the kernel's init, and read
    # back out of the emulator's VRAM. Comparing against `Potion.Tiles` rather
    # than against bytes written here is deliberate -- the two would have to be
    # wrong the same way to agree, and the tile cutter has its own fixture.
    test "the sheet is copied into VRAM at the base the kernel reserved" do
      {_pixels, _state, ram} = run_frames(Painted, 10)

      base = 0x8000 + Potion.Runtime.art_base() * 16
      copied = for i <- 0..31, do: Map.get(ram, base + i, 0)

      expected = Path.join(__DIR__, "fixtures/shades.png") |> Potion.Tiles.read!() |> Enum.join()

      assert :binary.list_to_bin(copied) == expected
    end

    # The game says `:bands` and the OAM holds 12. Nothing in the source names
    # that number, and nothing should: the kernel spoke for the first twelve
    # tiles and a game has no reason to learn how many.
    test "a name becomes the index the kernel left room for" do
      {_pixels, _state, ram} = run_frames(Painted, 10)

      [_y, _x, tile, _flags] = oam(ram, 0)
      assert tile == Potion.Runtime.art_base()
    end

    test "the second tile of the sheet is the second name" do
      {_pixels, _state, ram} = run_frames(Painted, 10)

      # background(3, 4, tile: :split) -- the map is 32 wide.
      assert Map.get(ram, 0x9800 + 4 * 32 + 3) == Potion.Runtime.art_base() + 1
    end

    # The assertion above compares the index against `art_base/0`, so it would
    # hold just as well if that base moved down onto the digits. This one states
    # what the base is actually for: after the sheet has been copied, the
    # kernel's own font is still where it put it.
    test "the drawing lands past the kernel's tiles rather than on top of them" do
      {_pixels, _state, ram} = run_frames(Painted, 10)

      # All ten digits and not just the first: a base one tile too low would
      # leave the front of the font untouched and eat the back of it, and a
      # single glyph checked at either end would have said nothing.
      font = Potion.Runtime.font_bytes()
      start = 0x8000 + Potion.Runtime.digits() * 16
      copied = for i <- 0..(byte_size(font) - 1), do: Map.get(ram, start + i, 0)

      assert :binary.list_to_bin(copied) == font
    end

    test "an unknown name is refused, and the message lists the ones there are" do
      allocation = Potion.Compiler.allocate([x: 0], tiles: %{ball: 0, paddle: 1})
      body = {:sprite, [], [0, [x: 8, y: 8, tile: :bal]]}

      assert_raise Potion.CompileError, ~r/no tile is named :bal.*:ball, :paddle/s, fn ->
        Potion.Compiler.compile(body, allocation)
      end
    end

    test "a game with no drawing at all says so rather than listing nothing" do
      allocation = Potion.Compiler.allocate(x: 0)
      body = {:sprite, [], [0, [x: 8, y: 8, tile: :ball]]}

      assert_raise Potion.CompileError, ~r/declares no tiles at all/, fn ->
        Potion.Compiler.compile(body, allocation)
      end
    end
  end

  describe "`and` and `or`" do
    test "every path through the two operators" do
      addresses = Gate.addresses()
      {_pixels, _state, ram} = run_frames(Gate, 10)

      assert Map.get(ram, addresses.both) == 1, "`and` with both sides true"
      assert Map.get(ram, addresses.right_only) == 1, "`or` where only the right side holds"
      assert Map.get(ram, addresses.left_only) == 1, "`or` where only the left side holds"
      assert Map.get(ram, addresses.neither) == 0, "`and` whose first test fails"
      assert Map.get(ram, addresses.half) == 0, "`and` whose second test fails"
    end

    # The whole claim of `and`, and the reason it costs nothing: a condition
    # already emits the jumps that leave when it is false, so two of them in a
    # row leave when either is false. There is nothing to add and nothing to
    # invert, and the proof is that the bytes do not move.
    test "`and` is the nested ifs it replaces, byte for byte" do
      allocation = Potion.Compiler.allocate(x: 0, y: 0, hit: 0)

      assign = {:=, [], [{:hit, [], nil}, 1]}
      left = {:<, [], [{:x, [], nil}, 5]}
      right = {:>, [], [{:y, [], nil}, 3]}

      joined = {:if, [], [{:and, [], [left, right]}, [do: assign]]}
      nested = {:if, [], [left, [do: {:if, [], [right, [do: assign]]}]]}

      bytes = fn tree ->
        tree
        |> Potion.Compiler.compile(allocation)
        |> Potion.Runtime.program()
        |> Potion.Assembler.assemble(origin: 0x0150)
      end

      assert bytes.(joined) == bytes.(nested)
    end
  end

  describe "the flags a comparison reads" do
    # `CP n` is a subtraction thrown away: Z if equal, C if A was the smaller.
    # Every comparison is a choice of jumps over those two bits, and the choice
    # is the whole semantics -- a played game does not always notice a wrong
    # one. A ball stepping by two crosses `> 100` at 102 whether or not the
    # equality is ruled out, so the boundary is stated here instead.
    test "each comparison spells its own flag test" do
      allocation = Potion.Compiler.allocate(x: 0, hit: 0)

      conditions = fn operator ->
        condition = {operator, [], [{:x, [], nil}, 5]}
        body = {:if, [], [condition, [do: {:=, [], [{:hit, [], nil}, 1]}]]}

        body
        |> Potion.Compiler.compile(allocation)
        |> Enum.filter(fn
          {_, _, {:label, :potion_installed}} -> false
          {mnemonic, _, _} when mnemonic in [:jr, :jp] -> true
          _ -> false
        end)
        |> Enum.map(&elem(&1, 1))
      end

      assert conditions.(:==) == [:nz]
      assert conditions.(:!=) == [:z]
      assert conditions.(:<) == [:nc]
      assert conditions.(:>=) == [:c]

      # Greater-than has to rule out equality as well as the borrow.
      assert conditions.(:>) == [:c, :z]

      # Less-or-equal is the only one that jumps *into* the body: "C or Z"
      # cannot be said by jumping away from it.
      assert conditions.(:<=) == [:c, :nz]
    end

    # The jumps that leave an `if` are absolute, and this is the reason. They
    # were relative, which reaches 127 bytes, and Pong's ball walked off that
    # cliff at 152: a collision, the offset it was struck at, and two ladders of
    # four speeds. Nothing about that block is extravagant — but the failure it
    # produced spoke of JR displacements, which is not a thing the author of a
    # game has any reason to have heard of.
    #
    # Forty assignments at five bytes each put the label some two hundred bytes
    # past the jump, which no relative jump can reach and every absolute one can.
    test "an `if` block may be larger than a relative jump could reach" do
      allocation = Potion.Compiler.allocate(x: 0, hit: 0)

      statements = for value <- 1..40, do: {:=, [], [{:hit, [], nil}, rem(value, 256)]}
      condition = {:>, [], [{:x, [], nil}, 5]}
      body = {:if, [], [condition, [do: {:__block__, [], statements}]]}

      elements = Potion.Compiler.compile(body, allocation)

      assert is_binary(
               Potion.Assembler.assemble(Potion.Runtime.program(elements), origin: 0x0150)
             )
    end

    test "the comparison loads the variable it names" do
      allocation = Potion.Compiler.allocate(x: 0, y: 0, hit: 0)
      condition = {:>, [], [{:y, [], nil}, 140]}
      body = {:if, [], [condition, [do: {:=, [], [{:hit, [], nil}, 1]}]]}

      elements = Potion.Compiler.compile(body, allocation)

      assert {:ld, :a, {:mem, allocation.cells.y}} in elements
      assert {:cp, :a, 140} in elements
    end
  end

  describe "a game that compares" do
    test "the ball falls, then turns round on its own" do
      addresses = Bouncer.addresses()

      # The actor runs from the third frame; 30 frames is 28 turns, enough to
      # cover the 20 steps down to the floor and start back up.
      {_pixels, _state, ram} = run_frames(Bouncer, 30)

      assert Map.get(ram, addresses.going_down) == 0, "it should have bounced"
      assert Map.get(ram, addresses.y) < 102
    end

    test "it never escapes the two walls it was given" do
      rom = Bouncer.rom()
      addresses = Bouncer.addresses()

      # The first turns are dropped: the init leaves the page at zero, and a
      # `y` that has not been laid down yet is not a position the game chose.
      {_final, seen} =
        Enum.reduce(1..120, {{Screen.boot_state(rom), Screen.boot_ram(rom)}, []}, fn n,
                                                                                     {{state,
                                                                                       ram},
                                                                                      seen} ->
          {_pixels, state, ram} = Screen.frame(state, rom, ram, false)
          {{state, ram}, if(n > 4, do: [Map.get(ram, addresses.y) | seen], else: seen)}
        end)

      travelled = seen |> Enum.reject(&is_nil/1) |> Enum.uniq()

      assert Enum.min(travelled) >= 18, "it went through the ceiling: #{Enum.min(travelled)}"
      assert Enum.max(travelled) <= 102, "it went through the floor: #{Enum.max(travelled)}"

      # A ball that never moved would also satisfy the two walls.
      assert length(travelled) > 20, "it barely moved: #{inspect(travelled)}"
    end

    test "the sprite follows the variable, one turn behind" do
      addresses = Bouncer.addresses()

      # The DMA publishes the mirror at the vblank *after* the actor filled it,
      # so the OAM always shows the previous turn's position. On a hero that
      # only moves under your thumb the lag is invisible; on a ball that moves
      # every frame it is the whole difference between right and nearly right.
      {_pixels, state, ram} = run_frames(Bouncer, 29)
      written = Map.get(ram, addresses.y)

      {_state, ram} = frames(Bouncer, state, ram, 1)
      [oam_y, oam_x, tile, flags] = oam(ram, 0)

      assert oam_y == written + 16
      assert oam_x == 80 + 8
      assert {tile, flags} == {0, 0}
    end
  end

  describe "a variable on the right-hand side" do
    test "the ball advances by a step it reads from memory" do
      addresses = Drifter.addresses()

      # Three turns of the actor: 40, 43, 46.
      {_pixels, _state, ram} = run_frames(Drifter, 6)

      assert Map.get(ram, addresses.x) == 40 + 3 * 3
      assert Map.get(ram, addresses.step) == 3
    end

    test "it stops where another variable says to, not where a literal does" do
      {_pixels, _state, ram} = run_frames(Drifter, 60)
      addresses = Drifter.addresses()

      assert Map.get(ram, addresses.step) == 0, "it should have reached the limit"

      x = Map.get(ram, addresses.x)
      assert x >= 120 and x < 123, "it stopped at #{x}, not just past its limit"
    end

    test "the addition reaches the second variable through HL" do
      allocation = Potion.Compiler.allocate(x: 0, step: 0)
      body = {:=, [], [{:x, [], nil}, {:+, [], [{:x, [], nil}, {:step, [], nil}]}]}

      elements = Potion.Compiler.compile(body, allocation)

      assert {:ld, :a, {:mem, allocation.cells.x}} in elements
      assert {:ld, :hl, allocation.cells.step} in elements
      assert {:add, :a, {:mem, :hl}} in elements
      assert {:ld, {:mem, allocation.cells.x}, :a} in elements
    end

    test "a comparison reaches it the same way" do
      allocation = Potion.Compiler.allocate(x: 0, limit: 0, hit: 0)
      condition = {:>=, [], [{:x, [], nil}, {:limit, [], nil}]}
      body = {:if, [], [condition, [do: {:=, [], [{:hit, [], nil}, 1]}]]}

      elements = Potion.Compiler.compile(body, allocation)

      assert {:ld, :hl, allocation.cells.limit} in elements
      assert {:cp, :a, {:mem, :hl}} in elements
    end

    test "a literal still costs one instruction less" do
      allocation = Potion.Compiler.allocate(x: 0)
      body = {:=, [], [{:x, [], nil}, {:+, [], [{:x, [], nil}, 3]}]}

      elements = Potion.Compiler.compile(body, allocation)

      assert {:add, :a, 3} in elements
      refute Enum.any?(elements, &match?({:ld, :hl, _}, &1))
    end
  end

  describe "the sign" do
    test "the ball walks forward, turns around, and walks back" do
      addresses = Rebound.addresses()

      # Three turns of the actor, all forward.
      {_pixels, _state, ram} = run_frames(Rebound, 6)
      assert Map.get(ram, addresses.x) == 103
      assert Map.get(ram, addresses.vx) == 1

      # Past 120 the direction is reversed, and `x = x + vx` -- the very same
      # sentence -- now walks the other way. 121 was the far point, and by the
      # 26th frame the ball has come back two steps.
      {_pixels, _state, ram} = run_frames(Rebound, 26)
      assert Map.get(ram, addresses.x) == 119
      assert Map.get(ram, addresses.vx) == 0xFF, "vx should hold -1 in two's complement"
    end

    test "and turns around again at the other end, without ever leaving the court" do
      # 19 is reached at the 126th frame, and reversed on the spot.
      {_pixels, _state, ram} = run_frames(Rebound, 131)
      addresses = Rebound.addresses()

      assert Map.get(ram, addresses.x) == 24
      assert Map.get(ram, addresses.vx) == 1

      # The invariant the two bounces exist for: the ball never wraps past the
      # walls. An unsigned `x = x + vx` would have run x through 0 to 255 on the
      # first step back.
      {_pixels, _state, ram} = run_frames(Rebound, 130)

      x = Map.get(ram, addresses.x)
      assert x in 19..121, "the ball left the court at #{x}"
    end

    test "`negative?` follows the sign bit, frame by frame" do
      addresses = Rebound.addresses()

      {_pixels, _state, ram} = run_frames(Rebound, 5)
      assert Map.get(ram, addresses.facing) == 0

      {_pixels, _state, ram} = run_frames(Rebound, 25)
      assert Map.get(ram, addresses.facing) == 1
    end

    test "a negative literal is folded into its byte, not computed" do
      allocation = Potion.Compiler.allocate(vx: 0)
      body = {:=, [], [{:vx, [], nil}, {:-, [], [1]}]}

      elements = Potion.Compiler.compile(body, allocation)

      assert {:ld, :a, 0xFF} in elements
      refute {:cpl} in elements
    end

    test "negating a variable is a flip and a step" do
      allocation = Potion.Compiler.allocate(vx: 0)
      body = {:=, [], [{:vx, [], nil}, {:-, [], [{:vx, [], nil}]}]}

      elements = Potion.Compiler.compile(body, allocation)

      assert {:cpl} in elements
      assert {:inc, :a} in elements
    end

    test "`negative?` is one bit test, and the jump is over the body" do
      allocation = Potion.Compiler.allocate(vx: 0, hit: 0)
      condition = {:negative?, [], [{:vx, [], nil}]}
      body = {:if, [], [condition, [do: {:=, [], [{:hit, [], nil}, 1]}]]}

      elements = Potion.Compiler.compile(body, allocation)

      assert {:ld, :a, {:mem, allocation.cells.vx}} in elements
      assert {:bit, 7, :a} in elements
      assert Enum.any?(elements, &match?({:jp, :z, {:label, _}}, &1))
      refute Enum.any?(elements, &match?({:cp, :a, _}, &1))
    end

    test "both ends of the byte are reachable, and neither one past" do
      # -128 and 255 are the same 256 values read two ways, and a game is
      # allowed to name either end: 0x80 is the largest step backwards, 0xFF
      # the largest forwards. The boundary is stated because it is the one
      # place a range can be off by one and still look right everywhere else.
      assert Potion.Compiler.allocate(vx: -128).initial == %{vx: 0x80}
      assert Potion.Compiler.allocate(vx: 255).initial == %{vx: 0xFF}

      allocation = Potion.Compiler.allocate(vx: 0)

      for {written, byte} <- [{{:-, [], [128]}, 0x80}, {255, 0xFF}] do
        body = {:=, [], [{:vx, [], nil}, written]}
        assert {:ld, :a, byte} in Potion.Compiler.compile(body, allocation)
      end

      for outside <- [{:-, [], [129]}, 256] do
        body = {:=, [], [{:vx, [], nil}, outside]}

        assert_raise Potion.CompileError, ~r/outside a byte/, fn ->
          Potion.Compiler.compile(body, allocation)
        end
      end

      for outside <- [-129, 256] do
        assert_raise Potion.CompileError, ~r/initial value outside a byte/, fn ->
          Potion.Compiler.allocate(vx: outside)
        end
      end
    end

    test "equality takes a negative literal, since it orders nothing" do
      allocation = Potion.Compiler.allocate(vx: 0, hit: 0)
      condition = {:==, [], [{:vx, [], nil}, {:-, [], [1]}]}
      body = {:if, [], [condition, [do: {:=, [], [{:hit, [], nil}, 1]}]]}

      elements = Potion.Compiler.compile(body, allocation)

      assert {:cp, :a, 0xFF} in elements
    end
  end

  describe "several actors" do
    test "each one gets its own cells, side by side in the page" do
      addresses = Pair.addresses()

      assert addresses.leader_x == Potion.Runtime.actor_state()
      # The leader takes a cell and its flag; the follower starts after both.
      assert addresses.follower_x == Potion.Runtime.actor_state() + 2
    end

    test "both run every frame, and both draw" do
      {_pixels, _state, ram} = run_frames(Pair, 8)
      addresses = Pair.addresses()

      leader = Map.get(ram, addresses.leader_x)
      follower = Map.get(ram, addresses.follower_x)

      assert leader > 20, "the leader has not moved"
      assert follower == leader - 8, "the follower did not read this frame's value"

      assert [_y, _x, 0, 0] = oam(ram, 0)
      assert [_y2, _x2, 0, 0] = oam(ram, 1)
    end

    test "the order is the declaration order, and the follower sees the same frame" do
      # If the kernel called them the other way round, the follower would be
      # reading the leader's *previous* position and would trail by nine.
      {_pixels, _state, ram} = run_frames(Pair, 12)
      addresses = Pair.addresses()

      assert Map.get(ram, addresses.follower_x) ==
               Map.get(ram, addresses.leader_x) - 8
    end

    test "the kernel calls one slot per actor" do
      program = Pair.program()

      calls =
        program
        |> Enum.drop_while(&(&1 != {:label, :main_loop}))
        |> Enum.take_while(&(&1 != {:label, :dma_source}))
        |> Enum.filter(&match?({:call, _}, &1))

      assert calls == [
               {:call, {:label, :read_pad}},
               {:call, {:label, :play_music}},
               {:call, {:label, :play_harmony}},
               {:call, {:label, :play_bass}},
               {:call, {:label, :actor_0}},
               {:call, {:label, :actor_1}}
             ]
    end

    test "the two actors' labels do not collide" do
      addresses = Assembler.addresses(Pair.program(), origin: 0x0150)

      assert Map.has_key?(addresses, :potion_0_installed)
      assert Map.has_key?(addresses, :potion_1_installed)
      assert addresses.potion_0_installed != addresses.potion_1_installed
    end
  end

  describe "the background layer" do
    test "a square of the map points at the digit the game asked for" do
      {_pixels, _state, ram} = run_frames(Scoreboard, 8)
      addresses = Scoreboard.addresses()

      score = Map.get(ram, addresses.score)
      square = Potion.Runtime.background_address(2, 1)

      assert Map.get(ram, square) == Potion.Runtime.digits() + score
      assert score > 0, "the counter never advanced"
    end

    test "the digit is really drawn, and only where it was put" do
      {pixels, _state, _ram} = run_frames(Scoreboard, 8, render: true)
      lit = non_white(pixels)

      # Column 2, row 1 of the map is the 8x8 square at (16, 8).
      inside = MapSet.intersection(lit, box(16, 8))

      assert MapSet.size(inside) > 8, "nothing was drawn in the square"
      assert MapSet.subset?(lit, box(16, 8)), "ink outside the one square asked for"

      # And in the same black as the sprite's solid tile. Both planes of the
      # glyph carry the bitmap, which is colour 3; carrying only one would draw
      # a legible but grey digit, and "non-white" would not notice.
      shades =
        for {x, y} <- inside, into: MapSet.new(), do: :binary.at(pixels, y * 160 + x)

      assert shades == MapSet.new([3]), "the ink is not colour 3: #{inspect(shades)}"
    end

    test "the kernel's font sits behind its own two tiles" do
      assert Potion.Runtime.digits() == 2
      assert byte_size(Potion.Runtime.font_bytes()) == 10 * 16
    end

    test "a raw tile index goes in unchanged" do
      allocation = Potion.Compiler.allocate(n: 0)
      body = {:background, [], [0, 0, [tile: {:n, [], nil}]]}

      elements = Potion.Compiler.compile(body, allocation)
      square = Potion.Runtime.background_address(0, 0)

      assert {:ld, :a, {:mem, allocation.cells.n}} in elements
      assert {:ld, {:mem, square}, :a} in elements
      refute Enum.any?(elements, &match?({:add, :a, _}, &1))
    end

    test "a digit adds the font's base, and a literal one folds at compile time" do
      allocation = Potion.Compiler.allocate(n: 0)

      variable =
        Potion.Compiler.compile({:background, [], [0, 0, [digit: {:n, [], nil}]]}, allocation)

      assert {:add, :a, Potion.Runtime.digits()} in variable

      literal = Potion.Compiler.compile({:background, [], [0, 0, [digit: 7]]}, allocation)
      assert {:ld, :a, Potion.Runtime.digits() + 7} in literal
      refute Enum.any?(literal, &match?({:add, :a, _}, &1))
    end
  end

  describe "what the v0 refuses to compile" do
    test "an ordering against a negative literal, which would never be taken" do
      message =
        reject!("Rejected.SignedOrdering", "variables vx: 1", "if vx < -1, do: vx = 1")

      assert message =~ "ordering against a negative literal"
      assert message =~ "negative?(vx)"
      assert message =~ "never taken"
    end

    test "each of the four orderings refuses it, and neither equality does" do
      for op <- ["<", ">", "<=", ">="] do
        message =
          reject!(
            "Rejected.Ordering#{:erlang.phash2(op)}",
            "variables vx: 1",
            "if vx #{op} -1, do: vx = 1"
          )

        assert message =~ "ordering against a negative literal",
               "`#{op}` let a negative literal through"
      end

      # `==` and `!=` compile, and the game they make is a real one: `vx` starts
      # at -1, so the branch is taken on the first frame.
      for op <- ["==", "!="] do
        {[{module, _} | _], _stderr} =
          ExUnit.CaptureIO.with_io(:stderr, fn ->
            Code.compile_string("""
            defmodule Accepted.Equality#{:erlang.phash2(op)} do
              use Potion

              defactor :sign do
                variables vx: -1, hit: 0

                every_frame do
                  if vx #{op} -1, do: hit = 1
                end
              end
            end
            """)
          end)

        {_pixels, _state, ram} = run_frames(module, 5)

        expected = if op == "==", do: 1, else: 0
        assert Map.get(ram, module.addresses().hit) == expected
      end
    end

    test "a literal below -128, which no byte holds either way" do
      message = reject!("Rejected.TooNegative", "variables vx: 1", "vx = -129")

      assert message =~ "outside a byte"
      assert message =~ "-128 to 255"
    end

    test "an initial value below -128" do
      message = reject!("Rejected.NegativeInitial", "variables vx: -129", "vx = 1")

      assert message =~ "initial value outside a byte"
      assert message =~ "-128 to 255"
    end

    test "`negative?` of something that is not a variable" do
      message =
        reject!("Rejected.SignOfLiteral", "variables vx: 1", "if negative?(3), do: vx = 1")

      assert message =~ "condition outside the subset"
      assert message =~ "negative?"
    end

    test "an expression outside the subset" do
      message = reject!("Rejected.Multiplication", "variables x: 1", "x = x * 2")

      assert message =~ "outside the v0 subset"
      assert message =~ "x * 2"
      assert message =~ "x = x + 1"
    end

    test "a computation nested inside another" do
      message = reject!("Rejected.Nested", "variables x: 1, y: 2", "x = x + (y + 1)")

      assert message =~ "operand outside the subset"
      assert message =~ "one operation per sentence"
    end

    test "an unknown key" do
      message =
        reject!("Rejected.Key", "variables x: 1", "if pressed?(:turbo), do: x = x + 1")

      assert message =~ "unknown key: :turbo"
      assert message =~ ":select"
    end

    test "an undeclared variable" do
      message = reject!("Rejected.Ghost", "variables x: 1", "y = y + 1")

      assert message =~ "undeclared variable: :y"
      assert message =~ "Declared: :x (0xC100)"
      assert message =~ "variables y: 0"
    end

    test "an undeclared variable inside a sprite" do
      message =
        reject!("Rejected.SpriteGhost", "variables x: 1", "sprite(0, x: x, y: z, tile: 0)")

      assert message =~ "undeclared variable: :z"
    end

    test "two actors sharing a variable name" do
      source = """
      defmodule Rejected.SharedName do
        use Potion

        defactor :left do
          variables y: 10
          every_frame do
            sprite(0, x: 10, y: y, tile: 0)
          end
        end

        defactor :right do
          variables y: 20
          every_frame do
            sprite(1, x: 150, y: y, tile: 0)
          end
        end
      end
      """

      message = refuse_compile!(source)

      assert message =~ "already used by another actor"
      assert message =~ ":left"
      assert message =~ "left_y"
    end

    test "two actors with the same name" do
      source = """
      defmodule Rejected.SameActor do
        use Potion

        defactor :ball do
          variables a: 1
          every_frame do
            a = a + 1
          end
        end

        defactor :ball do
          variables b: 1
          every_frame do
            b = b + 1
          end
        end
      end
      """

      message = refuse_compile!(source)

      assert message =~ "two actors called :ball"
    end

    test "a background square outside the map" do
      message = reject!("Rejected.Square", "variables x: 1", "background(40, 0, tile: 0)")

      assert message =~ "background square outside the map"
      assert message =~ "32 by 32"
    end

    test "a background square with neither tile nor digit" do
      message = reject!("Rejected.Field", "variables x: 1", "background(0, 0, colour: 3)")

      assert message =~ "malformed `background`"
    end

    test "a sprite number outside the forty OAM entries" do
      message = reject!("Rejected.Oam", "variables x: 1", "sprite(40, x: x, y: 10, tile: 0)")

      assert message =~ "OAM entry out of range: 40"
      assert message =~ "0 to 39"
    end

    # A sprite number held in a cell used to be refused and is now the point: a
    # pool of bullets writes one OAM entry per instance, and which entry is
    # decided while the game runs. The address becomes `mirror + 4 * n`, four
    # being two doublings rather than a multiply the processor does not have.
    test "a sprite number held in a cell is worked out at run time" do
      allocation = Potion.Compiler.allocate(n: 0, px: 0)

      body =
        {:sprite, [], [{:n, [], nil}, [x: {:px, [], nil}, y: 10, tile: 0]]}

      elements = Potion.Compiler.compile(body, allocation)

      assert {:ld, :a, {:mem, allocation.cells.n}} in elements
      assert Enum.count(elements, &(&1 == {:add, :a, :a})) == 2
      assert {:ld, :hl, Potion.Runtime.oam_mirror()} in elements
      assert {:ld, {:mem, :de}, :a} in elements
    end

    test "a comparison against something that is neither variable nor byte" do
      message =
        reject!(
          "Rejected.Comparand",
          "variables x: 1",
          "if x > (1 + 1), do: x = x + 1"
        )

      assert message =~ "operand outside the subset"
    end

    test "a comparison against a value outside a byte" do
      message =
        reject!("Rejected.TooBig", "variables x: 1", "if x > 300, do: x = x + 1")

      assert message =~ "outside a byte"
    end

    test "a condition that is neither a key nor a comparison" do
      message =
        reject!("Rejected.Condition", "variables x: 1", "if x, do: x = x + 1")

      assert message =~ "condition outside the subset"
    end

    test "an actor without every_frame" do
      source = """
      defmodule Rejected.NoFrame do
        use Potion

        defactor :inert do
          variables x: 1
        end
      end
      """

      assert refuse_compile!(source) =~ "actor without `every_frame`"
    end

    test "an initial value that does not fit in a byte" do
      message = reject!("Rejected.TooBig", "variables x: 300", "x = x + 1")

      assert message =~ "initial value outside a byte"
    end

    test "an unknown statement in the actor's body" do
      source = """
      defmodule Rejected.Statement do
        use Potion

        defactor :chatty do
          IO.puts("hello")

          every_frame do
            sprite(0, x: 10, y: 10, tile: 0)
          end
        end
      end
      """

      assert refuse_compile!(source) =~ "unknown statement"
    end

    test "`variables` used outside a defactor" do
      source = """
      defmodule Rejected.Stray do
        use Potion
        variables x: 1
      end
      """

      assert refuse_compile!(source) =~ "outside a `defactor`"
    end
  end

  # ══ The harness ══════════════════════════════════════════════════════════════

  # `count` frames since boot; the last one rendered if asked for.
  defp run_frames(game, count, opts \\ []) do
    rom = game.rom()
    render? = Keyword.get(opts, :render, false)

    Enum.reduce(1..count, {<<>>, Screen.boot_state(rom), Screen.boot_ram(rom)}, fn n,
                                                                                   {_pixels,
                                                                                    state, ram} ->
      Screen.frame(state, rom, ram, render? and n == count)
    end)
  end

  # Further frames, from a state in flight and a RAM the outside world may just
  # have touched.
  defp frames(game, state, ram, count) do
    rom = game.rom()

    Enum.reduce(1..count, {state, ram}, fn _n, {state, ram} ->
      {_pixels, state, ram} = Screen.frame(state, rom, ram, false)
      {state, ram}
    end)
  end

  defp position(ram, addresses), do: {Map.get(ram, addresses.x), Map.get(ram, addresses.y)}

  defp oam(ram, entry), do: for(i <- 0..3, do: Map.get(ram, 0xFE00 + 4 * entry + i))

  defp non_white(pixels) do
    for i <- 0..(byte_size(pixels) - 1),
        :binary.at(pixels, i) != 0,
        into: MapSet.new(),
        do: {rem(i, 160), div(i, 160)}
  end

  defp box(x, y) do
    for line <- y..(y + 7), column <- x..(x + 7), into: MapSet.new(), do: {column, line}
  end

  # ── Compiling a game for real, and expecting it to be refused ───────────────

  # The refusal happens when the host module compiles: these tests therefore
  # compile text, the way `mix compile` would. A direct call into
  # `Potion.Compiler` would test the same exception, but not the path along which
  # a programmer meets it — and that path is the language's promise.
  defp reject!(module, declarations, statement) do
    refuse_compile!("""
    defmodule #{module} do
      use Potion

      defactor :offender do
        #{declarations}

        every_frame do
          #{statement}
        end
      end
    end
    """)
  end

  defp refuse_compile!(source) do
    error =
      assert_raise Potion.CompileError, fn ->
        ExUnit.CaptureIO.capture_io(:stderr, fn -> Code.compile_string(source) end)
      end

    error.message
  end
end
