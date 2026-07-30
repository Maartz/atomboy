defmodule Mix.Tasks.Atomboy.Play do
  @shortdoc "Plays a Game Boy ROM in the terminal"

  @moduledoc """
  The console in the terminal: the emulator runs at the panel's cadence, and
  the keyboard stands in for the D-pad and the buttons.

      bin/play "Tetris (World) (Rev 1).gb"
      bin/play zelda.gb --hold 15

  The `bin/play` launcher is equivalent to `ELIXIR_ERL_OPTIONS="-noinput" mix
  atomboy.play …`: without `-noinput`, the BEAM's own tty reader steals one
  byte in three from the keyboard and arrow sequences never arrive whole — so
  the task refuses to start, printing these instructions instead.

  ## Keys

      arrows     the D-pad       x  A        c  B
      Enter      Start           ␣  Select   q or Ctrl-C  quit

  ## Saves

  The cartridge's battery-backed RAM lives in a `.sav` next to the ROM — the
  emulator convention, so the files travel both ways. Reloaded on launch,
  written on exit and every ~10 s as soon as the game has written something.

  ## Options

    * `--window` — play in a real window (wxWidgets) rather than in the
      terminal: real keyboard events, crisp pixels at scale, and none of the
      terminal's prerequisites (neither `bin/play` nor a minimum size).
    * `--hold N` — hold frames per keystroke (default 10), for terminals
      without the kitty keyboard protocol; with it (Ghostty…), key state is
      real and this setting no longer matters.
    * `--frames N` — stop after N frames (runs without a keyboard).
    * `--sound` / `--no-sound` — force sound on or off (default: on when
      interactive if ffplay is installed — `brew install ffmpeg`).
    * `--palette dmg|gray` — the green of the original panel (default) or
      neutral grays.
    * `--dump f.pgm` — write the last frame as an image on exit.
    * `--save name` — a save profile: `.sav` and `.state` become
      `rom.name.sav`/`rom.name.state`. Essential for linking two instances of
      the same game on one machine — two players, two save files. And in
      game, keys `1`-`9` pick the current state slot for s/r — nine snapshots
      per save.
    * `--listen [port]` / `--link host:port` — the link cable over TCP: one
      side listens (7373 by default), the other calls, and the two consoles
      trade their serial bytes just as they did over the real cable — Pokémon
      trades included. ⇄ in the status line.

  ## In game

    * `s` freezes the whole machine into a `.state` next to the ROM, `r`
      revives it — save before a boss, retry forever.
    * `Tab` toggles fast-forward (quarter rendering, sound muted) — intros go
      by in seconds.
    * `Backspace`, held down, rewinds — up to forty seconds back, ten frames
      per step. Died on a boss? Turn back time.
    * `p` pauses.

  The display wants 160 columns by 73 lines — shrinking the font (Cmd -) is
  usually enough.
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    case Atomboy.CLI.parse(args) do
      {:ok, rom, opts} ->
        {window, opts} = Keyword.pop(opts, :window, false)
        {server, opts} = Keyword.pop(opts, :server, false)

        runner =
          cond do
            server -> Atomboy.Server
            window -> Atomboy.Window
            true -> Atomboy.Play
          end

        case runner.run(rom, opts) do
          :ok -> :ok
          {:error, message} -> Mix.raise(message)
        end

      {:error, message} ->
        Mix.raise(message)
    end
  end
end
