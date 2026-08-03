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

  ## What Potion compiles

  The whole surface, and there is no more of it than this.

  ### State

      variables x: 80, vx: -1            cells of WRAM, and their first values
      variables bullets: [0, 0, 0, 0]    an array: consecutive cells, one name

      bullets[2] = 5                     a literal index is worked out here
      bullets[n] = bullets[n] + 1        one held in a cell, at run time

      defactor :bullet, count: 4 do      one declaration, four instances
        …                                its names mean *this* instance's
        sprite(me, x: bx, …)             and `me` says which one
      end

      x = 5                              a constant into a cell
      x = y                              one cell into another
      x = x + 1                          eight bits, which wrap
      x = y - 3
      x = x + vy                         a cell on the right-hand side too
      vx = -vx                           and the sentence a bounce is made of
      x = random(16)                     0..15 — the bound a power of two, 2..256

      x = y * 10                         unrolled at compile time; wraps like `+`
      h = div(score, 100)                the quotient, and rem(score, 10) the
                                         rest — a literal divisor, never zero;
                                         `/` is refused: a byte has no halves

  ### Asking

      if pressed?(:right), do: …         :right :left :up :down :a :b :select :start
      if negative?(vx), do: …            the sign bit, which ordering cannot ask about
      if y > 140, do: …                  == != < > <= >=, against a literal or a cell
      if a and b, do: …                  `and` is free, `or` costs one jump
      if touching?(:wall, x, y), do: …   which tile of the room the pixel is on
      if going_down == 1, do: …, else: … two sentences instead of one
      if pressed?(:a) do … end           a block, several statements

  ### Showing

      sprite(n, x: …, y: …, tile: …)     entry n of the mirror OAM, n a literal 0..39
      sprite(0, …, flip: :x)             mirrored — :x, :y or :both; a facing
                                         that changes is an `if` with two sprites
      background(2, 1, digit: score)     a digit on the background layer
      background(0, 0, tile: :wall)      a tile, by name or by index
      text(3, 7, "PRESS START")          words, turned into stores at compile time

      room :cave, @drawing,              a screen or more: 20×18 up to 32×32,
        tiles: %{?# => :wall}            each character a tile of the sheet
      show(:cave)                        painted whole, behind one dark frame

      scroll(cx, cy)                     the camera's corner in the room, in
                                         pixels — applied at the vblank, so the
                                         panel sees one camera per frame;
                                         sprites follow by `sx = x - cx`

      tiles from: "art/pong.png",        a drawing, cut into tiles and named
        names: [:ball, :paddle]

  ### Screens, sound, and saying a thing once

      state :title do                    an actor made of states instead of one body
        on_enter do … end                once, on the frame the state is entered
        every_frame do … end             every frame it stays in
      end

      become(:playing)                   and the frame ends there
      fade(0..3)                         the picture, down to a black screen

      beep(:c5)                          a note, :c2 to :b7, sharps as `cs`
      noise(:hit)                        a knock: :tick :hit :thud :boom

      music :theme, "c4 . e4 . g4 -"     a tune, declared beside the actors
      play(:theme)                       started once; the kernel keeps the beat
      silence()                          and stopped

      routine :bounce do … end           written once
      bounce()                           called from anywhere in the actor

  `sprite` writes into the kernel's mirror OAM — never into the real OAM, which
  is only writable during the vblank. The hardware offsets (Y+16, X+8) are added
  by the compiler: `sprite(0, x: 80, y: 72, …)` puts the sprite's top-left corner
  at pixel (80, 72) of the screen, and not sixteen lines further down. `flip:`
  sets the attribute byte's mirror bits; the rest of it is zeroed — and it is
  written on every call, so a sprite that stops saying `flip:` stops being
  flipped.

  ## The loop

      ELIXIR_ERL_OPTIONS="-noinput" mix atomboy.live games/pong.exs

  Plays the game and watches the file: save it, and the running console picks up
  the new cartridge without restarting. The ball keeps its position, the cells
  keep their values, and what you changed is different on the next frame. It is
  the trick GOAL played on the PlayStation, and it is nearly free here because
  `Atomboy.Screen.frame/4` takes the ROM as an argument every frame.

  Two things a reload cannot carry: the cells, since `variables` is an
  allocation and a new line moves the addresses; and the screen, since a title
  painted in `on_enter` has already been painted. `Mix.Tasks.Atomboy.Live` says
  more.

  `docs/pipeline.md` follows one line of a game from Elixir down to the bytes it
  becomes.

  ## The modules

    * `Potion.Compiler` — the restricted AST into an assembler fragment, and all
      the refusal messages.
    * `Potion.Runtime` — the kernel: the init, the vblank, the DMA, the pad, the
      tiles, the alphabet, and the loop that calls each actor in turn.
    * `Potion.Assembler` — the tuples into bytes.
    * `Potion.ROM` — the 32 KB cartridge, header and checksums included.
    * `Potion.PNG` and `Potion.Tiles` — a drawing down to its pixels, and pixels
      into the console's two-byte-a-row tiles.
    * `Potion.Music` — a line of notation into the bytes a tune is made of;
      `docs/sound.md` is the whole sound story on one page.
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
      import Potion,
        only: [
          defactor: 2,
          defactor: 3,
          variables: 1,
          every_frame: 1,
          tiles: 1,
          state: 2,
          on_enter: 1,
          routine: 2,
          room: 2,
          room: 3,
          music: 2,
          music: 3
        ]

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
    declare!(name, [], body, __CALLER__.module)
  end

  @doc """
  The same, in several instances: one declaration, `count:` sets of cells.

      defactor :bullet, count: 4 do
        variables bx: 0, live: 0

        every_frame do
          if live == 1, do: bx = bx + 2
          sprite(me, x: bx, y: 60, tile: 0)
        end
      end

  The body never says which instance it is. Each of the actor's own names
  becomes `count` consecutive cells and the compiler subscripts them by `me`,
  which the body may also read — that is how each instance reaches its own OAM
  entry. Another actor sees those same names as ordinary arrays, and writing
  into one is how anything gets spawned.
  """
  defmacro defactor(name, opts, do: body) do
    declare!(name, opts, body, __CALLER__.module)
  end

  defp declare!(name, opts, body, module) do
    name = name!(name, module)
    count = count!(opts, name)
    unique!(module, name)

    {declarations, behaviour, routines} = split!(body, name)

    slot = length(actors(module))

    allocation =
      Compiler.allocate(declarations,
        base: next_base(module),
        prefix: "potion_#{slot}",
        count: count,
        states: state_names(behaviour),
        routines: Enum.map(routines, fn {name, _} -> name end),
        # Empty on purpose: the tunes are trees until `__before_compile__`, and
        # this allocation's tunes are overridden there anyway -- the rebuilt one
        # is what fragments compile against.
        tunes: []
      )

    shared_names!(module, allocation, name)

    Module.put_attribute(
      module,
      :potion_actors,
      actors(module) ++ [{name, allocation, behaviour, routines}]
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
          Enum.reduce(actors, %{}, fn {_name, allocation, _behaviour, _routines}, acc ->
            Map.merge(acc, allocation.cells)
          end)

        # The lengths travel with the addresses. Without them a pool's cells
        # would be visible to another actor as a name it could not subscript --
        # and reaching into a pool from outside is how anything gets spawned.
        arrays =
          Enum.reduce(actors, %{}, fn {_name, allocation, _behaviour, _routines}, acc ->
            Map.merge(acc, allocation.arrays)
          end)

        art = Module.get_attribute(env.module, :potion_art) || %{bytes: <<>>, names: %{}}

        screens =
          Enum.map(rooms(env.module), fn {name, ascii, opts} ->
            {name, compiled_room!(name, ascii, opts, art.names, env)}
          end)

        songs =
          Enum.map(tunes(env.module), fn {name, notation, opts} ->
            {name, compiled_tune!(name, notation, opts, env)}
          end)

        fragments =
          Enum.map(actors, fn {name, allocation, behaviour, routines} ->
            allocation = %{
              allocation
              | cells: cells,
                arrays: arrays,
                tiles: art.names,
                tunes: Map.new(songs, &described/1),
                rooms: MapSet.new(screens, fn {name, _bytes} -> name end)
            }

            fragment =
              case behaviour do
                {:body, body} ->
                  Compiler.compile(body, allocation, routines)

                {:states, states} ->
                  Compiler.compile_machine(states, allocation, routines)
              end

            verify!(fragment, name, art.bytes, songs, screens)
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
              unquote(Macro.escape(art.bytes)),
              unquote(Macro.escape(songs)),
              unquote(Macro.escape(screens))
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

  @doc """
  One of an actor's states. Only inside a `defactor`, and never on its own.

  Like `variables` and `every_frame`, this exists so that writing it in the wrong
  place says so. Inside `defactor` the body is read as a tree and never expanded,
  so this function is not the one that runs — `Potion.Compiler` is.
  """
  defmacro state(_name, _blocks) do
    outside_actor!("state", "state :title do … end")
  end

  @doc """
  A state's entry code: run once, on the frame the state is entered.
  """
  defmacro on_enter(_blocks) do
    outside_actor!("on_enter", "on_enter do … end")
  end

  @doc """
  A block written once inside an actor and called by name from several places.
  """
  defmacro routine(_name, _blocks) do
    outside_actor!("routine", "routine :bounce do … end")
  end

  @doc """
  A tune, declared beside the actors and started with `play(:name)`.

      music :theme, "c4 . e4 . g4 . c5 . . ."
      music :hurry, "c5 e5 c5 e5", beat: 4
      music :song, [lead: "c5 [e5 g5] | c6 .", harmony: "e4 g4 | c5 .", bass: "c2 . | g1 ."],
        beat: 10, duty: :eighth, gap: 3, vibrato: :gentle, envelope: :pluck

      @motif "c4 e4 g4 ."
      music :loop, @motif <> " " <> @motif

  One line of text is the lead alone, on channel 1. `harmony:` is channel 2 and
  `bass:` the wave channel, which counts its period twice as slowly and so
  reaches an octave lower — `c1` is a note there and not on the lead.

  `beep` is also on channel 2, so a sound effect takes the harmony's voice for as
  long as it lasts and the harmony comes back at its next step. That is not a
  clash to be fixed but what a Game Boy sounds like: four channels, and a game
  with more than four things to say.

  `vibrato:` is `:none`, `:gentle` or `:deep`: the kernel rewrites the pitch of
  a sounding note every frame, with the trigger bit clear so it bends rather
  than starting again. It reaches the two pulses and not the bass, since the
  register holds a period and the same deviation is inaudible down there.

  `duty:` is which square the lead is — `:eighth`, `:quarter` or `:half`, the
  fraction of each period the wave is high, and the difference between one
  instrument and another. `gap:` ends every note that many frames early, which
  is what turns notes running into one another into notes with a rhythm.

  Compiled while the module compiles — in `__before_compile__`, so a motif kept
  in a module attribute is already written by the time it is read — into the
  bytes the cartridge carries; `Potion.Music` sets out the notation and the
  format. The kernel reads a step a frame, so a game starts a tune once and
  never feeds it.
  """
  defmacro music(name, notation, opts \\ []) do
    module = __CALLER__.module
    name = literal_name!(name, module)

    if Enum.any?(tunes(module), fn {taken, _notation, _opts} -> taken == name end) do
      raise CompileError, """
      two tunes called #{inspect(name)} in #{inspect(module)}.

      `play` names one of them, and two with one name is a question with no answer.
      """
    end

    # The notation is kept as a tree and compiled in `__before_compile__`, not
    # here, and the delay is load-bearing: a module's body is macro-expanded
    # first and evaluated after, so at this moment an `@motif` two lines up has
    # not been written yet -- read now, every attribute is `nil`. By the time
    # `__before_compile__` runs the body has been evaluated, and a motif is a
    # lookup away.
    Module.put_attribute(module, :potion_tunes, tunes(module) ++ [{name, notation, opts}])

    :ok
  end

  @doc """
  A screen, drawn where it is declared.

      room :clearing,
        \"\"\"
        ####################
        #..................#
        ...eighteen rows...
        ####################
        \"\"\",
        tiles: %{?# => :wall, ?. => :grass}

  Twenty columns by eighteen rows -- the panel, exactly. A space is the empty
  tile without being declared; every other character is named by `tiles:`, as a
  name from the game's sheet or a bare index. `show(:clearing)` paints it: the
  kernel turns the panel off, copies the 360 bytes, and turns it back on -- one
  dark frame, which is what a room change has always looked like.

  Like a tune, the drawing is kept as a tree and compiled in
  `__before_compile__`, so a room may live in a module attribute and a set of
  them may be stitched with ordinary Elixir.
  """
  defmacro room(name, ascii, opts \\ []) do
    module = __CALLER__.module
    name = literal_name!(name, module)

    if Enum.any?(rooms(module), fn {taken, _ascii, _opts} -> taken == name end) do
      raise CompileError, """
      two rooms called #{inspect(name)} in #{inspect(module)}.

      `show` names one of them, and two with one name is a question with no answer.
      """
    end

    Module.put_attribute(module, :potion_rooms, rooms(module) ++ [{name, ascii, opts}])

    :ok
  end

  defp rooms(module), do: Module.get_attribute(module, :potion_rooms) || []

  defp compiled_room!(name, ascii, opts, art, env) do
    {ascii, opts} =
      try do
        {ascii, _} = ascii |> attributes(env) |> Code.eval_quoted([], env)
        {opts, _} = opts |> attributes(env) |> Code.eval_quoted([], env)
        {ascii, opts}
      rescue
        error ->
          raise CompileError, """
          the room #{inspect(name)}'s drawing could not be worked out while compiling:

              #{Exception.message(error) |> String.split("\n") |> hd()}

          A room is built when the module compiles, so its drawing has to be \
          reachable then: a string, a module attribute, or an expression of those.
          """
      end

    unless is_binary(ascii) do
      raise CompileError, """
      the room #{inspect(name)} is drawn as a block of text, and this is not one: \
      #{inspect(ascii)}
      """
    end

    Compiler.room!(name, ascii, Keyword.get(opts, :tiles, %{}), art)
  end

  defp tunes(module), do: Module.get_attribute(module, :potion_tunes) || []

  # The notation is *evaluated*, not pattern-matched: the surface is Elixir,
  # and Elixir already has the pattern language a tune wants -- module
  # attributes for motifs, `<>` to chain them, `Enum.join` for lists. A
  # `defpattern` of our own would be the first place this project doubled the
  # host instead of using it.
  #
  # `@motif` is resolved by walking the tree rather than by the eval: inside
  # `Code.eval_quoted` the `@` expands against a `__MODULE__` that is no longer
  # there, and dies as an `ArgumentError` three layers down. Here the module is
  # still open and every attribute the body set is a lookup away.
  defp compiled_tune!(name, notation, opts, env) do
    {notation, opts} =
      try do
        {notation, _} = notation |> attributes(env) |> Code.eval_quoted([], env)
        {opts, _} = opts |> attributes(env) |> Code.eval_quoted([], env)
        {notation, opts}
      rescue
        error ->
          raise CompileError, """
          the tune #{inspect(name)}'s notation could not be worked out while compiling:

              #{Exception.message(error) |> String.split("\n") |> hd()}

          A tune is built when the module compiles, so its notation has to be \
          reachable then: a string, a module attribute, or an expression of those.

              @motif "c4 e4 g4 ."
              music :song, [lead: @motif <> " " <> @motif]

          A plain variable from the module body is out of reach -- a macro never \
          sees bindings. Make it an attribute.
          """
      end

    unless is_binary(notation) or Keyword.keyword?(notation) do
      raise CompileError, """
      the tune #{inspect(name)} is written as a line of text, or as its voices: \
      #{inspect(notation)}

          music :theme, "c4 . e4 . g4 ."
          music :theme, lead: "c4 . e4 .", bass: "c2 . . ."
      """
    end

    Potion.Music.compile!(notation, name, opts)
  end

  defp attributes(ast, env) do
    Macro.prewalk(ast, fn
      {:@, _, [{attribute, _, context}]} when is_atom(attribute) and is_atom(context) ->
        Macro.escape(Module.get_attribute(env.module, attribute))

      node ->
        node
    end)
  end

  # What `play` needs to know about a tune: which voices it carries, which
  # square its pulses are, and how a note carries its volume. The bytes stay
  # with the kernel.
  defp described({name, voices}) do
    {name,
     %{
       harmony?: voices.harmony != <<>>,
       bass?: voices.bass != <<>>,
       duty: voices.duty,
       vibrato: voices.vibrato,
       envelope: voices.envelope
     }}
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
    if Enum.any?(actors(module), fn {taken, _allocation, _behaviour, _routines} ->
         taken == name
       end) do
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
      Enum.flat_map(actors(module), fn {other, other_allocation, _behaviour, _routines} ->
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
    {declarations, every_frame, states, routines} =
      body
      |> statements()
      |> Enum.reduce({nil, nil, [], []}, fn statement,
                                            {declarations, every_frame, states, routines} ->
        case statement do
          {:variables, _, _} when declarations != nil ->
            duplicate!("variables", name)

          {:every_frame, _, _} when every_frame != nil ->
            duplicate!("every_frame", name)

          {:variables, _, [decl]} ->
            {decl, every_frame, states, routines}

          {:every_frame, _, [[do: block]]} ->
            {declarations, block, states, routines}

          {:state, _, [state_name, [do: block]]} ->
            {declarations, every_frame, states ++ [state!(state_name, block, name, states)],
             routines}

          {:routine, _, [routine_name, [do: block]]} ->
            {declarations, every_frame, states,
             routines ++ [routine!(routine_name, block, name, routines)]}

          other ->
            raise CompileError, """
            unknown statement in `defactor #{inspect(name)}`:

                #{Macro.to_string(other)}

            Rejected AST: #{inspect(other)}

            An actor's body contains four forms and no others:

                variables x: 80, y: 72
                every_frame do … end
                state :title do … end
                routine :bounce do … end

            The game's code goes into `every_frame` — either one for the whole \
            actor, or one inside each `state`.
            """
        end
      end)

    cond do
      every_frame != nil and states != [] ->
        raise CompileError, """
        the actor #{inspect(name)} has both an `every_frame` and states.

        An actor is one or the other. With states, the kernel still calls it once \
        a frame — it is the state it is in that decides what runs, so a body \
        outside them would have no moment at which to be called.

        Move that code into the state it belongs to, or into each of them.
        """

      states != [] ->
        {declarations || [], {:states, states}, routines}

      every_frame != nil ->
        {declarations || [], {:body, every_frame}, routines}

      true ->
        raise CompileError, """
        actor without `every_frame` or states: #{inspect(name)}

        An actor is code called once per frame. Without either, the kernel would \
        be calling a `RET` sixty times a second and the screen would stay empty.

            defactor #{inspect(name)} do
              every_frame do
                sprite(0, x: 80, y: 72, tile: 0)
              end
            end
        """
    end
  end

  # A routine is a name and a block, and nothing else -- no parameters, because
  # an actor's cells are the only storage there is and a caller sets them.
  defp routine!(routine_name, block, actor, seen) do
    routine_name = literal_name!(routine_name, actor)

    if Enum.any?(seen, fn {name, _} -> name == routine_name end) do
      raise CompileError, """
      the actor #{inspect(actor)} declares the routine #{inspect(routine_name)} twice.

      A call names one place in the ROM, so two blocks with one name is a call \
      with no answer.
      """
    end

    {routine_name, block}
  end

  # A state's body holds the same `every_frame` an actor does, and may hold an
  # `on_enter` before it. Both are optional -- a state that only waits for a key
  # has no entry code, and one that paints a screen and then does nothing has no
  # frame code.
  defp state!(state_name, block, actor, seen) do
    state_name = literal_name!(state_name, actor)

    if Enum.any?(seen, fn {name, _, _} -> name == state_name end) do
      raise CompileError, """
      the actor #{inspect(actor)} declares the state #{inspect(state_name)} twice.

      States are numbered in the order they are written and `become` names them, \
      so two with one name is a question with no answer.
      """
    end

    {on_enter, every_frame} =
      block
      |> statements()
      |> Enum.reduce({nil, nil}, fn statement, {on_enter, every_frame} ->
        case statement do
          {:on_enter, _, [[do: body]]} when on_enter == nil -> {body, every_frame}
          {:every_frame, _, [[do: body]]} when every_frame == nil -> {on_enter, body}
          other -> reject_state!(other, state_name, actor)
        end
      end)

    {state_name, on_enter, every_frame}
  end

  defp literal_name!(name, _actor) when is_atom(name), do: name

  defp literal_name!(other, actor) do
    raise CompileError, """
    a state's name is written out: #{Macro.to_string(other)}, in #{inspect(actor)}.

    States are numbered when the game compiles, and `become` names one of those \
    numbers. There is nothing to look a name up in at run time.
    """
  end

  defp reject_state!(other, state_name, actor) do
    raise CompileError, """
    unknown statement in `state #{inspect(state_name)}` of #{inspect(actor)}:

        #{Macro.to_string(other)}

    A state holds two forms and no others, both optional:

        on_enter do … end       once, on the frame the state is entered
        every_frame do … end    every frame it stays in

    `on_enter` is where a screen is painted: doing it in `every_frame` would \
    redraw it sixty times a second to no effect.
    """
  end

  # `count:` and nothing else. A pool of one is an actor, so the default says so
  # rather than being a special case anywhere below.
  defp count!(opts, name) do
    case Keyword.get(opts, :count, 1) do
      count when is_integer(count) and count in 1..255 ->
        count

      other ->
        raise CompileError, """
        the actor #{inspect(name)} asks for #{inspect(other)} instances.

        `count:` is a whole number from 1 to 255, decided while the game \
        compiles — every instance costs one cell per variable, out of the page \
        the kernel leaves to the actors.

            defactor :bullet, count: 4 do
        """
    end
  end

  defp state_names({:body, _}), do: []
  defp state_names({:states, states}), do: Enum.map(states, fn {name, _, _} -> name end)

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
  defp verify!(fragment, name, art, songs, screens) do
    Assembler.assemble(Runtime.program(fragment, art, songs, screens), origin: 0x0150)
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
