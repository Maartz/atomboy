defmodule Mix.Tasks.Atomboy.Tune do
  @shortdoc "Plays a line of Potion notation, without writing a game around it"

  @moduledoc """
  A bar, heard.

      ELIXIR_ERL_OPTIONS="-noinput" mix atomboy.tune "c4 . e4 . g4 . c5 . . ."
      ELIXIR_ERL_OPTIONS="-noinput" mix atomboy.tune "c5 e5 c5 e5" --beat 4

  Compiles the notation, wraps it in a cartridge that does nothing but play it,
  and plays that. It loops until `q`. Nothing is written to the project.

  ## Why this exists

  Writing music means hearing it, and until now hearing a bar of Potion meant
  editing a game, rebuilding it and starting it. That is the loop
  `mix atomboy.live` removed for code, and the same loop was still there for
  music — a bar at a time, through a whole game.

  This is the small end of the answer. The large end is a page with a keyboard
  on it that writes notation into the game file while `mix atomboy.live` is
  running, so a change is heard *in the game* without it stopping. Both ends of
  that already exist; what is missing between them is an editor.

  The important part of that design, and the reason this task emits nothing but
  sound: the thing to write is **notation**, not bytes. `music :theme, "c4 e4"`
  in the source is what the game is made of, what `mix atomboy.live` watches,
  and what a person can read in a diff a year later.

      --beat n     frames a token lasts, 1 to 255 (12 by default, so five a second)
      --bytes      print what the notation compiled to, and stop
  """

  use Mix.Task

  alias Potion.Music

  @impl true
  def run(argv) do
    Mix.Task.run("compile")
    Mix.Task.run("app.start")

    {opts, rest} = OptionParser.parse!(argv, strict: [beat: :integer, bytes: :boolean])

    notation =
      case rest do
        [notation] -> notation
        _ -> Mix.raise(~s|usage: mix atomboy.tune "c4 . e4 -" [--beat n] [--bytes]|)
      end

    beat = opts[:beat] || Music.default_beat()
    # `.lead`: the notation compiles to its voices now, and one line of text is
    # the lead alone. This readout broke the day the bass landed -- a map has no
    # byte_size -- and nothing covered it; the test below the task does now.
    bytes = Music.compile!(notation, :tune, beat: beat).lead
    steps = div(byte_size(bytes), 3) - 1

    if opts[:bytes] do
      Mix.shell().info("#{steps} steps, #{byte_size(bytes)} bytes\n")

      bytes
      |> :binary.bin_to_list()
      |> Enum.chunk_every(3)
      |> Enum.each(fn
        [0, 0, 0] ->
          Mix.shell().info("  end")

        [_lo, 0, frames] ->
          Mix.shell().info("  rest            #{frames} frames")

        [lo, hi, frames] ->
          Mix.shell().info("  #{name(lo, hi)}#{pad(name(lo, hi))}#{frames} frames")
      end)
    else
      Mix.shell().info("#{steps} steps at #{beat} frames a beat — q to stop")
      play(notation, beat)
    end
  end

  # The cartridge is built the way a game is, through the macros, because a tune
  # played by a different road from the one a game takes would prove the wrong
  # thing. It is a module with one actor whose whole life is `play`.
  defp play(notation, beat) do
    name = "Tune#{:erlang.unique_integer([:positive])}"

    [{module, _} | _] =
      Code.compile_string("""
      defmodule #{name} do
        use Potion

        music :it, #{inspect(notation)}, beat: #{beat}

        defactor :speaker do
          variables started: 0

          every_frame do
            if started == 0 do
              started = 1
              play(:it)
            end
          end
        end
      end
      """)

    path = Path.join(System.tmp_dir!(), "#{name}.gb")
    File.write!(path, module.rom())

    try do
      Atomboy.Play.run(path)
    after
      File.rm(path)
    end
  end

  # The number back into a note, so `--bytes` reads as music rather than as hex.
  defp name(lo, hi) do
    x = lo + Bitwise.band(hi, 0x07) * 256

    Music.notes()
    |> Enum.find(fn {_note, value} -> value == x end)
    |> case do
      {note, _} -> Atom.to_string(note)
      nil -> "?"
    end
  end

  defp pad(name), do: String.duplicate(" ", max(16 - String.length(name), 1))
end
