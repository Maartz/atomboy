defmodule Atomboy.Server do
  @moduledoc """
  Server mode: atomboy as the engine behind a native shell.

  The shell (SwiftUI on macOS, or anything that can read a pipe) launches
  `atomboy rom.gb --server` and speaks a minimal binary protocol:

  ## Output (stdout)

      <<?F, rgb::binary-69120>>          one 160×144 frame in RGB24
      <<?A, n::16-big, pcm::binary-n>>   s16le stereo PCM at 32,768 Hz

  The RGB comes out of the same `Screen.to_rgb` as the window — palette
  included, overlay menu included: the shell draws, it knows nothing. The
  PCM follows the wall clock's anti-starvation pacing (`Audio.cadence`);
  the shell plays it as it comes. Status messages (the cable…) go to
  stderr — stdout stays a pure binary stream.

  ## Input (stdin)

  Two-byte records: `<<op, key>>`, where `op` is `?+` (press) or `?-`
  (release). Keys: `?U ?D ?L ?R` the directions, `?A ?B` the buttons, `?S`
  Start, `?E` Select, `?M` the menu, `?W` rewind (held), `?P` pause — plus
  the direct actions for the native menu bar: `?s`/`?r` save/load state,
  `?1`-`?9` the slot. Two operations carry a value rather than a key:
  `<<?V, v>>` sets the mixer volume (0-100), `<<?X, mask>>` the four voices
  (bits 0-3) — the shell's native panel uses these. The end of input (shell
  closed) stops the game cleanly — save written.

  Everything else is the usual machinery: menu inside the frame, states,
  mixer, link cable (`--listen`/`--link` work in server mode too).
  """

  import Bitwise

  alias Atomboy.Codes
  alias Atomboy.APU
  alias Atomboy.Joypad
  alias Atomboy.Link
  alias Atomboy.Menu
  alias Atomboy.Play.Audio
  alias Atomboy.Play.Input
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
    sav = Save.path(rom_path, Keyword.get(opts, :save))

    with {:ok, link} <- link_up(opts) do
      # stdout is a binary stream: in Unicode (the BEAM's default), every
      # byte ≥ 128 would become two UTF-8 bytes — torn frames.
      :io.setopts(:standard_io, encoding: :latin1)

      parent = self()
      reader = spawn_link(fn -> read_stdin(parent) end)

      try do
        loop(%{
          state: Screen.boot_state(rom, Keyword.get(opts, :dmg, false)),
          rom: rom,
          ram:
            Screen.boot_ram(rom, Keyword.get(opts, :dmg, false))
            |> then(&if(link, do: Map.put(&1, :link, link), else: &1))
            |> Save.load(sav)
            |> Codes.installe(Codes.analyse(Keyword.get(opts, :codes, ""))),
          sav: sav,
          state_base: Path.rootname(sav),
          state_slot: 1,
          palette: Keyword.get(opts, :palette, :dmg),
          down: MapSet.new(),
          menu: nil,
          apu: %APU{},
          audio: %{t0: System.monotonic_time(:microsecond), sent: 0},
          frame: 0,
          max_frames: Keyword.get(opts, :frames, :infinity),
          history: [],
          last_frame: nil,
          turbo: false,
          deadline: System.monotonic_time(:microsecond) + @frame_us
        })
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

    # In turbo: one frame emitted in four, no PCM, no deadline.
    render? = not ctx.turbo or rem(ctx.frame, 4) == 0

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

    if render?, do: emit_frame(pixels, ctx.palette)

    deadline =
      if ctx.turbo do
        ctx.deadline
      else
        now = System.monotonic_time(:microsecond)
        deadline = max(ctx.deadline, now - 100_000)
        if deadline > now + 999, do: Process.sleep(div(deadline - now, 1000))
        deadline + @frame_us
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

  defp emit_frame(pixels, palette) do
    IO.binwrite(:stdio, [<<?F>>, Screen.to_rgb(pixels, palette)])
  end

  defp menu_idle(ctx) do
    if ctx.last_frame do
      emit_frame(Menu.render(ctx.menu, ctx.last_frame), ctx.palette)
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
    emit_frame(pixels, ctx.palette)

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

      {:codes, string} ->
        drain(%{ctx | ram: Codes.installe(ctx.ram, Codes.analyse(string))})

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
            Map.get(ctx.ram, :mixer)
          ),
        down: MapSet.new()
    }

  defp press(ctx, ?+, :pause), do: press(ctx, ?+, :menu)

  # Turbo: unavailable with the cable plugged in (the serial protocol
  # demands the tempo); on the way out, the audio pacing restarts from zero
  # — no catch-up burst inherited from the sprint.
  defp press(ctx, ?+, :turbo) do
    cond do
      Map.has_key?(ctx.ram, :link) ->
        ctx

      ctx.turbo ->
        %{
          ctx
          | turbo: false,
            audio: %{t0: System.monotonic_time(:microsecond), sent: 0},
            deadline: System.monotonic_time(:microsecond) + @frame_us
        }

      true ->
        %{ctx | turbo: true}
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
    Save.write_state(state_path(ctx), {ctx.state, ctx.ram, ctx.apu})
    ctx
  end

  defp menu_action(:load_state, ctx) do
    case Save.read_state(state_path(ctx)) do
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

  defp menu_action({:slot, n}, ctx), do: %{ctx | state_slot: n}
  defp menu_action({:palette, p}, ctx), do: %{ctx | palette: p}
  defp menu_action({:mixer, m}, ctx), do: %{ctx | ram: Map.put(ctx.ram, :mixer, m)}
  defp menu_action(:quit, _ctx), do: :quit

  # Slot 1 keeps the historical file name; the ".caseN" of slots 2-9 is the
  # on-disk convention `Atomboy.Save` also spells out.
  defp state_path(ctx) do
    if ctx.state_slot == 1 do
      ctx.state_base <> ".state"
    else
      ctx.state_base <> ".case#{ctx.state_slot}.state"
    end
  end

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

      {:ok, <<op, key>>} ->
        send(parent, {:key, op, key})
        read_loop(parent, f)

      _eof ->
        send(parent, :stdin_closed)
    end
  end
end
