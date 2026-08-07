defmodule Atomboy.Play do
  @moduledoc """
  The Game Boy, playable in the terminal.

  The loop: read the keyboard, lay the keys onto the joypad's lines, run
  one machine frame (154 scanlines), display it, hold the pace — 59.7 Hz,
  the panel's own.

  ## The terminal as a console — the way of the named pty

  The keyboard does **not** go through Erlang's I/O stack, for two reasons
  measured with a probe (`scripts/probe_clavier*.exs`):

    * `:shell.start_interactive({:noshell, :raw})`, OTP 26's API, never
      wakes a pending read when the keystroke arrives after it — input that
      was already buffered gets through, a human keystroke never does.
    * The BEAM detaches its child processes from the controlling terminal
      (`setsid` before exec): `/dev/tty` is dead to them, and any
      `stty < /dev/tty` is a silent no-op.

  But the pty has a *name* (`/dev/ttysNNN`), which `ps -o tty=` will give,
  and a device can be driven with no controlling link at all: `stty -f`
  sets the modes (`-icanon -echo -isig`: keystrokes one by one, no echo,
  Ctrl-C as byte 0x03 decoded as "quit"), and `:file.read` byte by byte
  delivers keystrokes in real time — verified with simultaneous writes
  included.

  One last thief: even with no read outstanding, `prim_tty` reads the
  terminal permanently and snatches one byte in three — arrows, three bytes
  long, almost never arrive whole. The `-noinput` flag turns it off
  (measured: 0/301 bytes received without it, 301/301 with), hence the
  `bin/play` launcher; on a tty without that flag, `run/2` refuses to start
  and prints the instructions instead.

    * The alternate screen (`\\e[?1049h`): the game takes the whole
      terminal, and the shell finds its scrollback intact on exit; the
      original `stty` settings are saved (`-g`) and restored.
    * Each frame redraws on top of the previous one (`\\e[H`), with no
      clearing — no flicker.
    * With no visible pty (`--frames` in tests, redirected input), reading
      falls back to `/dev/fd/0` and no size is demanded.

  ## Release, according to the terminal

  On a terminal that speaks the kitty keyboard protocol (Ghostty, kitty,
  WezTerm…), every key sends press *and* release: the keyboard state is
  real, and diagonals and A+direction chords work. The protocol is asked
  for at startup (`CSI > 11 u`, then a query) — the answer confirms it, and
  a mute terminal ignores the whole thing.

  Without it, a terminal reports keystrokes only, and macOS repeats just
  the last key pressed: each keystroke becomes a press held for `hold`
  frames (~170 ms), refreshed by auto-repeat — a real hold stays held, a
  brief tap stays brief, but chords last no longer than their hold window.
  Tunable with `hold:`.
  """

  alias Atomboy.APU
  alias Atomboy.Codes
  alias Atomboy.Joypad
  alias Atomboy.LCD
  alias Atomboy.Library
  alias Atomboy.Menu
  alias Atomboy.Play.Audio
  alias Atomboy.Play.Input
  alias Atomboy.Link
  alias Atomboy.PPU
  alias Atomboy.Save
  alias Atomboy.Screen

  # The period of a DMG frame: 70,224 T-cycles at 4.194 MHz.
  @frame_us 16_742
  @default_hold 10

  @doc """
  Plays `rom_path` until `q`/Ctrl-C — or for `frames:` frames, for trials
  without a keyboard. `dump:` writes the last frame as PGM on the way out.

  Returns `:ok`, or `{:error, message}` if the terminal is too small.
  """
  @spec run(Path.t(), keyword()) :: :ok | {:error, String.t()}
  def run(rom_path, opts \\ []) do
    rom = Screen.load(rom_path)
    lib = Library.open(rom, rom_path, opts)
    tty = pty_path()

    with :ok <- ensure_sole_reader(tty),
         {:ok, link} <- link_up(opts) do
      saved = terminal_setup(tty)

      try do
        play(rom, lib, tty, link, opts)
      after
        Link.close(link)
        terminal_restore(tty, saved)
      end
    end
  end

  # The cable is established before the alternate screen: the waiting
  # message has to be visible. With no option, no cable.
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

  # Without -noinput, prim_tty reads the terminal permanently and steals one
  # byte in three from the game — the arrows (3 bytes) never arrive whole.
  # Measured: 0/301 bytes received without -noinput, 301/301 with it. No
  # tty, no thief: redirected --frames trials pass without the flag.
  defp ensure_sole_reader(tty) do
    if tty != nil and :init.get_argument(:noinput) == :error do
      {:error,
       "The BEAM is reading the terminal at the same time as the game (it steals\n" <>
         "one byte in three — the arrows never arrive whole). Restart with:\n\n" <>
         "    bin/play <rom.gb>\n\n" <>
         "or  ELIXIR_ERL_OPTIONS=\"-noinput\" mix atomboy.play <rom.gb>"}
    else
      :ok
    end
  end

  defp play(rom, lib, tty, link, opts) do
    sav = Library.sav_path(lib)

    (fn ->
       parent = self()
       input = tty || "/dev/fd/0"
       reader = spawn_link(fn -> read_keys(parent, input) end)

       # Sound follows the keyboard: present when interactive, cut off in
       # redirected trials — unless asked for explicitly (sound: true/false).
       audio = if Keyword.get(opts, :sound, tty != nil), do: Audio.open()

       ram =
         Screen.boot_ram(rom, Keyword.get(opts, :dmg, false))
         |> then(&if(link, do: Map.put(&1, :link, link), else: &1))
         |> Save.load(sav)
         |> Codes.installe(Codes.analyse(Keyword.get(opts, :codes, "")))

       palette = Keyword.get(opts, :palette, :dmg)

       try do
         loop(%{
           state: Screen.boot_state(rom, Keyword.get(opts, :dmg, false)),
           rom: rom,
           ram: ram,
           sav: sav,
           hold: %{},
           down: MapSet.new(),
           menu: nil,
           kitty: false,
           audio: audio,
           sound?: audio != nil,
           apu: %APU{},
           pending: "",
           frame: 0,
           max_frames: Keyword.get(opts, :frames, :infinity),
           hold_frames: Keyword.get(opts, :hold, @default_hold),
           dump: Keyword.get(opts, :dump),
           dump_every: Keyword.get(opts, :dump_every),
           lib: lib,
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
           ghost: nil,
           gfx: false,
           gfx_id: 1,
           dims: terminal_dims(tty),
           size_ok: Keyword.has_key?(opts, :frames),
           turbo: false,
           paused: false,
           history: [],
           note: nil,
           # The hot seam: a function the caller may hand in, asked every so
           # often whether there is a newer cartridge. `Screen.frame` takes the
           # ROM as an argument, so swapping it is an assignment -- the console
           # keeps its RAM, its registers and its program counter, and the game
           # changes underneath itself.
           reload: Keyword.get(opts, :reload),
           reload_mark: 0,
           # The watch: the game's cells by name, handed in by `atomboy.live`
           # -- a bare `.gb` has bytes, not names. On from the start when the
           # names are known; `w` toggles it against the help line.
           watch: Keyword.get(opts, :watch),
           watching: Keyword.get(opts, :watch) != nil,
           # The listener's prompt: nil closed, the line typed so far open.
           prompt: nil,
           last_frame: nil,
           fps: 0.0,
           fps_mark: System.monotonic_time(:microsecond),
           deadline: System.monotonic_time(:microsecond) + @frame_us
         })
       after
         Process.unlink(reader)
         Process.exit(reader, :kill)
         Audio.close(audio)
       end
     end).()
  end

  # The size of the terminal, on the named pty (`stty -f … -a` — "66 rows;
  # 269 columns;" on mac, "rows 66; columns 269" elsewhere).
  defp terminal_dims(tty) do
    with out when is_binary(out) <- tty && to_string(:os.cmd(stty(tty, "-a 2> /dev/null"))),
         [_, rows] <- Regex.run(~r/(\d+) rows|rows (?:= )?(\d+)/, out) |> compact(),
         [_, cols] <- Regex.run(~r/(\d+) columns|columns (?:= )?(\d+)/, out) |> compact() do
      {String.to_integer(rows), String.to_integer(cols)}
    else
      _ -> nil
    end
  end

  # Half blocks demand 160×73; real images do not. So the verdict waits for
  # the half-second in which the terminal could answer the graphics query.
  defp ensure_size(%{size_ok: true}), do: :ok
  defp ensure_size(%{gfx: true}), do: :ok
  defp ensure_size(%{frame: n}) when n < 30, do: :wait

  defp ensure_size(%{dims: {rows, cols}}) when rows < 73 or cols < 160 do
    {:error,
     "The terminal is #{cols}×#{rows}; the DMG screen needs 160×73 in half\n" <>
       "blocks. Shrink the font (Cmd -), enlarge the window — or a terminal\n" <>
       "speaking the kitty graphics protocol (Ghostty, kitty, WezTerm) shows\n" <>
       "real images with no size constraint at all."}
  end

  defp ensure_size(_ctx), do: :ok

  # Regex.run with two alternatives: keep only the captured groups.
  defp compact(nil), do: nil
  defp compact(matches), do: Enum.reject(matches, &(&1 in [nil, ""]))

  # ── The frame loop ──────────────────────────────────────────────────────────

  defp loop(%{frame: n, max_frames: max} = ctx) when n >= max, do: finish(ctx)

  defp loop(ctx) do
    buffer = ctx.pending <> collect_input([])

    # The listener's prompt owns the whole keyboard while it is open: "x" is a
    # letter and not the A button, and `q` quits nothing. The machine keeps
    # running underneath -- the pad was released when the prompt opened, and
    # the world going on while you type is the point.
    if ctx.prompt != nil do
      {elements, pending} = Input.text(buffer)
      continue(Enum.reduce(elements, %{ctx | pending: pending}, &prompt_element/2))
    else
      {events, pending} = Input.decode(buffer)

      if Enum.any?(events, &match?({tag, :quit} when tag != :release, &1)) do
        finish(ctx)
      else
        continue(Enum.reduce(events, %{ctx | pending: pending}, &apply_event/2))
      end
    end
  end

  defp continue(ctx) do
    case ensure_size(ctx) do
      {:error, _} = error ->
        finish(ctx)
        error

      _ ->
        ctx |> reload() |> resume()
    end
  end

  # Asked four times a second rather than every frame: a stat() sixty times a
  # second to learn nothing is a syscall a frame, and a person cannot save a file
  # faster than this notices.
  #
  # A cartridge that fails to build leaves the running one alone. That is the
  # whole reason this returns the old context on an error rather than stopping:
  # a typo mid-edit should cost a note in the status line, not the game state
  # that took a minute to reach.
  defp reload(%{reload: nil} = ctx), do: ctx

  defp reload(%{frame: n, reload_mark: mark} = ctx) when n - mark < 15, do: ctx

  defp reload(ctx) do
    ctx = %{ctx | reload_mark: ctx.frame}

    case ctx.reload.() do
      {:ok, rom} -> %{ctx | rom: rom, note: {"reloaded", 90}}
      {:error, message} -> %{ctx | note: {"× " <> first_line(message), 240}}
      :unchanged -> ctx
    end
  end

  defp first_line(message) do
    message
    |> String.split("\n", trim: true)
    |> List.first("compile error")
    |> String.slice(0, 48)
  end

  defp resume(ctx) do
    ctx =
      if ctx.frame >= 30 and not ctx.size_ok do
        %{ctx | size_ok: true}
      else
        ctx
      end

    cond do
      ctx.menu != nil ->
        # Menu open: the machine sleeps, and the last frame carries the menu
        # as an overlay — the usual rendering displays it knowing nothing.
        ctx =
          if ctx.last_frame,
            do: draw(ctx, Menu.render(ctx.menu, ctx.last_frame), ctx.ram, []),
            else: ctx

        Process.sleep(50)
        loop(%{ctx | deadline: System.monotonic_time(:microsecond) + @frame_us})

      ctx.paused ->
        # Paused, the machine sleeps — the screen stays, the keyboard watches.
        ctx = if ctx.last_frame, do: draw(ctx, ctx.last_frame, ctx.ram, []), else: ctx
        Process.sleep(50)
        loop(%{ctx | deadline: System.monotonic_time(:microsecond) + @frame_us})

      rewinding?(ctx) ->
        rewind_step(ctx)

      true ->
        step(ctx)
    end
  end

  # Rewind held down — on a kitty keyboard through the real state, on a
  # classic one through the auto-repeat that keeps the hold alive.
  defp rewinding?(ctx) do
    MapSet.member?(ctx.down, :rewind) or Map.has_key?(ctx.hold, :rewind)
  end

  # One step backwards: pop a snapshot (ten frames of play) and draw it as
  # it stands — the machine is not running, time is going back. The sound
  # falls silent; on resuming, the stream slaved to the wall clock realigns
  # itself.
  defp rewind_step(ctx) do
    ctx =
      case ctx.history do
        [{state, ram, apu} | rest] ->
          %{ctx | state: state, ram: ram, apu: apu, history: rest}

        [] ->
          ctx
      end

    pixels = PPU.render_frame(ctx.ram)
    ctx = draw(%{ctx | note: {"⏪", 30}}, pixels, ctx.ram, [])

    now = System.monotonic_time(:microsecond)
    deadline = max(ctx.deadline, now - 100_000)
    if deadline > now + 999, do: Process.sleep(div(deadline - now, 1000))

    hold = for {key, left} <- ctx.hold, left > 1, into: %{}, do: {key, left - 1}
    loop(%{ctx | hold: hold, last_frame: pixels, deadline: deadline + @frame_us})
  end

  # The memory of rewinding: one snapshot every ten frames, a ring of 240 —
  # forty seconds of history, structurally shared (the map differs from one
  # frame to the next only by its writes).
  defp remember(%{frame: n} = ctx) when rem(n, 10) == 0 do
    %{ctx | history: Enum.take([{ctx.state, ctx.ram, ctx.apu} | ctx.history], 240)}
  end

  defp remember(ctx), do: ctx

  defp step(ctx) do
    held = Enum.uniq(MapSet.to_list(ctx.down) ++ Map.keys(ctx.hold))
    ram = Joypad.set(ctx.ram, Input.dpad_lines(held), Input.button_lines(held))
    ram = Codes.applique(ram)

    # In turbo, one frame in four is displayed — rendering is the cost.
    render? = not ctx.turbo or rem(ctx.frame, 4) == 0

    # An unknown opcode kills the game, not the progress: the cartridge's
    # battery is written before letting the crash report fly.
    {pixels, state, ram} =
      try do
        Screen.frame(ctx.state, ctx.rom, ram, render?)
      rescue
        e in [Atomboy.CPU.Unimplemented, Atomboy.CPU.Derailed] ->
          Save.flush(ram, ctx.sav)
          reraise e, __STACKTRACE__
      end

    # During turbo the audio port is closed: sound/3 discards the triggers
    # without pushing anything.
    {ram, apu, audio} = sound(ram, ctx.apu, ctx.audio)

    ctx = if render?, do: draw(ctx, pixels, ram, held), else: ctx

    # Pacing by absolute deadline: every excess of sleep is recovered on the
    # next frame, so the long-term rate is exactly 59.7275 Hz — the
    # condition for sample production to keep up with ffplay, which consumes
    # at a true 32,768 Hz. Relative pacing drifts by ~0.7% and starves the
    # audio buffer within half a minute. After an outright stall (> 100 ms),
    # the deadline realigns: no catch-up sprint.
    # Turbo suspends the deadline — emulation runs as fast as the BEAM can.
    deadline =
      if ctx.turbo do
        ctx.deadline
      else
        now = System.monotonic_time(:microsecond)
        deadline = max(ctx.deadline, now - 100_000)
        if deadline > now + 999, do: Process.sleep(div(deadline - now, 1000))
        deadline + @frame_us
      end

    hold = for {key, left} <- ctx.hold, left > 1, into: %{}, do: {key, left - 1}

    # Autosave: the cartridge's battery does not wait for the exit.
    ram = if rem(ctx.frame, 600) == 599, do: Save.flush(ram, ctx.sav), else: ram

    # The periodic dump: the harness's eye — the current screen, overwritten
    # every N frames, to drive a session from the outside.
    if ctx.dump_every && ctx.dump && rem(ctx.frame, ctx.dump_every) == 0 do
      dump(%{ctx | last_frame: if(render?, do: pixels, else: ctx.last_frame)})
    end

    ctx = %{
      ctx
      | state: state,
        ram: ram,
        hold: hold,
        apu: apu,
        audio: audio,
        frame: ctx.frame + 1,
        deadline: deadline,
        note: fade(ctx.note),
        last_frame: if(render?, do: pixels, else: ctx.last_frame)
    }

    loop(ctx |> remember() |> measure_fps())
  end

  # Two display paths. Half blocks: text, cursor at the top.
  # Graphics protocol: the image is transmitted under an alternating id —
  # the new one lands on top of the old, which is only erased afterwards
  # (no gap between two frames) — and the status line is anchored to the
  # terminal's last row.
  defp draw(%{gfx: true} = ctx, pixels, ram, held) do
    id = ctx.gfx_id
    old = 3 - id
    rows = with {r, _c} <- ctx.dims, do: r, else: (_ -> 24)

    {rgb, ghost} = Screen.to_rgb(pixels, ctx.palette, ctx.lcd, ctx.ghost)

    IO.write([
      "\e[H",
      Screen.kitty_rgb(rgb, id, rows - 1),
      "\e_Ga=d,d=I,i=#{old},q=2\e\\",
      "\e[#{rows};1H",
      status(ctx, ram, held)
    ])

    %{ctx | gfx_id: old, ghost: ghost}
  end

  # Half blocks stay ghost-free by design: the response curve turns the four
  # shades into hundreds of in-between colours, every cell then carries its
  # own SGR sequence, and the run-length trick that lets a terminal keep up
  # with 60 fps dies with it. The kitty path above pays nothing — it ships
  # RGB anyway.
  defp draw(ctx, pixels, ram, held) do
    IO.write(["\e[H", crlf(Screen.to_text(pixels, ctx.palette, ctx.lcd)), status(ctx, ram, held)])
    ctx
  end

  # The status line's ephemeral message goes out on its own.
  defp fade({_text, 0}), do: nil
  defp fade({text, left}), do: {text, left - 1}
  defp fade(nil), do: nil

  # The sound frame follows the picture frame; a player that has vanished
  # silences the sound without stopping the game. With no player, captured
  # triggers are discarded — the list must not swell for nothing.
  defp sound(ram, apu, audio), do: Audio.stream(audio, ram, apu)

  # ── The state of the keys ───────────────────────────────────────────────────

  # The answer to the kitty query: the terminal speaks the protocol. The
  # real state is only trustworthy with releases (bit 2 of the flags).
  defp apply_event({:kitty, flags}, ctx), do: %{ctx | kitty: Bitwise.band(flags, 2) != 0}

  # The terminal can display images: clear the half blocks and switch over —
  # the size constraint goes away with them.
  defp apply_event({:graphics, true}, ctx) do
    IO.write("\e[2J")
    %{ctx | gfx: true}
  end

  defp apply_event({:graphics, false}, ctx), do: ctx

  # ── The menu ────────────────────────────────────────────────────────────────

  # Escape or m opens it — the keys in flight are released, and the machine
  # will sleep for as long as it is there.
  defp apply_event({tag, :menu}, %{menu: nil} = ctx) when tag in [:key, :press],
    do: %{
      ctx
      | menu:
          Menu.open(
            ctx.state_slot,
            ctx.palette,
            Map.get(ctx.ram, :cgb, false),
            Map.get(ctx.ram, :mixer),
            ctx.lcd.preset
          ),
        down: MapSet.new(),
        hold: %{}
    }

  # Once open, the Game Boy keys drive it (repeats included — holding an
  # arrow scrolls through the slots).
  defp apply_event({tag, key}, %{menu: menu} = ctx)
       when menu != nil and tag in [:key, :press, :repeat] and
              key in [:up, :down, :left, :right, :a, :b, :menu] do
    {menu, actions} = Menu.press(ctx.menu, key)
    Enum.reduce(actions, %{ctx | menu: menu}, &menu_action/2)
  end

  defp apply_event({_tag, :menu}, ctx), do: ctx

  # The actions — on the rising edge only: press or keystroke, never the
  # repeat (holding p must not make the pause flicker).
  defp apply_event({tag, :save_state}, ctx) when tag in [:key, :press] do
    Library.save_state(
      ctx.lib,
      slot_name(ctx),
      {ctx.state, ctx.ram, ctx.apu},
      Library.screenshot(ctx.last_frame, ctx.palette, ctx.lcd)
    )

    %{ctx | note: {"state saved (slot #{ctx.state_slot})", 120}}
  end

  defp apply_event({tag, :load_state}, ctx) when tag in [:key, :press] do
    case Library.load_state(ctx.lib, slot_name(ctx)) do
      {:ok, {state, ram, apu}} ->
        # The current cable survives the trip through time.
        ram =
          case Map.get(ctx.ram, :link) do
            nil -> Map.delete(ram, :link)
            link -> Map.put(ram, :link, link)
          end

        %{
          ctx
          | state: state,
            ram: ram,
            apu: apu,
            note: {"state loaded (slot #{ctx.state_slot})", 120}
        }

      :error ->
        %{ctx | note: {"slot #{ctx.state_slot} empty", 120}}
    end
  end

  # The digits pick the current state slot — nine snapshots per game, slot 1
  # being the historical file.
  defp apply_event({tag, {:slot, n}}, ctx) when tag in [:key, :press],
    do: %{ctx | state_slot: n, note: {"state slot #{n}", 120}}

  defp apply_event({_tag, {:slot, _n}}, ctx), do: ctx

  # Turbo starves any audio player (production stopped, consumption
  # ongoing): we close ffplay on the way in and open a fresh one on the way
  # out — clean buffer, no inherited starvation.
  # The cable demands the tempo: two consoles in turbo drift apart and the
  # serial protocol tears — so turbo is unavailable while plugged in.
  defp apply_event({tag, :turbo}, ctx) when tag in [:key, :press] do
    if Map.has_key?(ctx.ram, :link) do
      %{ctx | note: {"turbo unavailable: link cable plugged in", 120}}
    else
      turbo_toggle(ctx)
    end
  end

  defp apply_event({tag, :pause}, ctx) when tag in [:key, :press],
    do: %{ctx | paused: not ctx.paused}

  defp apply_event({tag, :watch}, %{watch: nil} = ctx) when tag in [:key, :press],
    do: %{ctx | note: {"no cells to watch — run mix atomboy.live", 180}}

  defp apply_event({tag, :watch}, ctx) when tag in [:key, :press],
    do: %{ctx | watching: not ctx.watching}

  # The listener opens on `:` -- with the keys in flight released, because the
  # first letter of a cell's name must not also steer the game.
  defp apply_event({tag, :listen}, %{watch: nil} = ctx) when tag in [:key, :press],
    do: %{ctx | note: {"the listener needs names — run mix atomboy.live", 180}}

  defp apply_event({tag, :listen}, %{menu: nil} = ctx) when tag in [:key, :press],
    do: %{ctx | prompt: "", down: MapSet.new(), hold: %{}}

  defp apply_event({_tag, key}, ctx)
       when key in [:save_state, :load_state, :turbo, :pause, :watch, :listen],
       do: ctx

  defp apply_event({:release, key}, %{kitty: true} = ctx),
    do: %{ctx | down: MapSet.delete(ctx.down, key), hold: Map.delete(ctx.hold, key)}

  defp apply_event({tag, key}, %{kitty: true} = ctx) when tag in [:press, :repeat],
    do: %{ctx | down: MapSet.put(ctx.down, key)}

  # Under kitty, the bare press of an arrow ("ESC [ A") will get its release.
  defp apply_event({:key, key}, %{kitty: true} = ctx)
       when key in [:up, :down, :left, :right],
       do: %{ctx | down: MapSet.put(ctx.down, key)}

  # Classic regime: a keystroke with no known release → a held press.
  defp apply_event({tag, key}, ctx) when tag in [:key, :press, :repeat],
    do: %{ctx | hold: Map.put(ctx.hold, key, ctx.hold_frames)}

  # A release with no confirmed protocol: ignored.
  defp apply_event(_event, ctx), do: ctx

  # ── The listener's line editor ──────────────────────────────────────────────

  defp prompt_element({:char, c}, ctx), do: %{ctx | prompt: ctx.prompt <> <<c>>}
  defp prompt_element(:backspace, ctx), do: %{ctx | prompt: String.slice(ctx.prompt, 0..-2//1)}
  defp prompt_element(:cancel, ctx), do: %{ctx | prompt: nil}

  defp prompt_element(:enter, ctx) do
    if String.trim(ctx.prompt) == "" do
      %{ctx | prompt: nil}
    else
      case poke(ctx.watch, ctx.ram, ctx.prompt) do
        {:ok, ram, text} -> %{ctx | ram: ram, prompt: nil, note: {text, 150}}
        {:error, text} -> %{ctx | prompt: nil, note: {"× " <> text, 240}}
      end
    end
  end

  defp turbo_toggle(ctx) do
    turbo = not ctx.turbo

    audio =
      if turbo do
        Audio.close(ctx.audio)
        nil
      else
        if ctx.sound?, do: Audio.open()
      end

    %{ctx | turbo: turbo, audio: audio, deadline: System.monotonic_time(:microsecond) + @frame_us}
  end

  # The actions chosen in the menu take the same paths as the direct
  # shortcuts — the menu is only another way of pressing a key.
  defp menu_action(:save_state, ctx), do: apply_event({:key, :save_state}, ctx)
  defp menu_action(:load_state, ctx), do: apply_event({:key, :load_state}, ctx)
  defp menu_action({:slot, n}, ctx), do: apply_event({:key, {:slot, n}}, ctx)
  defp menu_action({:palette, p}, ctx), do: recompile(%{ctx | palette: p})
  defp menu_action({:panel, p}, ctx), do: recompile(%{ctx | lcd: %{ctx.lcd | preset: p}})

  # The mixer lives in the memory map: the APU folds it into its per-frame
  # config, and it travels along with saved states.
  defp menu_action({:mixer, m}, ctx), do: %{ctx | ram: Map.put(ctx.ram, :mixer, m)}
  # Quitting through the menu: the frame budget drops to zero remaining —
  # the loop concludes by the normal path (save written, terminal restored).
  defp menu_action(:quit, ctx), do: %{ctx | max_frames: ctx.frame}

  # Palette and panel both feed the same tables: whichever moved, they are
  # rebuilt. The game sleeps behind the menu, so the moment it costs on a
  # color cartridge goes unnoticed.
  defp recompile(ctx),
    do: %{
      ctx
      | lcd: LCD.compile(ctx.lcd.preset, ctx.palette, Map.get(ctx.ram, :cgb, false), ctx.dial),
        ghost: nil
    }

  # The slot as the library knows it — a reserved state name. In sidecar
  # fallback the library itself keeps the historical file names.
  defp slot_name(ctx), do: "slot-#{ctx.state_slot}"

  # The explicit \r before each \n: harmless when opost already translates,
  # a lifesaver if some environment turned it off — the display then depends
  # on no terminal output setting at all.
  defp crlf(text), do: :binary.replace(text, "\n", "\r\n", [:global])

  defp finish(ctx) do
    Save.flush(ctx.ram, ctx.sav)
    dump(ctx)
  end

  defp dump(%{dump: path, last_frame: pixels}) when is_binary(path) and is_binary(pixels) do
    File.write!(path, Screen.to_pgm(pixels))
  end

  defp dump(_ctx), do: :ok

  defp collect_input(acc) do
    receive do
      {:input, data} -> collect_input([acc | data])
      # The audio port's messages (output, exit status): of no interest, but
      # to be drained — a mailbox that swells slows everything down.
      {port, {:data, _}} when is_port(port) -> collect_input(acc)
      {port, {:exit_status, _}} when is_port(port) -> collect_input(acc)
    after
      0 -> IO.iodata_to_binary(acc)
    end
  end

  defp measure_fps(%{frame: n} = ctx) when rem(n, 30) == 0 do
    now = System.monotonic_time(:microsecond)
    %{ctx | fps: 30 * 1.0e6 / max(now - ctx.fps_mark, 1), fps_mark: now}
  end

  defp measure_fps(ctx), do: ctx

  defp status(ctx, ram, held) do
    bank = div(Map.get(ram, :rom_bank_base, 0x4000), 0x4000)
    keys = if held == [], do: "", else: " · " <> Enum.map_join(held, " ", &Atom.to_string/1)

    note =
      case ctx.note do
        {text, _left} -> " · #{text}"
        nil -> ""
      end

    lead =
      cond do
        ctx.prompt != nil ->
          " : " <> ctx.prompt <> "▮   "

        ctx.watching and ctx.watch ->
          " ⌚ " <> watch_line(ctx.watch, ram) <> "   "

        true ->
          " ✚ arrows · x A · c B · ⏎ Start · ␣ Select · s/r state · ⇥ turbo · p pause · w watch · q quit   "
      end

    [
      "\e[0m",
      lead,
      :io_lib.format(~c"~5.1f fps · bank ~2..0B", [ctx.fps, bank]),
      if(ctx.audio, do: " · ♪", else: ""),
      if(Map.has_key?(ram, :link), do: " · ⇄", else: ""),
      if(ctx.turbo, do: " · »»", else: ""),
      if(ctx.paused, do: " · ⏸ pause", else: ""),
      note,
      keys,
      "\e[K"
    ]
  end

  @doc """
  The watch's text: every named cell and the byte it holds, right now.

  The names come from `addresses/0` -- what `mix atomboy.live` knows about the
  game it built -- and the order is the cells' own: sorted by address, which is
  declaration order, because that is the order the author's eye already knows.
  Values are padded to three so the line holds still while they run.

  A pooled or arrayed name shows its first cell: the watch is a glance, not an
  inspector, and instance zero is the glance's answer.
  """
  @spec watch_line(%{atom() => non_neg_integer()}, map()) :: String.t()
  def watch_line(cells, ram) do
    cells
    |> Enum.sort_by(fn {_name, address} -> address end)
    |> Enum.map_join(" · ", fn {name, address} ->
      "#{name} #{String.pad_leading("#{Map.get(ram, address, 0)}", 3)}"
    end)
  end

  @doc """
  One sentence of the listener, applied to the machine.

  `x = 20` writes the byte into the named cell -- the game reads it on its
  very next frame, which is the whole point. `x` alone answers with the value,
  a read without a write. A negative takes the two's complement the language
  itself writes, so `vx = -1` at the prompt means what it means in the source.

  Returns `{:ok, ram, said}` or `{:error, said}` -- the machine is never
  half-written: a sentence that cannot be honoured whole changes nothing.
  """
  @spec poke(%{atom() => non_neg_integer()}, map(), String.t()) ::
          {:ok, map(), String.t()} | {:error, String.t()}
  def poke(cells, ram, line) do
    case line |> String.split("=", parts: 2) |> Enum.map(&String.trim/1) do
      [name, value] ->
        with {:ok, address} <- cell(cells, name),
             {:ok, byte} <- byte(value) do
          {:ok, Map.put(ram, address, byte), "#{name} ← #{byte}"}
        end

      [name] ->
        with {:ok, address} <- cell(cells, name) do
          {:ok, ram, "#{name} = #{Map.get(ram, address, 0)}"}
        end
    end
  end

  # The name against the cells the cartridge was built with. `to_existing_atom`
  # because the names all exist -- the watch map holds them -- and a typo must
  # not mint an atom per keystroke for the rest of the session.
  defp cell(cells, name) do
    address =
      try do
        Map.get(cells, String.to_existing_atom(name))
      rescue
        ArgumentError -> nil
      end

    case address do
      nil -> {:error, "no cell named #{name}"}
      address -> {:ok, address}
    end
  end

  defp byte(value) do
    case Integer.parse(value) do
      {n, ""} when n in 0..255 -> {:ok, n}
      {n, ""} when n in -128..-1 -> {:ok, 256 + n}
      {_n, ""} -> {:error, "a cell holds a byte: 0..255, or a negative down to -128"}
      _ -> {:error, "not a number: #{value}"}
    end
  end

  # ── The keyboard ────────────────────────────────────────────────────────────

  # The pty is opened right here: a :raw descriptor can only be read from
  # the process that opened it. Then one byte at a time, in a blocking read
  # outside Erlang's I/O stack — that read is the one a terminal in -icanon
  # wakes on every keystroke. End of stream (redirected input exhausted)
  # merely stops the reading: the game goes on with the joypad released.
  defp read_keys(parent, path) do
    case :file.open(String.to_charlist(path), [:read, :binary, :raw]) do
      {:ok, f} -> read_loop(parent, f)
      _ -> :ok
    end
  end

  defp read_loop(parent, f) do
    case :file.read(f, 1) do
      {:ok, data} ->
        send(parent, {:input, data})
        read_loop(parent, f)

      _eof_or_error ->
        :ok
    end
  end

  # ── The terminal ────────────────────────────────────────────────────────────

  # The name of this BEAM's pty — "ttys005" — through ps, the only link that
  # survives the setsid. nil with no terminal (redirected input, CI).
  defp pty_path do
    tty = :os.cmd(String.to_charlist("ps -o tty= -p #{System.pid()}"))
    tty = tty |> to_string() |> String.trim()
    if String.starts_with?(tty, "tty"), do: "/dev/#{tty}"
  end

  defp terminal_setup(tty) do
    saved =
      if tty do
        saved = tty |> stty("-g 2> /dev/null") |> :os.cmd() |> to_string() |> String.trim()
        :os.cmd(stty(tty, "-icanon -echo -isig min 1 time 0 2> /dev/null"))
        saved
      end

    IO.write("\e[?1049h\e[?25l\e[2J")

    # The kitty keyboard protocol, if it is spoken: push the flags
    # (1 disambiguate, 2 press/release events, 4 alternate keys, 8 all keys
    # as sequences) then query — the "CSI ? … u" answer confirms it, and the
    # releases give the real keyboard state (diagonals, chords). Flag 4 is
    # what lets a shifted key say what it *typed*: with 8 on, no plain bytes
    # arrive at all, so without it Shift-; is the code for ";" and a ":" is
    # untypable — the listener could never open. A mute terminal ignores the
    # whole thing: the frame-based hold stays in place.
    if tty, do: IO.write("\e[>15u\e[?u")

    # And the graphics protocol: transmit one pixel as a query (a=q) —
    # "OK" in reply = real images rather than half blocks.
    if tty, do: IO.write("\e_Gi=31,a=q,t=d,f=24,s=1,v=1;AAAA\e\\")
    saved
  end

  defp terminal_restore(tty, saved) do
    if tty, do: IO.write("\e[<u")
    IO.write("\e[?1049l\e[?25h\e[0m")

    if tty do
      restore = if saved && saved =~ ~r/^[\w:=,.-]+$/, do: saved, else: "sane"
      :os.cmd(stty(tty, "#{restore} 2> /dev/null"))
    end

    :ok
  end

  # macOS says `stty -f file`, GNU says `stty -F file`.
  defp stty(tty, args) do
    flag = if match?({:unix, :linux}, :os.type()), do: "-F", else: "-f"
    String.to_charlist("stty #{flag} #{tty} #{args}")
  end
end
