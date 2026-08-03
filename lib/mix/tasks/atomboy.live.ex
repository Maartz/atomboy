defmodule Mix.Tasks.Atomboy.Live do
  @shortdoc "Plays a Potion game and reloads it into the running console on save"

  @moduledoc """
  The game, hot.

      ELIXIR_ERL_OPTIONS="-noinput" mix atomboy.live games/pong.exs

  Plays the game exactly as `mix atomboy.play` does — same keyboard, same sound,
  same status line — and watches the source file. Save it, and the running
  console picks up the new cartridge without restarting: the ball keeps its
  position, the score its count, the cells their values, and whatever you
  changed is different on the next frame.

  ## The watch

  The status line opens on the game's variables instead of the help: every
  cell by name, its value live, in declaration order. `w` toggles it back to
  the help and forth. It is the GOAL listener's reading half: the game is not
  a black box being fed a cartridge, it is a machine whose state has names —
  this task built the cartridge, so it knows them. Debugging a wall that
  does not stop the walker becomes *watching* `x` refuse to grow, rather than
  sprinkling probes.

  ## The listener

  And the writing half: press `:` and the status line becomes a prompt. Type
  `x = 20`, Enter, and the cell is written between two frames — the game reads
  it on its next one and the square jumps. `x` alone reads the cell back;
  negatives take the two's complement the language writes; Escape closes the
  prompt. The game keeps running while you type — the pad is released, the
  letters belong to the sentence — because watching the world go on around
  the value you are about to change is what a listener *is*.

  ## Why this is nearly free

  `Atomboy.Screen.frame/4` takes the ROM as an argument every frame, so swapping
  a cartridge is an assignment. And the swap is safe rather than lucky: the
  kernel is a fixed prefix of `Potion.Runtime.program/2` — init, vblank, pad,
  main loop — and the actors come after it, so at a frame boundary the processor
  is inside the `HALT` of a loop that has not moved. The actors may change
  length behind it; the `CALL`s that reach them are resolved afresh in the new
  ROM.

  It is the trick GOAL played on the PlayStation, and the reason it mattered
  there is the reason it matters here: the distance between changing a number
  and feeling it is the whole of the work.

  ## What a reload cannot carry

  The cells. `variables x: 80, y: 72` is an allocation, and adding, removing or
  reordering a line moves the addresses — the old bytes are then read under a
  new map and mean nothing. The task notices that the layout changed and says
  so; the game keeps running on the cartridge it had, and a restart is the
  honest answer.

  Naughty Dog had the same edge and the same answer: change a structure, reload
  the level.

  And the screen. A reload swaps the code, not what the code already did: a
  title painted in `on_enter` stays exactly as it was painted, because the state
  machine has already entered that state and will not enter it again. Change the
  words of a title screen and nothing happens until the game comes back round to
  it. What changes immediately is what is drawn or decided *every frame* — a
  paddle's position, a speed, a threshold, an angle.

  That is not a shortcoming to be fixed so much as the thing itself: the console
  kept its state, and its state includes the picture.

  ## When it does not compile

  Nothing happens to the game. The error's first line goes into the status bar
  and the console carries on with the last cartridge that built — a typo halfway
  through an edit should cost a note on screen, not the state that took a minute
  to reach.
  """

  use Mix.Task

  alias Atomboy.Play

  @impl true
  def run(argv) do
    Mix.Task.run("compile")
    Mix.Task.run("app.start")

    {opts, rest} =
      OptionParser.parse!(argv,
        strict: [save: :string, palette: :string, frames: :integer],
        aliases: []
      )

    path =
      case rest do
        [path] -> path
        _ -> Mix.raise("usage: mix atomboy.live <game.exs> [--save file] [--frames n]")
      end

    unless File.regular?(path), do: Mix.raise("no such game: #{path}")

    {module, rom, addresses} = build!(path)
    cartridge = Path.join(Mix.Project.build_path(), Path.basename(path, ".exs") <> ".gb")
    File.mkdir_p!(Path.dirname(cartridge))
    File.write!(cartridge, rom)

    Mix.shell().info("""
    #{module} — #{map_size(addresses)} cells, live from #{path}
    Save the file and the running console picks it up.
    The status line shows the cells, live — `w` toggles the help back.
    """)

    # The watcher's whole memory: when the file was last read, and what the cell
    # map looked like. The second is what tells a reload apart from a reboot.
    :persistent_term.put({__MODULE__, :seen}, {mtime(path), addresses})

    play =
      [
        save: opts[:save],
        palette: palette(opts[:palette]),
        reload: fn -> reload(path) end,
        # The watch: the cell map this task just built is exactly the thing the
        # status line needs to show the game's variables by name, live. The
        # layout cannot move under it -- a reload that moves cells is refused
        # above -- so the map handed over here stays true for the whole run.
        watch: addresses
      ]
      |> then(&if(opts[:frames], do: [{:frames, opts[:frames]} | &1], else: &1))

    Play.run(cartridge, play)
  end

  @doc false
  def reload(path) do
    {seen_at, seen_cells} = :persistent_term.get({__MODULE__, :seen})
    now = mtime(path)

    if now == seen_at do
      :unchanged
    else
      :persistent_term.put({__MODULE__, :seen}, {now, seen_cells})

      try do
        {_module, rom, cells} = build!(path)

        cond do
          cells == seen_cells ->
            {:ok, rom}

          true ->
            :persistent_term.put({__MODULE__, :seen}, {now, cells})

            {:error, "the cells moved — #{changed(seen_cells, cells)} — restart to pick this up"}
        end
      rescue
        error -> {:error, Exception.message(error)}
      end
    end
  end

  # Which names came or went, for a message that says what to do rather than
  # that something is wrong. A reordering shows as neither, so the count of
  # cells is named too.
  defp changed(before, now) do
    gone = Map.keys(before) -- Map.keys(now)
    new = Map.keys(now) -- Map.keys(before)

    cond do
      new != [] -> "added #{Enum.map_join(new, ", ", &inspect/1)}"
      gone != [] -> "removed #{Enum.map_join(gone, ", ", &inspect/1)}"
      true -> "#{map_size(now)} of them, reordered"
    end
  end

  # Compiled under a fresh name each time, because a module cannot be redefined
  # without Elixir complaining and the old one going stale under any process
  # still holding it. The name is thrown away; only the bytes and the cells are
  # kept.
  @doc false
  def build!(path) do
    source = File.read!(path)

    old =
      case Regex.run(~r/defmodule\s+([A-Z][\w.]*)\s+do/, source) do
        [_, name] -> name
        _ -> raise "#{path} does not define a module"
      end

    # A fresh name every time. Redefining a module makes Elixir complain and
    # leaves the old one stale under anything still holding it; the name is
    # thrown away, only the bytes and the cells are kept.
    new = "#{old}_#{:erlang.unique_integer([:positive])}"

    source
    |> module_only()
    |> String.replace("defmodule #{old} do", "defmodule #{new} do")
    |> Code.compile_string(Path.absname(path))

    module = Module.concat([new])
    {module, module.rom(), module.addresses()}
  end

  # Everything up to and including the file's last unindented `end` -- that is,
  # the module and not the three lines under it that write a .gb and announce
  # it. Those lines are why: the console is running in a raw alternate screen,
  # and an `IO.puts` from a reload would land in the middle of the picture.
  defp module_only(source) do
    lines = String.split(source, "\n")

    last =
      lines
      |> Enum.with_index()
      |> Enum.filter(fn {line, _index} -> line == "end" end)
      |> List.last()

    case last do
      {_line, index} -> lines |> Enum.take(index + 1) |> Enum.join("\n")
      nil -> source
    end
  end

  defp mtime(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime, size: size}} -> {mtime, size}
      _ -> :missing
    end
  end

  defp palette(nil), do: :dmg
  defp palette(name), do: String.to_existing_atom(name)
end
