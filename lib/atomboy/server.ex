defmodule Atomboy.Server.Split do
  @moduledoc """
  Four machines where there was one.

  A universe is a machine — the `{state, ram, apu}` trio a snapshot freezes
  — kept by a process of its own (`Atomboy.Server.Universe`), and a split
  is four of them plus the one being listened to. The list is ordered by
  universe: index 0 is the unperturbed original — the future that would
  have happened anyway — and 1 to 3 were nudged apart at the divider.

  The struct holds the four processes, never the four machines: a memory
  map costs its full size every time it crosses between processes, and a
  loop that handed four of them out and took four of them back every frame
  paid that price sixty times a second. Here the machines stay put and the
  pictures travel.

  It is the whole of the split's state besides: no frame counter of its own
  (the four are stepped together, so the loop's own counter speaks for all
  of them) and no memory of what was live before the fork, because universe
  0 already is it.
  """

  @type t :: %__MODULE__{universes: [pid()], focus: 0..3}

  defstruct universes: [], focus: 0
end

defmodule Atomboy.Server do
  @moduledoc """
  Server mode: atomboy as the engine behind a native shell.

  The shell (SwiftUI on macOS, or anything that can read a pipe) launches
  `atomboy rom.gb --server` and speaks a minimal binary protocol:

  ## Output (stdout)

      <<?F, rgb::binary-69120>>          one 160×144 frame in RGB24
      <<?U, universe, rgb::binary-69120>>  the same, from one of four
      <<?A, n::16-big, pcm::binary-n>>   s16le stereo PCM at 32,768 Hz
      <<?P, preset>>                     the panel, announced
      <<?R, state>>                      the movie: 0 idle, 1 recording, 2 replaying
      <<?S, split, focus>>               the multiverse, answered

  The RGB comes out of the same `Screen.to_rgb` as the window — palette
  included, overlay menu included: the shell draws, it knows nothing. The
  PCM follows the wall clock's anti-starvation pacing (`Audio.cadence`);
  the shell plays it as it comes. Status messages (the cable…) go to
  stderr — stdout stays a pure binary stream.

  `?P` carries the index into `Atomboy.LCD.presets/0` (0 raw, 1 dmg,
  2 pocket, 3 cgb, 4 crt), sent before the first frame and again whenever the
  menu changes it. It exists because the response curve does *not* run
  here: unlike the window, the server ships its frames un-ghosted. The
  shell owns the display, so the shell owns time — its shader applies the
  panel's response per RGB channel (which covers colour games, where the
  Elixir pass never could) and the dot structure with it. A shell that
  ignores `?P` simply draws sharp frames through the panel's colours.

  ## Input (stdin)

  Two-byte records: `<<op, key>>`, where `op` is `?+` (press) or `?-`
  (release). Keys: `?U ?D ?L ?R` the directions, `?A ?B` the buttons, `?S`
  Start, `?E` Select, `?M` the menu, `?W` rewind (held), `?P` pause, `?.`
  frame advance (one frame of machine while the menu holds the world
  still) — plus the direct actions for the native menu bar: `?s`/`?r`
  save/load state,
  `?1`-`?9` the slot. `?T`, turbo, is held rather than latched: `<<?+, ?T>>`
  engages it and `<<?-, ?T>>` lets it go. Five operations carry a value
  rather than a key: `<<?V, v>>` sets the mixer volume (0-100), `<<?X,
  mask>>` the four voices (bits 0-3), `<<?N, i>>` the panel preset (the same
  index `?P` announces), `<<?G, v>>` the contrast dial (0-100; above 100
  returns to the preset's resting point), `<<?T, n>>` the turbo speed (2, 4
  or 8, or 0 for uncapped — an op byte in the first position, where the
  keys' `?T` never stands)
  — the shell's native settings use these. The end of input (shell closed)
  stops the game cleanly — save written.

  ## The library

  The save browser speaks six more operations. `<<?L, _>>` asks for the
  inventory and is answered on stdout with the stream's one structured
  record — `<<?J, len::32-big, json>>`: game id, current profile, the
  profiles, and the named states with their timestamps and screenshot
  paths. `<<?K, len, name>>` saves the machine under a name (portrait
  included), `<<?O, len, name>>` loads it back, `<<?D, len, name>>`
  deletes it — `K` and `D` answer with a fresh `?J`, as does `?L`.
  `<<?F, len, name>>` switches profile, and a profile switch is a power
  cycle: battery flushed, machine reset on the other player's cartridge.
  `<<?E, _>>` exports the battery back beside the ROM.

  ## The movies

  Two more operations, and one answer. `<<?R, 1>>` starts recording from
  the machine as it stands (a snapshot anchor — the shell's player is
  mid-game) and `<<?R, 0>>` stops and writes the take into the game's own
  folder under the hour it was stopped. `<<?M, len::16-big, path>>` plays a
  movie back from a path: two bytes of length rather than the one the
  library's names get, because a path down a home folder outruns 255 bytes
  in a way a save's name never does.

  Whatever moves — the ops, a track running out, a take refused for
  belonging to another cartridge — the engine answers with `<<?R, state>>`,
  and only when the state actually changes. The shell's badge is therefore
  never a guess about what the engine did with a click.

  ## The console's clock

  `<<?H, 0, seconds::64-signed-big>>` sets what the cartridge's real-time
  clock is served: `seconds` away from the machine's own time, signed —
  the future to the right, yesterday to the left, zero for real time. Ten
  bytes, because a date is not a byte: the two-byte record framing is kept
  (the second byte is padding, as the value ops' key byte would be) and the
  eight that follow carry the offset. The shell sends it on boot and on
  every change; a terminal has `ATOMBOY_RTC_OFFSET` instead.

  While a movie records or replays, the take's own hour wins over this
  one — a recorded run is told the same time on every replay, and the
  shell greys the control out for the duration.

  ## The multiverse

  One operation, `<<?S, verb::4, universe::4>>`, holds all four verbs:

      0x00  fork    — four copies of the live machine, and the split begins
      0x1k  focus k — which universe is heard (and mirrored into the loop)
      0x2k  commit k — keep machine k, drop the other three
      0x30  abort   — commit universe 0, the future that would have happened

  A fork copies the machine four times and nudges each copy's *internal*
  divider counter by 0, 17, 37 and 59 T-cycles. Universe 0 takes the zero,
  and takes it as a no-op: not one key of its map moves, so it runs the
  frames the unsplit session would have run, byte for byte. The other
  three read DIV a shade out of phase from there on, and a game whose luck
  is drawn off timing draws different luck.

  While a split is up, the same joypad reaches all four machines through
  the same seam, the four are stepped **in parallel** (one `Task` each,
  awaited before the frame ends, so they are always at the same frame
  count), and every frame leaves as `?U` — the bare `?F` is untouched, so
  ordinary play is byte for byte the stream it always was. `?A` is
  unchanged too: only the focused universe is heard.

  Refused while split, each with a note: a second fork, a movie (recording
  and replay both), a state written or loaded, a pull off the rewind ring,
  and turbo — every one of them hides an "in which universe?" this version
  does not answer. And the other way round: a fork is refused while a take
  records or replays, while the cable is plugged, while turbo is engaged,
  and while a split is already up.

  Every `?S` operation is answered with `<<?S, split, focus>>` — 1 or 0 for
  whether four machines are running, and which one is heard — whether it
  was honoured or refused. The shell is never optimistic about a click: a
  refused fork answers "still one machine", and the UI stays where it was.

  Everything else is the usual machinery: menu inside the frame, states,
  mixer, link cable (`--listen`/`--link` work in server mode too).
  """

  import Bitwise

  alias Atomboy.Codes
  alias Atomboy.APU
  alias Atomboy.CPU.CartLoop
  alias Atomboy.Joypad
  alias Atomboy.LCD
  alias Atomboy.Library
  alias Atomboy.Link
  alias Atomboy.Menu
  alias Atomboy.Movie
  alias Atomboy.Play
  alias Atomboy.Play.Audio
  alias Atomboy.Play.Turbo
  alias Atomboy.PPU
  alias Atomboy.Save
  alias Atomboy.Screen
  alias Atomboy.Server.Split
  alias Atomboy.Server.Universe

  @frame_us 16_742

  # The visible divider byte. The counter behind it lives under `:div_acc`,
  # which is where a fork's nudge actually lands — see `nudged/2`.
  @div 0xFF04

  # What the four universes are offset by, in T-cycles of divider. Universe
  # 0 first, and its zero is load-bearing.
  @nudges [0, 17, 37, 59]

  # How long the loop waits for four machines to finish a frame. A frame is
  # milliseconds; this is the length of a hang, not of a slow machine.
  @split_await 30_000

  @keys %{
          ?U => :up,
          ?D => :down,
          ?L => :left,
          ?R => :right,
          ?A => :a,
          ?B => :b,
          ?S => :start,
          ?E => :select,
          ?M => :menu,
          ?W => :rewind,
          ?P => :pause,
          ?T => :turbo,
          ?. => :frame_advance,
          # The direct actions — the native menu bar uses these.
          ?s => :save_state,
          ?r => :load_state
        }
        |> Map.merge(for n <- 1..9, into: %{}, do: {?0 + n, {:slot, n}})

  @buttons [:up, :down, :left, :right, :a, :b, :start, :select, :rewind]

  @doc "Plays `rom_path` in server mode. Same options as the window."
  @spec run(Path.t(), keyword()) :: :ok | {:error, String.t()}
  def run(rom_path, opts \\ []) do
    rom = Screen.load(rom_path)
    lib = Library.open(rom, rom_path, opts)
    sav = Library.sav_path(lib)

    with {:ok, link} <- link_up(opts) do
      # stdout is a binary stream: in Unicode (the BEAM's default), every
      # byte ≥ 128 would become two UTF-8 bytes — torn frames.
      :io.setopts(:standard_io, encoding: :latin1)

      parent = self()
      reader = spawn_link(fn -> read_stdin(parent) end)

      ram =
        Screen.boot_ram(rom, Keyword.get(opts, :dmg, false))
        |> then(&if(link, do: Map.put(&1, :link, link), else: &1))
        |> Save.load(sav)
        |> Codes.installe(Codes.analyse(Keyword.get(opts, :codes, "")))

      palette = Keyword.get(opts, :palette, :dmg)

      try do
        # The panel goes out before the first frame: the shell must know
        # what it is looking through before it draws anything.
        loop(
          emit_panel(%{
            state: Screen.boot_state(rom, Keyword.get(opts, :dmg, false)),
            rom: rom,
            ram: ram,
            sav: sav,
            lib: lib,
            # What a power-on has to remember: a movie anchored on boot
            # puts the machine back here (`Play.start_replay/2`).
            dmg: Keyword.get(opts, :dmg, false),
            state_slot: 1,
            palette: palette,
            lcd:
              LCD.compile(
                Keyword.get(opts, :panel, :raw),
                palette,
                Map.get(ram, :cgb, false),
                Keyword.get(opts, :dial)
              ),
            dial: Keyword.get(opts, :dial),
            down: MapSet.new(),
            menu: nil,
            apu: %APU{},
            audio: %{t0: System.monotonic_time(:microsecond), sent: 0},
            frame: 0,
            max_frames: Keyword.get(opts, :frames, :infinity),
            history: [],
            last_frame: nil,
            turbo: false,
            # The shell resends the chosen speed on every boot (`?T`); the
            # flag is here for a server started from the command line.
            turbo_speed: Keyword.get(opts, :turbo_speed, :uncapped),
            # The movie machinery is the play loop's, field for field —
            # `Play.pad/2`, `Play.stamp/2` and `Play.restore/3` are shared
            # rather than copied, so a take recorded in the shell and one
            # recorded in the terminal are the same artifact.
            movie: nil,
            take: nil,
            movie_file: Keyword.get(opts, :record),
            # What the shell was last told the machinery was doing.
            movie_said: nil,
            # The note the shared functions write. The shell has no status
            # line to put it on — it learns the same news from `?R` — but
            # the field has to exist for those functions to write it.
            note: nil,
            # The one frame `?.` buys while the menu holds the world still.
            advance: false,
            # Nothing, or the four machines a fork put where this one was.
            # While it stands, `state`, `ram` and `apu` above mirror the
            # focused universe at the end of every frame — so the battery
            # that is autosaved, the machine a crash flushes and the one a
            # commit lands on are all the future the player is listening to.
            split: nil,
            # What a power cycle must remember: the codes of boot.
            reset: %{codes: Keyword.get(opts, :codes, "")},
            deadline: System.monotonic_time(:microsecond) + @frame_us
          })
          |> from_the_start(opts)
        )
      after
        # This kill retires the process; whether it also frees the thread
        # the process was reading on is up to `read_stdin/1`, which is why
        # that function is careful about what it agrees to read at all.
        Process.unlink(reader)
        Process.exit(reader, :kill)
        Link.close(link)
      end

      :ok
    end
  end

  defp link_up(opts) do
    cond do
      port = Keyword.get(opts, :listen) -> Link.listen(port)
      target = Keyword.get(opts, :link) -> connect(target)
      true -> {:ok, nil}
    end
  end

  defp connect(target) do
    case String.split(target, ":") do
      [host, port] -> Link.connect(host, String.to_integer(port))
      [host] -> Link.connect(host, Link.default_port())
    end
  end

  # ── The loop ────────────────────────────────────────────────────────────────

  defp loop(%{frame: n, max_frames: max} = ctx) when n >= max, do: finish(ctx)

  defp loop(ctx) do
    case drain(ctx) do
      :quit ->
        finish(ctx)

      # The menu is this front-end's pause — the machine sleeps behind it —
      # so it is also where a frame is worth buying one at a time.
      ctx when ctx.menu != nil and ctx.advance ->
        step(%{ctx | advance: false})

      ctx when ctx.menu != nil ->
        menu_idle(ctx)

      # A split refuses the rewind key at the door (`press/3`), so a held
      # rewind cannot be standing here while four machines run.
      ctx ->
        if MapSet.member?(ctx.down, :rewind), do: rewind_step(ctx), else: step(ctx)
    end
  end

  # A session that ends inside a split ends on the universe the player was
  # listening to: the same machine a commit would have installed, asked for
  # once on the way out. Nothing else in the loop reads the split's machines,
  # so this is where they come home.
  defp finish(%{split: %Split{}} = ctx), do: finish(commit(ctx, ctx.split.focus))

  defp finish(ctx) do
    Save.flush(ctx.ram, ctx.sav)
    written(ctx)
    :ok
  end

  defp step(%{split: %Split{}} = ctx), do: split_step(ctx)

  defp step(ctx) do
    held = MapSet.to_list(ctx.down)
    # The movie's one seam, shared with the play loop: recording copies the
    # pad the frame is about to be run on, replay dictates it.
    {ctx, dpad, btns} = Play.pad(ctx, held)
    ctx = announce_movie(ctx)
    ram = Joypad.set(ctx.ram, dpad, btns)
    ram = Codes.applique(ram)

    # In turbo: one frame emitted per speed step (one in four uncapped),
    # no PCM, and a deadline divided — or suspended.
    render? = Turbo.render?(ctx.frame, ctx.turbo, ctx.turbo_speed)

    {pixels, state, ram} =
      try do
        Screen.frame(ctx.state, ctx.rom, ram, render?)
      rescue
        e in [Atomboy.CPU.Unimplemented, Atomboy.CPU.Derailed] ->
          Save.flush(ram, ctx.sav)
          reraise e, __STACKTRACE__
      end

    {ram, apu, audio} =
      if ctx.turbo do
        # The triggers are consumed anyway — the APU's state stays
        # coherent, only the PCM falls silent.
        {_, ram, apu} = APU.samples(ram, ctx.apu, 0)
        {ram, apu, ctx.audio}
      else
        sound(ram, ctx.apu, ctx.audio)
      end

    ctx = if render?, do: emit_frame(ctx, pixels), else: ctx

    deadline =
      case Turbo.frame_us(ctx.turbo, ctx.turbo_speed) do
        :suspended ->
          ctx.deadline

        frame_us ->
          now = System.monotonic_time(:microsecond)
          deadline = max(ctx.deadline, now - 100_000)
          if deadline > now + 999, do: Process.sleep(div(deadline - now, 1000))
          deadline + frame_us
      end

    ram = if rem(ctx.frame, 600) == 599, do: Save.flush(ram, ctx.sav), else: ram

    %{
      ctx
      | state: state,
        ram: ram,
        apu: apu,
        audio: audio,
        frame: ctx.frame + 1,
        deadline: deadline,
        last_frame: if(render?, do: pixels, else: ctx.last_frame)
    }
    |> remember()
    |> loop()
  end

  # The PCM owed by the wall clock, pushed into the stream — the shell plays.
  defp sound(ram, apu, audio) do
    {audio, needed} = Audio.cadence(audio)
    {pcm, ram, apu} = APU.samples(ram, apu, needed)

    if byte_size(pcm) > 0 do
      IO.binwrite(:stdio, [<<?A, byte_size(pcm)::16-big>>, pcm])
    end

    {ram, apu, %{audio | sent: audio.sent + needed}}
  end

  # A frame onto the wire, through the panel's colours — never its response
  # curve: the shell's shader owns time (see the moduledoc). The context
  # passes through untouched; the shape mirrors the window's for symmetry.
  defp emit_frame(ctx, pixels) do
    IO.binwrite(:stdio, [<<?F>>, Screen.to_rgb(pixels, ctx.palette, ctx.lcd)])
    ctx
  end

  # The panel announced to the shell — its index in the preset cycle.
  defp emit_panel(ctx) do
    index = Enum.find_index(LCD.presets(), &(&1 == ctx.lcd.preset)) || 0
    IO.binwrite(:stdio, <<?P, index>>)
    ctx
  end

  # What the machinery is doing, whenever it stops being what the shell was
  # last told. Every path that could move it passes through here — the ops,
  # the menu's verbs, a state load that re-records, and the frame on which
  # a track runs out — so the shell's badge is the engine's own answer and
  # never an optimistic guess about a click.
  defp announce_movie(ctx) do
    said = Play.movie_state(ctx)

    if said == ctx.movie_said do
      ctx
    else
      IO.binwrite(:stdio, <<?R, movie_byte(said)>>)
      %{ctx | movie_said: said}
    end
  end

  defp movie_byte(:recording), do: 1
  defp movie_byte(:replaying), do: 2
  defp movie_byte(nil), do: 0

  # A take asked for on the command line: `--record` claims a boot anchor,
  # `--replay` names a file. The shell does not use these — it has the ops
  # — but a server started by hand is still atomboy.
  defp from_the_start(ctx, opts) do
    cond do
      Keyword.has_key?(opts, :record) ->
        announce_movie(Play.start_recording(ctx, anchor: :boot))

      path = Keyword.get(opts, :replay) ->
        announce_movie(Play.replay(ctx, path))

      true ->
        ctx
    end
  end

  # `--record` named its file before the first frame, and the shell closing
  # is what stops the take.
  defp written(%{movie_file: path, movie: {:recording, _movie}} = ctx) when is_binary(path) do
    {movie, _ctx} = Play.stop_movie(ctx)
    Movie.write(movie, path)
  end

  defp written(_ctx), do: :ok

  defp menu_idle(ctx) do
    ctx =
      if ctx.last_frame do
        emit_frame(ctx, Menu.render(ctx.menu, ctx.last_frame))
      else
        ctx
      end

    Process.sleep(50)
    loop(%{ctx | deadline: System.monotonic_time(:microsecond) + @frame_us})
  end

  # A pull off the ring is a state load like any other, so it goes through
  # the same door: while a take records, it cuts the track back to the
  # entry's frame and counts as a re-record, and an entry older than the
  # take is refused rather than played into the middle of one — a refused
  # pull stays on the ring, since it changed nothing and must spend
  # nothing.
  defp rewind_step(ctx) do
    ctx =
      case ctx.history do
        [frozen | rest] ->
          case Play.restore(%{ctx | history: rest}, frozen, "⏪") do
            {:ok, ctx} -> announce_movie(ctx)
            :refused -> ctx
          end

        [] ->
          ctx
      end

    pixels = PPU.render_frame(ctx.ram)
    ctx = emit_frame(ctx, pixels)

    now = System.monotonic_time(:microsecond)
    deadline = max(ctx.deadline, now - 100_000)
    if deadline > now + 999, do: Process.sleep(div(deadline - now, 1000))

    loop(%{ctx | last_frame: pixels, deadline: deadline + @frame_us})
  end

  # The stamp rides inside the entry, as it does in the play loop: a frozen
  # machine has to say which frame of which take it stands at, or a rewind
  # during a recording would land the console somewhere the track cannot
  # account for.
  defp remember(%{frame: n} = ctx) when rem(n, 10) == 0 do
    %{
      ctx
      | history: Enum.take([{ctx.state, Play.stamp(ctx, ctx.ram), ctx.apu} | ctx.history], 240)
    }
  end

  defp remember(ctx), do: ctx

  # ── The multiverse ──────────────────────────────────────────────────────────

  # One frame, four times over. The pad is settled once — through the play
  # loop's own seam, so a split reads exactly the buttons the single machine
  # would have read — and handed to every universe unchanged: the fork is in
  # the machines' luck, never in the player's hands.
  #
  # The ring does not grow while the split is up. Its entries are the shared
  # past every universe came out of, which is why a commit keeps them; a
  # snapshot of one universe among four would be a machine the other three
  # never stood at, and the rewind key is refused for that very reason.
  defp split_step(ctx) do
    held = MapSet.to_list(ctx.down)
    {ctx, dpad, btns} = Play.pad(ctx, held)
    ctx = announce_movie(ctx)

    # The frame's worth of sound, owed by the wall clock and drawn by the
    # one universe being listened to. The other three are asked for none —
    # which still runs their APU over its captured triggers, so an unheard
    # machine stays coherent and a switch of focus never lands in the
    # middle of a note nobody played.
    {audio, needed} = Audio.cadence(ctx.audio)
    stepped = advance(ctx, dpad, btns, needed)

    {_pixels, _rgb, pcm} = Enum.at(stepped, ctx.split.focus)
    if byte_size(pcm) > 0, do: IO.binwrite(:stdio, [<<?A, byte_size(pcm)::16-big>>, pcm])

    stepped
    |> Enum.with_index()
    |> Enum.each(fn {{_pixels, rgb, _pcm}, universe} -> emit_universe(universe, rgb) end)

    # The same absolute pacing the single machine keeps: four universes are
    # four times the work, never four times the speed.
    now = System.monotonic_time(:microsecond)
    deadline = max(ctx.deadline, now - 100_000)
    if deadline > now + 999, do: Process.sleep(div(deadline - now, 1000))

    # The picture is mirrored into the loop; the machine behind it is not.
    # `state`, `ram` and `apu` stand where the fork left them for as long as
    # the split does, and the focused universe is asked for its machine only
    # when one is actually needed — a commit, a derailment, the end of the
    # session. The battery is left alone throughout: a cartridge must not be
    # written from a future that is still up for abandoning.
    {pixels, _rgb, _pcm} = Enum.at(stepped, ctx.split.focus)

    %{
      ctx
      | audio: %{audio | sent: audio.sent + needed},
        frame: ctx.frame + 1,
        deadline: deadline + @frame_us,
        last_frame: pixels
    }
    |> loop()
  end

  # The four universes stepped at once: every one is asked before any one is
  # awaited, which is what puts them on four cores, and all four are back
  # before this function returns — so they can never be at different frame
  # counts. Lockstep is not bookkeeping here, it is the shape of the code.
  #
  # What crosses is a pad byte out and pictures back. The pictures are
  # binaries the size of a screen, which the runtime passes by reference:
  # the frame costs what the slowest universe costs, and no longer what four
  # memory maps cost to copy.
  defp advance(ctx, dpad, btns, needed) do
    ctx.split.universes
    |> Enum.with_index()
    |> Enum.map(fn {universe, index} ->
      samples = if index == ctx.split.focus, do: needed, else: 0
      Universe.step(universe, dpad, btns, ctx.palette, ctx.lcd, samples)
    end)
    |> Enum.map(&Universe.await(&1, @split_await))
    |> Enum.map(&landed(ctx, &1))
  end

  # A universe that ran off the rails takes the session with it — but not the
  # battery: the machine the player was listening to is written first, exactly
  # as the single loop writes it before letting the crash report fly. The
  # exception is carried back across the barrier rather than allowed to kill
  # the process holding it, because an exit would arrive here with the
  # cartridge unsaved — and with nobody left to say where the machine stood.
  defp landed(_ctx, {:ok, pixels, rgb, pcm}), do: {pixels, rgb, pcm}

  defp landed(ctx, {:derailed, error, stacktrace}) do
    {_state, ram, _apu} = focused_machine(ctx)
    Save.flush(ram, ctx.sav)
    reraise error, stacktrace
  end

  defp focused_machine(ctx) do
    ctx.split.universes
    |> Enum.at(ctx.split.focus)
    |> Universe.machine(@split_await)
  end

  # A frame with its universe written on it. `?F` is left alone: a shell that
  # knows nothing of splits reads the stream it always read.
  defp emit_universe(universe, rgb), do: IO.binwrite(:stdio, [<<?U, universe>>, rgb])

  # The engine's answer to a `?S`, honoured or refused: how many machines are
  # running and which one is heard. Sent on every operation rather than only
  # on the ones that changed something, because the question a refusal
  # answers is precisely "did that click do anything?".
  defp announce_split(ctx) do
    case ctx.split do
      %Split{focus: focus} -> IO.binwrite(:stdio, <<?S, 1, focus>>)
      nil -> IO.binwrite(:stdio, <<?S, 0, 0>>)
    end

    ctx
  end

  # The four verbs, in one value byte: the verb in the high nibble, the
  # universe in the low one.
  defp split_op(ctx, value) do
    case {bsr(value, 4), value &&& 0x0F} do
      {0, _any} -> fork(ctx)
      {1, k} when k in 0..3 -> focused(ctx, k)
      {2, k} when k in 0..3 -> commit(ctx, k)
      # Abort is not a verb of its own: it is commit 0, and universe 0 is the
      # future that would have happened anyway.
      {3, _any} -> commit(ctx, 0)
      _unknown -> ctx
    end
  end

  # Four copies of the live machine, three of them nudged. Refused by
  # everything that would leave "in which universe?" unanswered: a take being
  # written or read, the cable, a split already up — and turbo, which is
  # refused the other way round too. Dropping turbo silently to make room for
  # a fork would answer a question the player did not ask, and a split
  # sprinting at eight times the rate is four screens nobody can watch.
  defp fork(%{split: %Split{}} = ctx), do: split_refuse(ctx, "a second fork")
  defp fork(%{movie: movie} = ctx) when movie != nil, do: split_refuse(ctx, "the fork")
  defp fork(%{turbo: true} = ctx), do: split_refuse(ctx, "the fork")

  defp fork(ctx) do
    if Map.has_key?(ctx.ram, :link) do
      split_refuse(ctx, "the fork")
    else
      universes =
        Enum.map(@nudges, fn nudge ->
          Universe.open(ctx.rom, nudged({ctx.state, ctx.ram, ctx.apu}, nudge))
        end)

      %{ctx | split: %Split{universes: universes, focus: 0}}
    end
  end

  # The nudge, on the counter and not on the byte. What 0xFF04 shows is the
  # top half of a sixteen-bit counter the hardware ticks every T-cycle; here
  # the bottom half is `:div_acc`, the T-cycles the timer has not yet carried
  # (`Atomboy.Timer.advance/2`). Offsetting the pair moves the *phase* of
  # every future DIV read — which is what a game that seeds its randomness on
  # the divider actually reads — where writing 0xFF04 alone would be overrun
  # by the next carry and forgotten.
  #
  # Universe 0 takes the zero and takes it whole: not one key of the map is
  # touched, not even to write back what was already there, because the proof
  # that a split changes nothing is a proof about this exact map.
  defp nudged(machine, 0), do: machine

  defp nudged({state, ram, apu}, offset) do
    counter = bsl(Map.get(ram, @div, 0), 8) ||| Map.get(ram, :div_acc, 0)
    counter = counter + offset &&& 0xFFFF

    {state, ram |> Map.put(@div, bsr(counter, 8)) |> Map.put(:div_acc, counter &&& 0xFF), apu}
  end

  # Which universe is heard. The mirror follows at the end of the next frame,
  # which is soon enough: nothing between here and there reads it.
  defp focused(%{split: nil} = ctx, _k), do: ctx
  defp focused(ctx, k), do: %{ctx | split: %Split{ctx.split | focus: k}}

  # Machine k kept, the other three dropped. Nothing is added on the way in:
  # a fork copies the live memory map, which never carries the take's stamp
  # (only a *frozen* machine does — `Play.stamp/2`), and a commit is not the
  # place for one to be invented. The rewind ring survives untouched, because
  # every entry on it is from the past all four universes shared.
  defp commit(%{split: nil} = ctx, _k), do: ctx

  defp commit(ctx, k) do
    {state, ram, apu} = ctx.split.universes |> Enum.at(k) |> Universe.machine(@split_await)
    Enum.each(ctx.split.universes, &Universe.close/1)

    %{ctx | split: nil, state: state, ram: ram, apu: apu}
  end

  # The note the shared functions write. The shell has no status line to put
  # it on — it learns the same news from the `?S` answer — but a refusal that
  # says nothing anywhere is a refusal nobody can debug.
  defp split_refuse(ctx, what),
    do: %{ctx | note: {"#{what} unavailable: the reality is split", 120}}

  defp split?(%{split: %Split{}}), do: true
  defp split?(_ctx), do: false

  # ── The keys ────────────────────────────────────────────────────────────────

  defp drain(ctx) do
    receive do
      # The shell's native mixer: volume (?V, 0-100) and the four-voice mask
      # (?X, bits 0-3) — applied to the same ram[:mixer] as the in-game
      # menu, folded by the APU into its per-frame config.
      {:key, ?V, volume} ->
        drain(%{ctx | ram: mixer_put(ctx.ram, :volume, min(volume, 100))})

      {:key, ?X, mask} ->
        voices =
          {(mask &&& 1) != 0, (mask &&& 2) != 0, (mask &&& 4) != 0, (mask &&& 8) != 0}

        drain(%{ctx | ram: mixer_put(ctx.ram, :voices, voices)})

      # The shell's native panel picker: ?N carries the preset index — the
      # tables recompile and the choice is announced back through ?P, so
      # the shader and the engine stay in step. An index off the end of
      # the cycle leaves the panel as it stands.
      {:key, ?N, index} ->
        preset = Enum.at(LCD.presets(), index, ctx.lcd.preset)
        drain(recompile(%{ctx | lcd: %{ctx.lcd | preset: preset}}))

      {:codes, string} ->
        drain(%{ctx | ram: Codes.installe(ctx.ram, Codes.analyse(string))})

      # The console's clock: how far from real time it is set, in signed
      # seconds. It shifts what the cartridge's RTC is served from the next
      # read on — a game that has already latched keeps its snapshot until
      # it latches again, which is the hardware's own rule.
      {:clock, seconds} ->
        drain(%{ctx | ram: CartLoop.set_rtc_offset(ctx.ram, seconds)})

      # The contrast dial: ?G carries 0-100; anything above returns the
      # panel to its resting point. The tables recompile mid-frame.
      {:key, ?G, v} ->
        drain(recompile(%{ctx | dial: if(v <= 100, do: v, else: nil)}))

      # The turbo speed: ?T carries 2, 4 or 8 — or 0, the suspended
      # deadline turbo has always run at. A multiplier nobody knows leaves
      # the speed where it stands.
      {:key, ?T, value} ->
        drain(turbo_speed(ctx, value))

      # The multiverse: fork, focus, commit, abort — one op, four verbs, and
      # the engine's own answer to every one of them.
      {:key, ?S, value} ->
        drain(announce_split(split_op(ctx, value)))

      # The save browser: list, save, load, delete, profile, export.
      {:library, :list} ->
        drain(emit_library(ctx))

      {:library, :save, name} ->
        drain(emit_library(save_named(ctx, name)))

      {:library, :load, name} ->
        drain(load_named(ctx, name))

      {:library, :delete, name} ->
        Library.delete_state(ctx.lib, name)
        drain(emit_library(ctx))

      {:library, :profile, name} ->
        drain(ctx |> power_cycle(name) |> emit_library())

      {:library, :export} ->
        Library.export(ctx.lib)
        drain(ctx)

      # The movie ops. Recording starts on the machine as it stands — the
      # player who clicked is mid-game — and stopping writes the take into
      # the game's folder, which is where the shell's open panel will find
      # it again. Both directions of one refusal meet here too: a take
      # cannot begin over four machines, and a fork cannot begin over a take.
      {:key, ?R, 1} ->
        if split?(ctx),
          do: drain(split_refuse(ctx, "recording")),
          else: drain(announce_movie(Play.start_recording(ctx)))

      {:key, ?R, _stop} ->
        drain(announce_movie(elem(Play.stop_and_save(ctx), 1)))

      {:movie, :replay, path} ->
        if split?(ctx),
          do: drain(split_refuse(ctx, "replay")),
          else: drain(announce_movie(Play.replay(ctx, path)))

      {:key, op, key} ->
        case press(ctx, op, Map.get(@keys, key)) do
          :quit -> :quit
          ctx -> drain(ctx)
        end

      :stdin_closed ->
        # The shell is gone: conclude — except in a bounded trial
        # (--frames), where the input may legitimately be closed already.
        if ctx.max_frames == :infinity, do: :quit, else: ctx
    after
      0 -> ctx
    end
  end

  # Changing speed mid-sprint re-anchors the deadline: the suspended one
  # is minutes behind, and the loop would try to pay that off in a burst.
  defp turbo_speed(ctx, value) do
    case Turbo.speed(value) do
      {:ok, speed} ->
        %{ctx | turbo_speed: speed, deadline: System.monotonic_time(:microsecond) + @frame_us}

      :error ->
        ctx
    end
  end

  defp press(ctx, _op, nil), do: ctx

  # The TAS verb, ahead of the menu's own keys: one frame, bought while the
  # world is held still — which in this front-end is the menu being open. A
  # running machine has nothing to buy, so it ignores the key, and so does
  # the release the shell sends after every keybind: a frame is asked for,
  # never held.
  defp press(%{menu: menu} = ctx, ?+, :frame_advance) when menu != nil,
    do: %{ctx | advance: true}

  defp press(ctx, _op, :frame_advance), do: ctx

  defp press(%{menu: menu} = ctx, ?+, key) when menu != nil do
    {menu, actions} = Menu.press(ctx.menu, key)

    case Enum.reduce(actions, %{ctx | menu: menu}, &menu_action/2) do
      :quit -> :quit
      ctx -> ctx
    end
  end

  defp press(%{menu: menu} = ctx, ?-, _key) when menu != nil, do: ctx

  defp press(ctx, ?+, :menu),
    do: %{
      ctx
      | menu:
          Menu.open(
            ctx.state_slot,
            ctx.palette,
            Map.get(ctx.ram, :cgb, false),
            Map.get(ctx.ram, :mixer),
            ctx.lcd.preset,
            Play.movie_state(ctx)
          ),
        down: MapSet.new()
    }

  defp press(ctx, ?+, :pause), do: press(ctx, ?+, :menu)

  # Turbo is held, not latched: the shell sends `+T` while the key or the
  # shoulder is down and `-T` when it comes up. Unavailable with the cable
  # plugged in (the serial protocol demands the tempo); on the way out, the
  # audio pacing restarts from zero — no catch-up burst inherited from the
  # sprint.
  #
  # Refused while split, and the split is refused while turbo runs: four
  # machines at eight times the rate are four screens nobody can watch, and
  # the pacing a fork inherits has to be the one the player was playing at.
  defp press(%{split: %Split{}} = ctx, ?+, :turbo), do: split_refuse(ctx, "turbo")
  defp press(%{split: %Split{}} = ctx, ?-, :turbo), do: ctx

  # The rewind key never joins the held set while the reality is split: a
  # pull off the ring is a state load, and a state load has no universe.
  defp press(%{split: %Split{}} = ctx, ?+, :rewind), do: split_refuse(ctx, "rewind")

  defp press(ctx, op, :turbo) when op in [?+, ?-] do
    tag = if op == ?+, do: :press, else: :release

    case Turbo.asked(tag, ctx.turbo, Map.has_key?(ctx.ram, :link)) do
      :on ->
        %{ctx | turbo: true}

      :off ->
        %{
          ctx
          | turbo: false,
            audio: %{t0: System.monotonic_time(:microsecond), sent: 0},
            deadline: System.monotonic_time(:microsecond) + @frame_us
        }

      _none_or_refused ->
        ctx
    end
  end

  defp press(ctx, ?+, :save_state), do: menu_action(:save_state, ctx)
  defp press(ctx, ?+, :load_state), do: menu_action(:load_state, ctx)
  defp press(ctx, ?+, {:slot, n}), do: %{ctx | state_slot: n}
  defp press(ctx, ?+, key) when key in @buttons, do: %{ctx | down: MapSet.put(ctx.down, key)}
  defp press(ctx, ?-, key) when key in @buttons, do: %{ctx | down: MapSet.delete(ctx.down, key)}
  defp press(ctx, _op, _key), do: ctx

  defp menu_action(_action, :quit), do: :quit

  # The slot's own save and load go through the browser's doors, refusals
  # included — the menu is another way of pressing a key, not another rule.
  defp menu_action(:save_state, ctx), do: save_named(ctx, slot_name(ctx))

  defp menu_action(:load_state, ctx), do: load_named(ctx, slot_name(ctx))

  defp menu_action({:slot, n}, ctx), do: %{ctx | state_slot: n}
  defp menu_action({:palette, p}, ctx), do: recompile(%{ctx | palette: p})
  defp menu_action({:panel, p}, ctx), do: recompile(%{ctx | lcd: %{ctx.lcd | preset: p}})
  defp menu_action({:mixer, m}, ctx), do: %{ctx | ram: Map.put(ctx.ram, :mixer, m)}

  # The take's three verbs, as the in-game menu offers them — the same
  # functions the shell's own menu bar reaches through `?R` and `?M`.
  defp menu_action(:record_movie, ctx), do: announce_movie(Play.start_recording(ctx))
  defp menu_action(:stop_movie, ctx), do: announce_movie(elem(Play.stop_and_save(ctx), 1))
  defp menu_action(:replay_movie, ctx), do: announce_movie(Play.replay_latest(ctx))

  defp menu_action(:quit, _ctx), do: :quit

  # Palette and panel both feed the same tables: whichever moved, they are
  # rebuilt. The game sleeps behind the menu, so the moment it costs on a
  # color cartridge goes unnoticed.
  defp recompile(ctx),
    do:
      emit_panel(%{
        ctx
        | lcd: LCD.compile(ctx.lcd.preset, ctx.palette, Map.get(ctx.ram, :cgb, false), ctx.dial)
      })

  # A machine frozen under its name, portrait included. Refused while the
  # reality is split: four machines have four presents, and a file that names
  # one of them without saying which is a file nobody can load back.
  defp save_named(%{split: %Split{}} = ctx, _name), do: split_refuse(ctx, "saving a state")

  defp save_named(ctx, name) do
    Library.save_state(
      ctx.lib,
      name,
      {ctx.state, Play.stamp(ctx, ctx.ram), ctx.apu},
      Library.screenshot(ctx.last_frame, ctx.palette, ctx.lcd)
    )

    ctx
  end

  # A state by name, through the play loop's own door: the cable survives
  # the trip through time, the take's stamp comes off the machine before
  # the cartridge ever sees it, and a state loaded mid-take re-records.
  #
  # Refused while split, for the mirror image of the reason a save is: a
  # machine landing into one of four universes would leave the other three
  # standing somewhere the player never played.
  defp load_named(%{split: %Split{}} = ctx, _name), do: split_refuse(ctx, "loading a state")

  defp load_named(ctx, name) do
    case Library.load_state(ctx.lib, name) do
      {:ok, frozen} ->
        case Play.restore(ctx, frozen, "state loaded") do
          {:ok, ctx} -> announce_movie(ctx)
          :refused -> ctx
        end

      :error ->
        ctx
    end
  end

  # Switching profile is handing the console to the other player: the
  # battery flushed, the machine reset from boot on the other cartridge —
  # cable, mixer and clock surviving, they belong to the table, not the game.
  defp power_cycle(ctx, profile) do
    Save.flush(ctx.ram, ctx.sav)
    lib = Library.set_profile(ctx.lib, profile)
    sav = Library.sav_path(lib)

    ram =
      Screen.boot_ram(ctx.rom, ctx.dmg)
      |> then(&if(link = Map.get(ctx.ram, :link), do: Map.put(&1, :link, link), else: &1))
      |> then(&if(mixer = Map.get(ctx.ram, :mixer), do: Map.put(&1, :mixer, mixer), else: &1))
      |> then(&Play.carry_clock(&1, ctx.ram))
      |> Save.load(sav)
      |> Codes.installe(Codes.analyse(ctx.reset.codes))

    %{
      ctx
      | lib: lib,
        sav: sav,
        ram: ram,
        state: Screen.boot_state(ctx.rom, ctx.dmg),
        apu: %APU{},
        history: [],
        last_frame: nil,
        menu: nil
    }
  end

  # The inventory onto the wire: the one structured record of the stream.
  defp emit_library(ctx) do
    payload =
      JSON.encode!(%{
        game: Library.game_id(ctx.rom),
        profile: ctx.lib.profile,
        profiles: Library.profiles(ctx.lib),
        states: Library.list(ctx.lib)
      })

    IO.binwrite(:stdio, [<<?J, byte_size(payload)::32-big>>, payload])
    ctx
  end

  # The slot as the library knows it — a reserved state name. In sidecar
  # fallback the library itself keeps the historical file names.
  defp slot_name(ctx), do: "slot-#{ctx.state_slot}"

  defp mixer_put(ram, key, value) do
    mixer = Map.get(ram, :mixer, Menu.mixer_default())
    Map.put(ram, :mixer, Map.put(mixer, key, value))
  end

  # ── The input ───────────────────────────────────────────────────────────────

  # Two bytes per event, read as they come; the end of the stream (the shell
  # is gone) concludes the game.
  #
  # A terminal is never read at all, and the reason is a leak rather than a
  # preference. The read below is `:file.read` on a `:raw` descriptor — a
  # NIF, which parks one of the ten dirty IO scheduler threads inside
  # `read(2)` for as long as the read lasts. Against a pipe that is a moment
  # and then the shell's bytes, or end of stream when it closes; against a
  # terminal, where nobody is ever going to type a binary protocol by hand,
  # it lasts forever. An exit signal cannot interrupt a NIF, so the teardown
  # kill retires the Erlang process and leaves the thread where it stands:
  # `Process.alive?/1` answers false while the thread is gone for good. Ten
  # runs in one VM — a test suite reaches that in one file — and the pool is
  # empty, at which point every file operation in the whole node blocks,
  # whoever asked for it.
  #
  # So the descriptor is asked what it is first. `false` covers the pipe the
  # native shell speaks through and a stdin closed before we ever looked
  # (the open then fails, and says so); `true` means there is no shell on
  # the other end, and the game runs on to its own budget with the pad at
  # rest — which is what a terminal was going to give it anyway.
  defp read_stdin(parent) do
    if :prim_tty.isatty(:stdin) == true do
      :ok
    else
      case :file.open(~c"/dev/fd/0", [:read, :binary, :raw]) do
        {:ok, f} -> read_loop(parent, f)
        _ -> send(parent, :stdin_closed)
      end
    end
  end

  defp read_loop(parent, f) do
    case :file.read(f, 2) do
      # ?C: the GameShark codes — a length, then the ASCII list, which
      # REPLACES the active set (an empty list clears everything).
      {:ok, <<?C, len>>} ->
        send(parent, {:codes, chunk(f, len)})
        read_loop(parent, f)

      # The library ops: L and E stand alone, K/O/D/F carry a name.
      {:ok, <<?L, _>>} ->
        send(parent, {:library, :list})
        read_loop(parent, f)

      {:ok, <<?E, _>>} ->
        send(parent, {:library, :export})
        read_loop(parent, f)

      {:ok, <<op, len>>} when op in ~c"KODF" ->
        verb = %{?K => :save, ?O => :load, ?D => :delete, ?F => :profile}
        send(parent, {:library, Map.fetch!(verb, op), chunk(f, len)})
        read_loop(parent, f)

      # ?H: the console's clock, as an offset from real time. Eight bytes,
      # signed and big-endian: a date can be years either side of today, and
      # a byte of value would only ever have carried a minute.
      {:ok, <<?H, _pad>>} ->
        case :file.read(f, 8) do
          {:ok, <<seconds::64-signed-big>>} ->
            send(parent, {:clock, seconds})
            read_loop(parent, f)

          _eof ->
            send(parent, :stdin_closed)
        end

      # ?M: a movie to replay, by path. The length is two bytes rather than
      # the one a save's name gets — the high half rides where a value byte
      # would — because 255 is generous for a name a player typed and thin
      # for a path down somebody's home folder.
      {:ok, <<?M, hi>>} ->
        case :file.read(f, 1) do
          {:ok, <<lo>>} ->
            send(parent, {:movie, :replay, chunk(f, hi * 256 + lo)})
            read_loop(parent, f)

          _eof ->
            send(parent, :stdin_closed)
        end

      {:ok, <<op, key>>} ->
        send(parent, {:key, op, key})
        read_loop(parent, f)

      _eof ->
        send(parent, :stdin_closed)
    end
  end

  # The payload of an op that carries one — a length already read, and the
  # bytes that follow it. A truncated stream gives an empty string rather
  # than a half a name: the op then does nothing, which is what a shell
  # that died mid-write deserves.
  defp chunk(_f, 0), do: ""

  defp chunk(f, len) do
    case :file.read(f, len) do
      {:ok, data} -> data
      _ -> ""
    end
  end
end
