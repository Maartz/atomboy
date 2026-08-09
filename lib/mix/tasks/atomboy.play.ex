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

  The cartridge's battery-backed RAM lives in the library: one folder per
  game, keyed by the header rather than by the file's name, so the saves
  follow a ROM that moves or is renamed. On a game's first sight whatever
  the sidecar convention left next to the ROM is copied in — the emulator
  convention, so the files travel both ways — and a library root that
  cannot be written falls back to those sidecar files entirely. Reloaded on
  launch, written on exit and every ~10 s as soon as the game has written
  something.

  ## Options

    * `--window` — play in a real window (wxWidgets) rather than in the
      terminal: real keyboard events, crisp pixels at scale, and none of the
      terminal's prerequisites (neither `bin/play` nor a minimum size).
    * `--server` — draw nothing and speak the binary protocol of
      `Atomboy.Server` on stdout instead: the door a native shell comes
      through, not a way to play from a terminal.
    * `--hold N` — hold frames per keystroke (default 10), for terminals
      without the kitty keyboard protocol; with it (Ghostty…), key state is
      real and this setting no longer matters.
    * `--frames N` — stop after N frames (runs without a keyboard).
    * `--sound` / `--no-sound` — force sound on or off (default: on when
      interactive if ffplay is installed — `brew install ffmpeg`).
    * `--palette dmg|gray` — the green of the original panel (default) or
      neutral grays.
    * `--panel raw|dmg|pocket|cgb|crt` — the screen the frame is seen through:
      `raw` is no screen at all (default, the palette straight), the others
      model a real panel's colour and its response curve — the ghosting of
      moving images, in the window and the kitty terminal (half blocks stay
      sharp: hundreds of in-between colours would defeat the run-length
      encoding that keeps the terminal at 60 fps). Also on the PANEL row of
      the menu.
    * `--dial 0-100` — the contrast wheel under the DMG's thumb: turned up,
      every shade slides toward the darkest; turned down, toward the bare
      reflector. Only means anything on a panel — `raw` is the absence of
      one.
    * `--dmg` — force the monochrome machine on a cartridge that would have
      woken in colour.
    * `--dump f.pgm` — write the last frame as an image on exit.
    * `--dump-every N` — and write that same file every N frames while the
      game runs: an eye on the session from outside.
    * `--turbo 2|4|8` — how fast fast-forward runs: two, four or eight times
      the console's cadence, the screen keeping its own rate. Left out, `Tab`
      runs as fast as the machine allows, as it always has.
    * `--codes 01VVLLHH,…` — GameShark pokes, written before every frame;
      an unreadable one is reported on stderr and ignored.
    * `--save name` — a save profile: the battery becomes `name.sav` in the
      game's library folder, with its own states beside it. Essential for
      linking two instances of the same game on one machine — two players,
      two save files. And in game, keys `1`-`9` pick the current state slot
      for s/r — nine snapshots per profile.
    * `--library dir` — where that library lives; the platform's user-data
      folder otherwise.
    * `--record take.tas` / `--replay take.tas` — the movie: one joypad byte
      per frame from the boot on, and a replay deals the very same frames
      back. Not with the cable plugged in — the other console is the one
      input no track can promise to deal again. `mix atomboy.export` turns a
      take into an MP4 or a GIF.
    * `--listen [port]` / `--link host:port` — the link cable over TCP: one
      side listens (7373 by default), the other calls, and the two consoles
      trade their serial bytes just as they did over the real cable — Pokémon
      trades included. ⇄ in the status line.

  ## In game

    * `s` freezes the whole machine into the current slot's state in the
      library, `r` revives it — save before a boss, retry forever.
    * `Tab` toggles fast-forward (part of the frames drawn, sound muted) —
      intros go by in seconds. `--turbo` picks how fast.
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
