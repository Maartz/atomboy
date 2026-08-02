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
  takes two frames, the actor runs for the first time at the third one's vblank,
  and the DMA publishes its OAM at the next. We unroll five frames before looking
  at the state, six before looking at the screen.
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
      {_pixels, _state, ram} = run_frames(Drifter, 5)

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
      {_pixels, _state, ram} = run_frames(Rebound, 5)
      assert Map.get(ram, addresses.x) == 103
      assert Map.get(ram, addresses.vx) == 1

      # Past 120 the direction is reversed, and `x = x + vx` -- the very same
      # sentence -- now walks the other way. 121 was the far point, and by the
      # 25th frame the ball has come back two steps.
      {_pixels, _state, ram} = run_frames(Rebound, 25)
      assert Map.get(ram, addresses.x) == 119
      assert Map.get(ram, addresses.vx) == 0xFF, "vx should hold -1 in two's complement"
    end

    test "and turns around again at the other end, without ever leaving the court" do
      # 19 is reached at the 125th frame, and reversed on the spot.
      {_pixels, _state, ram} = run_frames(Rebound, 130)
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

    test "a sprite number that is not a literal" do
      message =
        reject!("Rejected.OamVariable", "variables n: 1", "sprite(n, x: 10, y: 10, tile: 0)")

      assert message =~ "is not a literal"
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
