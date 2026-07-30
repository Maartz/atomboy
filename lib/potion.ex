defmodule Potion.CompileError do
  @moduledoc """
  What the v0 cannot compile, said while the host module compiles.

  This exception is raised during the expansion of the `Potion` macros — that is,
  while `mix compile` is reading the game's file. A game that compiles is
  therefore a game every line of which has an equivalent in SM83 instructions;
  there is no such thing as "Potion crashing at run time" for this class of
  mistakes, because at run time there is nothing left but a cartridge.
  """

  defexception [:message]
end

defmodule Potion do
  @moduledoc """
  A game language that compiles into a cartridge.

  Potion is Elixir. You write a module, add it to the project, `mix compile`
  reads it — and out come 32 KB of bytes a Game Boy executes:

      defmodule MyGame do
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

      MyGame.rom()        # the ROM, binary, 32,768 bytes
      MyGame.program()    # the assembler program, for reading
      MyGame.addresses()  # where x and y live in WRAM

  Those eleven lines make a black square in the middle of the screen, which moves
  under your thumb. They do nothing else — and that is the whole point of the v0:
  that the entire chain should stand up, from the macro to the OAM, before it
  grows.

  ## The surface is Elixir, the semantics are the console's

  It is the language's only contract, and it must be taken literally. `x = x + 1`
  is written as in Elixir, reads as in Elixir, and does not mean the same thing:

    * `x` is not a binding, it is **a cell of WRAM**. The compiler gives it an
      address in the page the kernel reserves for the actor, and `x = x + 1`
      compiles into `LD A, (x)` / `ADD A, 1` / `LD (x), A`.
    * the arithmetic is **eight bits, and it wraps**. 255 + 1 makes 0, and no
      check catches it: there is no room in a frame to verify what the silicon
      already does.
    * an assignment is **an effect**, not a new value. Two `x = …` in one frame
      write the same cell twice, and the second one wins.

  None of this is a regrettable compromise. It is what a Game Boy game *is*, and
  a language claiming otherwise would be lying about the machine it drives — at
  the cost, sooner or later, of a frame lost to emulating semantics that do not
  apply.

  What does not translate is refused, and refused **at compile time**: `x = x *
  2` makes `mix compile` fail with a `Potion.CompileError` that shows the
  rejected AST and lists what the v0 can do. A ROM that compiles is a ROM every
  line of which exists in SM83.

  ## The lineage

  The idea is not new, and its precedent is a glorious one: GOOL, the language
  Andy Gavin wrote for *Crash Bandicoot* — a Lisp compiled to bytecode for the
  PlayStation, where every character was an actor with its own state and its own
  frame code. Naughty Dog did not write an engine with scripts on top; they wrote
  a language whose sentences *are* the game, and a compiler that makes them fit
  inside the console.

  Potion takes up the same shape — the actor, the named state, the code called
  once per frame — on a machine fifty times smaller, and from a host that already
  knows how to read trees: Elixir's macros do the work Gavin did with the macros
  of his Lisp.

  ## The actor

  A `defactor` declares three things, two of which are optional:

      defactor :hero do
        variables x: 80, y: 72    # the WRAM cells, and their starting values
        every_frame do            # the code called once per frame, by the kernel
          …
        end
      end

  The initial values are not laid down "at startup": an actor has no startup, the
  kernel calls it once per frame and that is all. The compiler therefore
  allocates one extra cell — the "installed" flag, which the game neither
  declares nor ever sees — and lets the first frame recognise that it is the
  first. `Potion.Compiler` details that pattern.

  The v0 accepts **only one actor per module**: the kernel's scheduler has a
  single slot, and a second `defactor` would compile a game half of which would
  never run. The day the scheduler has several, the macro will accept them
  without the surface changing.

  ## What the v0 compiles

      x = 5                              a constant into a cell
      x = y                              one cell into another
      x = x + 1                          eight bits, which wrap
      x = y - 3

      if pressed?(key), do: …            :right :left :up :down :a :b :select :start
      if pressed?(:a) do                 a block, several statements
        x = x + 1
        y = y - 1
      end

      sprite(n, x: …, y: …, tile: …)    entry n of the mirror OAM, n a literal from 0 to 39

  `sprite` writes into the kernel's mirror OAM — never into the real OAM, which
  is only writable during the vblank. The hardware offsets (Y+16, X+8) are added
  by the compiler: `sprite(0, x: 80, y: 72, …)` puts the sprite's top-left corner
  at pixel (80, 72) of the screen, and not sixteen lines further down. The
  attributes are zeroed.

  ## The modules

    * `Potion.Compiler` — the restricted AST into an assembler fragment, and all
      the refusal messages.
    * `Potion.Runtime` — the runtime: the init, the vblank, the DMA, the pad, the
      loop that calls the actor.
    * `Potion.Assembler` — the tuples into bytes.
    * `Potion.ROM` — the 32 KB cartridge, header and checksums included.
  """

  alias Potion.Assembler
  alias Potion.Compiler
  alias Potion.CompileError
  alias Potion.Runtime

  # Fifteen characters is what the cartridge header holds.
  @title_max 15

  @doc """
  Opens the language inside the host module: `defactor` and its two words.
  """
  defmacro __using__(_opts) do
    quote do
      import Potion, only: [defactor: 2, variables: 1, every_frame: 1]
    end
  end

  @doc """
  Declares the module's actor, and gives it `rom/0`, `program/0`, `addresses/0`.

  All the work happens here, during expansion: the body is read as a tree, the
  variables are allocated, the `every_frame` body is compiled, and the complete
  program is assembled once to check that it fits. What survives all that is a
  list of tuples engraved into the module — the generated functions no longer
  compile anything, they return a value.
  """
  defmacro defactor(name, do: body) do
    module = __CALLER__.module
    name = name!(name, module)
    unique!(module, name)

    {declarations, every_frame} = split!(body, name)
    allocation = Compiler.allocate(declarations)
    fragment = Compiler.compile(every_frame, allocation)
    verify!(fragment, name)

    Module.put_attribute(module, :potion_actor, name)

    quote do
      @doc """
      The complete assembler program — the kernel, then the actor `#{inspect(unquote(name))}`.

      In the `Potion.Assembler` format: a list of tuples, which can be read,
      sliced, or passed to `Potion.Assembler.addresses/2` to find out where
      everything landed.
      """
      def program do
        Potion.Runtime.program(unquote(Macro.escape(fragment)))
      end

      @doc """
      The ROM, 32,768 bytes, ready to burn or to hand to `Atomboy.Screen`.
      """
      def rom do
        Potion.ROM.build(program(),
          vblank: :vblank,
          title: unquote(title(module))
        )
      end

      @doc """
      Where the game's variables live, in WRAM.

      A Potion game has no variables in the BEAM sense: it has cells. Here they
      are, for whoever wants to read them from the outside — an emulator, a test,
      a debugger.
      """
      def addresses do
        unquote(Macro.escape(allocation.cells))
      end
    end
  end

  @doc """
  The game's WRAM cells and their starting values.

      variables x: 80, y: 72

  Only used inside a `defactor`, where it is not executed but read: `defactor`
  takes the tree as it stands and hands it to the compiler.
  """
  defmacro variables(declarations) do
    outside_actor!("variables", Macro.to_string({:variables, [], [declarations]}))
  end

  @doc """
  The code called once per frame, by the kernel's loop.

      every_frame do
        if pressed?(:right), do: x = x + 1
        sprite(0, x: x, y: y, tile: 0)
      end

  Only used inside a `defactor`. See `Potion` for what the v0 accepts in there.
  """
  defmacro every_frame(_blocks) do
    outside_actor!("every_frame", "every_frame do … end")
  end

  # ══ Reading the actor's tree ═════════════════════════════════════════════════

  defp name!(name, _module) when is_atom(name), do: name

  defp name!(other, module) do
    raise CompileError, """
    actor name that is not an atom, in #{inspect(module)}:

        #{Macro.to_string(other)}

    Rejected AST: #{inspect(other)}

    The form is `defactor :hero do … end`. The name is written on the spot, like \
    a function's — it is not computed.
    """
  end

  defp unique!(module, name) do
    case Module.get_attribute(module, :potion_actor) do
      nil ->
        :ok

      first ->
        raise CompileError, """
        second actor in #{inspect(module)}: #{inspect(name)}, after #{inspect(first)}.

        The v0 scheduler has only one slot — the kernel makes a single `CALL` per \
        frame, and #{inspect(first)} occupies it. #{inspect(name)} would never \
        run, which is the worst possible way of not working.

        Until there is a multi-slot scheduler: one actor per module, and one ROM \
        per module.
        """
    end
  end

  # The body of a `defactor`: at most one `variables`, exactly one `every_frame`,
  # and nothing else. Neither is expanded — they are forms this function
  # recognises, not code that runs.
  defp split!(body, name) do
    body
    |> statements()
    |> Enum.reduce({nil, nil}, fn statement, {declarations, every_frame} ->
      case statement do
        {:variables, _, _} when declarations != nil ->
          duplicate!("variables", name)

        {:every_frame, _, _} when every_frame != nil ->
          duplicate!("every_frame", name)

        {:variables, _, [decl]} ->
          {decl, every_frame}

        {:every_frame, _, [[do: block]]} ->
          {declarations, {:body, block}}

        other ->
          raise CompileError, """
          unknown statement in `defactor #{inspect(name)}`:

              #{Macro.to_string(other)}

          Rejected AST: #{inspect(other)}

          An actor's body contains two forms and no others:

              variables x: 80, y: 72
              every_frame do … end

          The game's code goes into `every_frame`; that is what the kernel calls.
          """
      end
    end)
    |> case do
      {_declarations, nil} ->
        raise CompileError, """
        actor without `every_frame`: #{inspect(name)}

        An actor is code called once per frame. Without `every_frame`, the kernel \
        would be calling a `RET` sixty times a second and the screen would stay \
        empty.

            defactor #{inspect(name)} do
              every_frame do
                sprite(0, x: 80, y: 72, tile: 0)
              end
            end
        """

      {declarations, {:body, block}} ->
        {declarations || [], block}
    end
  end

  defp statements({:__block__, _, list}), do: list
  defp statements(nil), do: []
  defp statements(single), do: [single]

  defp duplicate!(word, name) do
    raise CompileError, """
    `#{word}` written twice in `defactor #{inspect(name)}`.

    An actor has a single state and a single frame body. Two `#{word}` would not \
    say which one counts — and the v0 would rather refuse than choose on your \
    behalf.
    """
  end

  # The dry run of the assembly: is the fragment a program? The kernel checks the
  # closing RET, the assembler the labels and the jump ranges. Doing it here
  # rather than on the first call to `rom/0` is the whole benefit of a compiled
  # language: an `if` whose block overshoots the range of a JR shows up in `mix
  # compile`, not three weeks later on a flashcart.
  defp verify!(fragment, name) do
    Assembler.assemble(Runtime.program(fragment), origin: 0x0150)
    :ok
  rescue
    error in ArgumentError ->
      reraise CompileError,
              [
                message: """
                the actor #{inspect(name)} does not assemble.

                #{error.message}

                The body compiled, but the fragment that came out of it is not a \
                valid program. If the message speaks of a jump out of range, it is \
                an `if` block that is too big: JR only jumps 127 bytes, and the v0 \
                knows nothing but JR.
                """
              ],
              __STACKTRACE__
  end

  defp title(module) do
    module
    |> Module.split()
    |> List.last()
    |> String.upcase()
    |> String.slice(0, @title_max)
  end

  defp outside_actor!(word, form) do
    raise CompileError, """
    `#{word}` used outside a `defactor`.

    This form is not code: it is part of an actor's declaration, which `defactor` \
    reads from its tree. It only makes sense here:

        defactor :hero do
          #{form}
        end
    """
  end
end
