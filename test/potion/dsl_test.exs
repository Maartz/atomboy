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
      assert {:label, :actor} in program

      addresses = Assembler.addresses(program, origin: 0x0150)

      assert addresses.init == 0x0150
      assert Map.has_key?(addresses, :actor)
      assert addresses.actor > addresses.main_loop

      # The compiler's labels, all prefixed: one per `if`, plus the one for the
      # installation.
      assert Map.has_key?(addresses, :potion_installed)

      for n <- 0..3, do: assert(Map.has_key?(addresses, :"potion_end_#{n}"))

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

  describe "what the v0 refuses to compile" do
    test "an expression outside the subset" do
      message = reject!("Rejected.Multiplication", "variables x: 1", "x = x * 2")

      assert message =~ "outside the v0 subset"
      assert message =~ "x * 2"
      assert message =~ "x = x + 1"
    end

    test "an addition of two variables — the v0 has no register policy" do
      message = reject!("Rejected.TwoVariables", "variables x: 1, y: 2", "x = x + y")

      assert message =~ "outside the v0 subset"
      assert message =~ "integer literal from 0 to 255"
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

    test "two actors in the same module" do
      source = """
      defmodule Rejected.TwoActors do
        use Potion

        defactor :first do
          every_frame do
            sprite(0, x: 10, y: 10, tile: 0)
          end
        end

        defactor :second do
          every_frame do
            sprite(1, x: 20, y: 20, tile: 0)
          end
        end
      end
      """

      message = refuse_compile!(source)

      assert message =~ "second actor"
      assert message =~ ":second"
      assert message =~ "has only one slot"
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

    test "an `if` with a branch the v0 does not compile" do
      message =
        reject!(
          "Rejected.Else",
          "variables x: 1",
          "if pressed?(:a), do: x = x + 1, else: x = x - 1"
        )

      assert message =~ "branch the v0 does not compile"
      assert message =~ "else"
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
