defmodule Atomboy.Server do
  @moduledoc """
  Server mode: atomboy as the engine behind a native shell.

  The shell (SwiftUI on macOS, or anything that can read a pipe) launches
  `atomboy rom.gb --server` and speaks a minimal binary protocol:

  ## Output (stdout)

      <<?F, rgb::binary-69120>>          one 160×144 frame in RGB24
      <<?A, n::16-big, pcm::binary-n>>   s16le stereo PCM at 32,768 Hz
      <<?P, preset>>                     the panel, announced

  The RGB comes out of the same `Screen.to_rgb` as the window — palette
  included, overlay menu included: the shell draws, it knows nothing. The
  PCM follows the wall clock's anti-starvation pacing (`Audio.cadence`);
  the shell plays it as it comes. Status messages (the cable…) go to
  stderr — stdout stays a pure binary stream.

  `?P` carries the index into `Atomboy.LCD.presets/0` (0 raw, 1 dmg,
  2 pocket, 3 cgb), sent before the first frame and again whenever the
  menu changes it. It exists because the response curve does *not* run
  here: unlike the window, the server ships its frames un-ghosted. The
  shell owns the display, so the shell owns time — its shader applies the
  panel's response per RGB channel (which covers colour games, where the
  Elixir pass never could) and the dot structure with it. A shell that
  ignores `?P` simply draws sharp frames through the panel's colours.

  ## Input (stdin)

  Two-byte records: `<<op, key>>`, where `op` is `?+` (press) or `?-`
  (release). Keys: `?U ?D ?L ?R` the directions, `?A ?B` the buttons, `?S`
  Start, `?E` Select, `?M` the menu, `?W` rewind (held), `?P` pause — plus
  the direct actions for the native menu bar: `?s`/`?r` save/load state,
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

  Everything else is the usual machinery: menu inside the frame, states,
  mixer, link cable (`--listen`/`--link` work in server mode too).
  """

  import Bitwise

  alias Atomboy.Codes
  alias Atomboy.APU
  alias Atomboy.Joypad
  alias Atomboy.LCD
  alias Atomboy.Library
  alias Atomboy.Link
  alias Atomboy.Menu
  alias Atomboy.Play.Audio
  alias Atomboy.Play.Input
  alias Atomboy.Play.Turbo
  alias Atomboy.PPU
  alias Atomboy.Save
  alias Atomboy.Screen

  @frame_us 16_742

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
            # What a power cycle must remember: the machine flags of boot.
            reset: %{
              dmg: Keyword.get(opts, :dmg, false),
              codes: Keyword.get(opts, :codes, "")
            },
            deadline: System.monotonic_time(:microsecond) + @frame_us
          })
        )
      after
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
      :quit -> finish(ctx)
      ctx when ctx.menu != nil -> menu_idle(ctx)
      ctx -> if MapSet.member?(ctx.down, :rewind), do: rewind_step(ctx), else: step(ctx)
    end
  end

  defp finish(ctx) do
    Save.flush(ctx.ram, ctx.sav)
    :ok
  end

  defp step(ctx) do
    held = MapSet.to_list(ctx.down)
    ram = Joypad.set(ctx.ram, Input.dpad_lines(held), Input.button_lines(held))
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

  defp rewind_step(ctx) do
    ctx =
      case ctx.history do
        [{state, ram, apu} | rest] -> %{ctx | state: state, ram: ram, apu: apu, history: rest}
        [] -> ctx
      end

    pixels = PPU.render_frame(ctx.ram)
    ctx = emit_frame(ctx, pixels)

    now = System.monotonic_time(:microsecond)
    deadline = max(ctx.deadline, now - 100_000)
    if deadline > now + 999, do: Process.sleep(div(deadline - now, 1000))

    loop(%{ctx | last_frame: pixels, deadline: deadline + @frame_us})
  end

  defp remember(%{frame: n} = ctx) when rem(n, 10) == 0 do
    %{ctx | history: Enum.take([{ctx.state, ctx.ram, ctx.apu} | ctx.history], 240)}
  end

  defp remember(ctx), do: ctx

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

      # The contrast dial: ?G carries 0-100; anything above returns the
      # panel to its resting point. The tables recompile mid-frame.
      {:key, ?G, v} ->
        drain(recompile(%{ctx | dial: if(v <= 100, do: v, else: nil)}))

      # The turbo speed: ?T carries 2, 4 or 8 — or 0, the suspended
      # deadline turbo has always run at. A multiplier nobody knows leaves
      # the speed where it stands.
      {:key, ?T, value} ->
        drain(turbo_speed(ctx, value))

      # The save browser: list, save, load, delete, profile, export.
      {:library, :list} ->
        drain(emit_library(ctx))

      {:library, :save, name} ->
        Library.save_state(
          ctx.lib,
          name,
          {ctx.state, ctx.ram, ctx.apu},
          Library.screenshot(ctx.last_frame, ctx.palette, ctx.lcd)
        )

        drain(emit_library(ctx))

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
            ctx.lcd.preset
          ),
        down: MapSet.new()
    }

  defp press(ctx, ?+, :pause), do: press(ctx, ?+, :menu)

  # Turbo is held, not latched: the shell sends `+T` while the key or the
  # shoulder is down and `-T` when it comes up. Unavailable with the cable
  # plugged in (the serial protocol demands the tempo); on the way out, the
  # audio pacing restarts from zero — no catch-up burst inherited from the
  # sprint.
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

  defp menu_action(:save_state, ctx) do
    Library.save_state(
      ctx.lib,
      slot_name(ctx),
      {ctx.state, ctx.ram, ctx.apu},
      Library.screenshot(ctx.last_frame, ctx.palette, ctx.lcd)
    )

    ctx
  end

  defp menu_action(:load_state, ctx), do: load_named(ctx, slot_name(ctx))

  defp menu_action({:slot, n}, ctx), do: %{ctx | state_slot: n}
  defp menu_action({:palette, p}, ctx), do: recompile(%{ctx | palette: p})
  defp menu_action({:panel, p}, ctx), do: recompile(%{ctx | lcd: %{ctx.lcd | preset: p}})
  defp menu_action({:mixer, m}, ctx), do: %{ctx | ram: Map.put(ctx.ram, :mixer, m)}
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

  # A state by name — the current cable survives the trip through time.
  defp load_named(ctx, name) do
    case Library.load_state(ctx.lib, name) do
      {:ok, {state, ram, apu}} ->
        ram =
          case Map.get(ctx.ram, :link) do
            nil -> Map.delete(ram, :link)
            link -> Map.put(ram, :link, link)
          end

        %{ctx | state: state, ram: ram, apu: apu}

      :error ->
        ctx
    end
  end

  # Switching profile is handing the console to the other player: the
  # battery flushed, the machine reset from boot on the other cartridge —
  # cable and mixer surviving, they belong to the table, not the game.
  defp power_cycle(ctx, profile) do
    Save.flush(ctx.ram, ctx.sav)
    lib = Library.set_profile(ctx.lib, profile)
    sav = Library.sav_path(lib)

    ram =
      Screen.boot_ram(ctx.rom, ctx.reset.dmg)
      |> then(&if(link = Map.get(ctx.ram, :link), do: Map.put(&1, :link, link), else: &1))
      |> then(&if(mixer = Map.get(ctx.ram, :mixer), do: Map.put(&1, :mixer, mixer), else: &1))
      |> Save.load(sav)
      |> Codes.installe(Codes.analyse(ctx.reset.codes))

    %{
      ctx
      | lib: lib,
        sav: sav,
        ram: ram,
        state: Screen.boot_state(ctx.rom, ctx.reset.dmg),
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
  defp read_stdin(parent) do
    case :file.open(~c"/dev/fd/0", [:read, :binary, :raw]) do
      {:ok, f} -> read_loop(parent, f)
      _ -> send(parent, :stdin_closed)
    end
  end

  defp read_loop(parent, f) do
    case :file.read(f, 2) do
      # ?C: the GameShark codes — a length, then the ASCII list, which
      # REPLACES the active set (an empty list clears everything).
      {:ok, <<?C, len>>} ->
        string =
          case :file.read(f, len) do
            {:ok, data} when len > 0 -> data
            _ -> ""
          end

        send(parent, {:codes, string})
        read_loop(parent, f)

      # The library ops: L and E stand alone, K/O/D/F carry a name.
      {:ok, <<?L, _>>} ->
        send(parent, {:library, :list})
        read_loop(parent, f)

      {:ok, <<?E, _>>} ->
        send(parent, {:library, :export})
        read_loop(parent, f)

      {:ok, <<op, len>>} when op in ~c"KODF" ->
        name =
          case :file.read(f, len) do
            {:ok, data} when len > 0 -> data
            _ -> ""
          end

        verb = %{?K => :save, ?O => :load, ?D => :delete, ?F => :profile}
        send(parent, {:library, Map.fetch!(verb, op), name})
        read_loop(parent, f)

      {:ok, <<op, key>>} ->
        send(parent, {:key, op, key})
        read_loop(parent, f)

      _eof ->
        send(parent, :stdin_closed)
    end
  end
end
