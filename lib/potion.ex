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
            if negative?(vx), do: vx = 1       is the sign bit set

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

  A module may hold **several actors**. The kernel gives each one a slot and
  calls them in declaration order, every frame, with nothing in between -- so an
  actor that writes a cell another one reads will be read in that order, always.

  Their cells share one namespace: `addresses/0` returns the whole game's, and
  two actors cannot both declare a `y`. In exchange, any actor can name any
  cell, whichever actor declared it and whatever the order -- a ball reads the
  paddles, and the paddles read the ball.

  ## What the v0 compiles

      background(2, 1, digit: score)     a digit on the background layer
      background(0, 0, tile: 0)          any tile, by index

      vx = -1                            a negative literal, two's complement
      vx = -vx                           and the sentence a bounce is made of

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
      import Potion, only: [defactor: 2, variables: 1, every_frame: 1, tiles: 1]

      @before_compile Potion
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

    slot = length(actors(module))

    allocation =
      Compiler.allocate(declarations, base: next_base(module), prefix: "potion_#{slot}")

    shared_names!(module, allocation, name)

    Module.put_attribute(
      module,
      :potion_actors,
      actors(module) ++ [{name, allocation, every_frame}]
    )

    :ok
  end

  @doc """
  Brings a drawing into the game, and gives its tiles names.

      tiles from: "art/pong.png", names: [:ball, :paddle]

  The file is read **here**, while the host module compiles: the sheet is cut
  into 8x8 tiles in reading order — left to right, then down — and the bytes are
  laid into the cartridge, where the kernel copies them into VRAM at startup.
  Nothing about the drawing survives into the running game except sixteen bytes
  a tile.

  `names` are handed out in that same order, and there may be fewer names than
  tiles: a sheet can carry scenery nobody needs to name. More names than tiles
  is refused, because it can only mean the sheet is not the one that was meant.

  The path is relative to the file that declares it, so a game and its art
  travel together — `games/pong.exs` looks for `games/art/pong.png`.

  The drawing is registered with the compiler as an external resource, so
  editing the PNG recompiles the module. Without that, a redrawn sprite would
  not appear until something else in the file changed, which is a confusing
  half-hour the first time it happens.
  """
  defmacro tiles(options) do
    module = __CALLER__.module
    options = tile_options!(options, module)

    path = Path.expand(options[:from], Path.dirname(__CALLER__.file))
    cut = Potion.Tiles.read!(path)
    names = options[:names] || []

    if length(names) > length(cut) do
      raise CompileError, """
      #{length(names)} names for #{length(cut)} tiles in #{Path.relative_to_cwd(path)}.

      Names are handed to tiles in reading order and there are not enough to go \
      round, which means this is not the sheet the names were written for.
      """
    end

    Module.put_attribute(module, :external_resource, path)

    Module.put_attribute(module, :potion_art, %{
      bytes: Enum.join(cut),
      names: names |> Enum.with_index() |> Map.new()
    })

    :ok
  end

  defp tile_options!(options, module) do
    with true <- Keyword.keyword?(options),
         path when is_binary(path) <- options[:from],
         names when is_list(names) or is_nil(names) <- options[:names] do
      unless Module.get_attribute(module, :potion_art) == nil do
        raise CompileError, """
        this module declares `tiles` twice.

        A cartridge has one sheet. Put every tile the game draws on it — the \
        names are what tell them apart, and there is room for 244.
        """
      end

      options
    else
      _ ->
        raise CompileError, """
        malformed `tiles`: #{Macro.to_string(options)}

        It takes the drawing and, optionally, the names its tiles answer to:

            tiles from: "art/pong.png", names: [:ball, :paddle]
        """
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    case actors(env.module) do
      [] ->
        :ok

      actors ->
        # Compiling here rather than in `defactor` is what lets an actor name a
        # cell belonging to another one. At `defactor` time only the actors
        # declared *above* exist, so a ball could see the paddles and the paddles
        # could never see the ball -- a rule nobody would remember. By the time
        # the module closes, every cell is known, and reading is symmetric.
        cells =
          Enum.reduce(actors, %{}, fn {_name, allocation, _body}, acc ->
            Map.merge(acc, allocation.cells)
          end)

        art = Module.get_attribute(env.module, :potion_art) || %{bytes: <<>>, names: %{}}

        fragments =
          Enum.map(actors, fn {name, allocation, body} ->
            fragment =
              Compiler.compile(body, %{allocation | cells: cells, tiles: art.names})

            verify!(fragment, name, art.bytes)
            fragment
          end)

        quote do
          @doc """
          The complete assembler program -- the kernel, then each actor in turn.

          In the `Potion.Assembler` format: a list of tuples, which can be read,
          sliced, or passed to `Potion.Assembler.addresses/2` to find out where
          everything landed.
          """
          def program do
            Potion.Runtime.program(
              unquote(Macro.escape(fragments)),
              unquote(Macro.escape(art.bytes))
            )
          end

          @doc """
          The ROM, 32,768 bytes, ready to burn or to hand to `Atomboy.Screen`.
          """
          def rom do
            Potion.ROM.build(program(),
              vblank: :vblank,
              title: unquote(title(env.module))
            )
          end

          @doc """
          Where the game's variables live, in WRAM.

          A Potion game has no variables in the BEAM sense: it has cells. Here
          they are -- every actor's, in one map, which is why two actors cannot
          share a variable name.
          """
          def addresses do
            unquote(Macro.escape(cells))
          end
        end
    end
  end

  # Declaration order, which is also the order the kernel calls them in. The
  # list is held whole rather than accumulated: an `accumulate: true` attribute
  # comes back reversed, and reversing it at every read is one more place for
  # the scheduling order to go quietly wrong.
  defp actors(module), do: Module.get_attribute(module, :potion_actors) || []

  # Each actor takes its slice of the page, one after another.
  defp next_base(module) do
    case actors(module) do
      [] -> Runtime.actor_state()
      list -> list |> List.last() |> elem(1) |> Compiler.next_free()
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
    if Enum.any?(actors(module), fn {taken, _allocation, _fragment} -> taken == name end) do
      raise CompileError, """
      two actors called #{inspect(name)} in #{inspect(module)}.

      The name is what the game calls a slot; two of them would not say which \
      one the kernel calls first, nor which cells belong to which.
      """
    end
  end

  # Every actor's variables end up in one `addresses/0`, so a name taken twice
  # would hide a cell rather than clash. Better said here, while the second
  # declaration is still on screen.
  defp shared_names!(module, allocation, name) do
    clashes =
      Enum.flat_map(actors(module), fn {other, other_allocation, _fragment} ->
        for {variable, _address} <- other_allocation.cells,
            Map.has_key?(allocation.cells, variable),
            do: {variable, other}
      end)

    case clashes do
      [] ->
        :ok

      taken ->
        raise CompileError, """
        variable name already used by another actor, in #{inspect(name)}: \
        #{Enum.map_join(taken, ", ", fn {variable, other} -> "#{inspect(variable)} (#{inspect(other)})" end)}

        A game's cells all share one `addresses/0`, so names are unique across \
        the whole game, not merely within an actor. Two paddles want `left_y` \
        and `right_y` rather than a `y` each.
        """
    end
  end

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
  # language: a fragment that is not a program shows up in `mix compile`, not
  # three weeks later on a flashcart.
  defp verify!(fragment, name, art) do
    Assembler.assemble(Runtime.program(fragment, art), origin: 0x0150)
    :ok
  rescue
    error in ArgumentError ->
      reraise CompileError,
              [
                message: """
                the actor #{inspect(name)} does not assemble.

                #{error.message}

                The body compiled, but the fragment that came out of it is not a \
                valid program. An `if` block of any size is fine — every jump that \
                leaves one is absolute — so a jump out of range here is a bug in \
                the compiler and not in the game.
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
