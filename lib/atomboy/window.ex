defmodule Atomboy.Window do
  @moduledoc """
  The Game Boy in a real window — wxWidgets, shipped with OTP.

  The window wipes out in one stroke every hard-won conquest of the
  terminal: no pty to track down through `ps`, no `-noinput`, no keyboard
  protocol to negotiate — wx delivers the **real** press/release events of
  every key. The keyboard state is exact by construction, and so are the
  diagonals.

  ## The architecture

  The game loop lives in the process that created the window: wx events
  arrive in its mailbox, drained every frame just like the terminal's
  keyboard. Rendering goes through an ETS table: the loop drops the frame's
  RGB there and asks for a refresh; the paint *callback* — run by the wx
  thread, never blocked by the loop — reads it, scales it to the window
  (nearest neighbour: crisp pixels, not blur) and draws it.

  Same keys as in the terminal: arrows, x/c, Enter, Space, s/r state, Tab
  turbo, p pause, q or Escape to quit — plus the window's close button.
  Sound still goes through ffplay. The status line becomes the window title.
  """

  alias Atomboy.APU
  alias Atomboy.Codes
  alias Atomboy.Joypad
  alias Atomboy.LCD
  alias Atomboy.Library
  alias Atomboy.Link
  alias Atomboy.Menu
  alias Atomboy.Play.Audio
  alias Atomboy.Play.Input
  alias Atomboy.PPU
  alias Atomboy.Save
  alias Atomboy.Screen

  require Record
  Record.defrecordp(:wx, Record.extract(:wx, from_lib: "wx/include/wx.hrl"))
  Record.defrecordp(:wxKey, Record.extract(:wxKey, from_lib: "wx/include/wx.hrl"))
  Record.defrecordp(:wxClose, Record.extract(:wxClose, from_lib: "wx/include/wx.hrl"))

  @frame_us 16_742
  @scale 3
  # wxWANTS_CHARS: without it, the arrows navigate between widgets.
  @wants_chars 0x00040000

  # WXK_LEFT..WXK_DOWN, and the letters in capitals — the wx codes.
  @keys %{
    314 => :left,
    315 => :up,
    316 => :right,
    317 => :down,
    ?X => :a,
    ?C => :b,
    13 => :start,
    ?\s => :select,
    # WXK_BACK: Backspace — rewinding, held down.
    8 => :rewind
  }
  @actions %{?S => :save_state, ?R => :load_state, 9 => :turbo, ?P => :pause}
           |> Map.merge(for n <- 1..9, into: %{}, do: {?0 + n, {:slot, n}})
           # Escape and M open the menu — quitting lives on Q and in the menu.
           |> Map.merge(%{27 => :menu, ?M => :menu})
  @quits [?Q]

  @doc "Plays `rom_path` in a window. Same options as the terminal."
  @spec run(Path.t(), keyword()) :: :ok | {:error, String.t()}
  def run(rom_path, opts \\ []) do
    rom = Screen.load(rom_path)
    lib = Library.open(rom, rom_path, opts)
    sav = Library.sav_path(lib)

    link =
      cond do
        port = Keyword.get(opts, :listen) ->
          case Link.listen(port) do
            {:ok, l} -> l
            {:error, m} -> throw({:link, m})
          end

        target = Keyword.get(opts, :link) ->
          {host, port} =
            case String.split(target, ":") do
              [h, p] -> {h, String.to_integer(p)}
              [h] -> {h, Link.default_port()}
            end

          case Link.connect(host, port) do
            {:ok, l} -> l
            {:error, m} -> throw({:link, m})
          end

        true ->
          nil
      end

    :wx.new()
    {width, height} = Atomboy.PPU.dimensions()
    frame_w = :wxFrame.new(:wx.null(), -1, ~c"atomboy")
    :wxFrame.setClientSize(frame_w, {width * @scale, height * @scale})
    panel = :wxPanel.new(frame_w, style: @wants_chars)

    table = :ets.new(:atomboy_frame, [:public, :set])
    :wxPanel.connect(panel, :paint, callback: fn _evt, _obj -> paint(panel, table) end)
    :wxPanel.connect(panel, :key_down)
    :wxPanel.connect(panel, :key_up)
    :wxFrame.connect(frame_w, :close_window)
    :wxFrame.show(frame_w)
    :wxWindow.setFocus(panel)

    audio = if Keyword.get(opts, :sound, true), do: Audio.open()

    ram =
      Screen.boot_ram(rom, Keyword.get(opts, :dmg, false))
      |> then(&if(link, do: Map.put(&1, :link, link), else: &1))
      |> Save.load(sav)
      |> Codes.installe(Codes.analyse(Keyword.get(opts, :codes, "")))

    palette = Keyword.get(opts, :palette, :dmg)

    ctx = %{
      state: Screen.boot_state(rom, Keyword.get(opts, :dmg, false)),
      rom: rom,
      ram: ram,
      sav: sav,
      lib: lib,
      state_slot: 1,
      palette: palette,
      # The panel's tables — compiled once, here, because the color table
      # is a hundred kilobytes a monochrome game would never read.
      lcd:
        LCD.compile(
          Keyword.get(opts, :panel, :raw),
          palette,
          Map.get(ram, :cgb, false),
          Keyword.get(opts, :dial)
        ),
      dial: Keyword.get(opts, :dial),
      # The response curve's per-pixel state — nil until the first ghosted
      # frame, dropped back to nil whenever the panel changes.
      ghost: nil,
      down: MapSet.new(),
      audio: audio,
      sound?: audio != nil,
      apu: %APU{},
      frame: 0,
      max_frames: Keyword.get(opts, :frames, :infinity),
      dump: Keyword.get(opts, :dump),
      turbo: false,
      paused: false,
      menu: nil,
      history: [],
      note: nil,
      last_frame: nil,
      fps: 0.0,
      fps_mark: System.monotonic_time(:microsecond),
      deadline: System.monotonic_time(:microsecond) + @frame_us,
      window: frame_w,
      panel: panel,
      table: table
    }

    try do
      loop(ctx)
    after
      Link.close(link)
      Audio.close(audio)
      :wx.destroy()
    end

    :ok
  catch
    {:link, message} -> {:error, message}
  end

  # ── The loop ────────────────────────────────────────────────────────────────

  defp loop(%{frame: n, max_frames: max} = ctx) when n >= max, do: finish(ctx)

  defp loop(ctx) do
    case drain(ctx) do
      :quit -> finish(ctx)
      ctx when ctx.menu != nil -> menu_idle(ctx)
      ctx when ctx.paused -> idle(ctx)
      ctx -> if MapSet.member?(ctx.down, :rewind), do: rewind_step(ctx), else: step(ctx)
    end
  end

  # Menu open: the machine sleeps, and the last frame carries the menu as an
  # overlay — same rendering as the game, the painter knows nothing of it.
  defp menu_idle(ctx) do
    ctx =
      if ctx.last_frame do
        composed = Menu.render(ctx.menu, ctx.last_frame)
        {rgb, ghost} = Screen.to_rgb(composed, ctx.palette, ctx.lcd, ctx.ghost)
        :ets.insert(ctx.table, {:frame, rgb})
        :wxWindow.refresh(ctx.panel, eraseBackground: false)
        %{ctx | ghost: ghost}
      else
        ctx
      end

    Process.sleep(50)
    loop(%{ctx | deadline: System.monotonic_time(:microsecond) + @frame_us})
  end

  # One step backwards: pop a snapshot (ten frames of play) and draw it as
  # it stands — the machine is not running, time is going back.
  defp rewind_step(ctx) do
    ctx =
      case ctx.history do
        [{state, ram, apu} | rest] ->
          %{ctx | state: state, ram: ram, apu: apu, history: rest}

        [] ->
          ctx
      end

    pixels = PPU.render_frame(ctx.ram)
    {rgb, ghost} = Screen.to_rgb(pixels, ctx.palette, ctx.lcd, ctx.ghost)
    ctx = %{ctx | ghost: ghost}
    :ets.insert(ctx.table, {:frame, rgb})
    :wxWindow.refresh(ctx.panel, eraseBackground: false)
    :wxFrame.setTitle(ctx.window, ~c"atomboy — ⏪ rewind")

    now = System.monotonic_time(:microsecond)
    deadline = max(ctx.deadline, now - 100_000)
    if deadline > now + 999, do: Process.sleep(div(deadline - now, 1000))

    loop(%{ctx | last_frame: pixels, deadline: deadline + @frame_us})
  end

  # The memory of rewinding: one snapshot every ten frames, a ring of 240 —
  # forty seconds, structurally shared.
  defp remember(%{frame: n} = ctx) when rem(n, 10) == 0 do
    %{ctx | history: Enum.take([{ctx.state, ctx.ram, ctx.apu} | ctx.history], 240)}
  end

  defp remember(ctx), do: ctx

  defp idle(ctx) do
    Process.sleep(50)
    loop(%{ctx | deadline: System.monotonic_time(:microsecond) + @frame_us})
  end

  defp step(ctx) do
    held = MapSet.to_list(ctx.down)
    ram = Joypad.set(ctx.ram, Input.dpad_lines(held), Input.button_lines(held))
    ram = Codes.applique(ram)

    render? = not ctx.turbo or rem(ctx.frame, 4) == 0

    # A derailment kills the game, not the progress: the cartridge's battery
    # is written before letting the crash report fly.
    {pixels, state, ram} =
      try do
        Screen.frame(ctx.state, ctx.rom, ram, render?)
      rescue
        e in [Atomboy.CPU.Unimplemented, Atomboy.CPU.Derailed] ->
          Save.flush(ram, ctx.sav)
          reraise e, __STACKTRACE__
      end

    {ram, apu, audio} = sound(ram, ctx.apu, ctx.audio)

    ctx =
      if render? do
        {rgb, ghost} = Screen.to_rgb(pixels, ctx.palette, ctx.lcd, ctx.ghost)
        :ets.insert(ctx.table, {:frame, rgb})
        :wxWindow.refresh(ctx.panel, eraseBackground: false)
        title(ctx, ram)
        %{ctx | ghost: ghost}
      else
        ctx
      end

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

    ctx = %{
      ctx
      | state: state,
        ram: ram,
        apu: apu,
        audio: audio,
        frame: ctx.frame + 1,
        deadline: deadline,
        note: fade(ctx.note),
        last_frame: if(render?, do: pixels, else: ctx.last_frame)
    }

    loop(ctx |> remember() |> measure_fps())
  end

  # ── The wx events ───────────────────────────────────────────────────────────

  defp drain(ctx) do
    receive do
      wx(event: wxKey(type: :key_down, keyCode: code)) ->
        case on_key(ctx, code) do
          :quit -> :quit
          ctx -> drain(ctx)
        end

      wx(event: wxKey(type: :key_up, keyCode: code)) ->
        drain(%{ctx | down: MapSet.delete(ctx.down, Map.get(@keys, code, :none))})

      wx(event: wxClose()) ->
        :quit

      wx() ->
        drain(ctx)
    after
      0 -> ctx
    end
  end

  defp on_key(_ctx, code) when code in @quits, do: :quit

  # Menu open: the Game Boy keys drive it, everything else waits.
  defp on_key(%{menu: menu} = ctx, code) when menu != nil do
    key =
      case Map.get(@keys, code) do
        nil -> if Map.get(@actions, code) == :menu, do: :menu
        key -> key
      end

    if key do
      {menu, actions} = Menu.press(ctx.menu, key)

      case Enum.reduce(actions, %{ctx | menu: menu}, &menu_action/2) do
        :quit -> :quit
        ctx -> ctx
      end
    else
      ctx
    end
  end

  defp on_key(ctx, code) do
    cond do
      key = Map.get(@keys, code) ->
        %{ctx | down: MapSet.put(ctx.down, key)}

      action = Map.get(@actions, code) ->
        act(ctx, action)

      true ->
        ctx
    end
  end

  defp act(ctx, :save_state) do
    Library.save_state(
      ctx.lib,
      slot_name(ctx),
      {ctx.state, ctx.ram, ctx.apu},
      Library.screenshot(ctx.last_frame, ctx.palette, ctx.lcd)
    )

    %{ctx | note: {"state saved (slot #{ctx.state_slot})", 120}}
  end

  defp act(ctx, :load_state) do
    case Library.load_state(ctx.lib, slot_name(ctx)) do
      {:ok, {state, ram, apu}} ->
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

  defp act(ctx, {:slot, n}), do: %{ctx | state_slot: n, note: {"state slot #{n}", 120}}

  defp act(ctx, :menu),
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

  defp act(ctx, :turbo) do
    if Map.has_key?(ctx.ram, :link) do
      %{ctx | note: {"turbo unavailable: link cable plugged in", 120}}
    else
      turbo_toggle(ctx)
    end
  end

  defp act(ctx, :pause), do: %{ctx | paused: not ctx.paused}

  # The actions chosen in the menu take the same paths as the direct
  # shortcuts — the menu is only another way of pressing a key.
  defp menu_action(_action, :quit), do: :quit
  defp menu_action(:save_state, ctx), do: act(ctx, :save_state)
  defp menu_action(:load_state, ctx), do: act(ctx, :load_state)
  defp menu_action({:slot, n}, ctx), do: act(ctx, {:slot, n})
  defp menu_action({:palette, p}, ctx), do: recompile(%{ctx | palette: p})
  defp menu_action({:panel, p}, ctx), do: recompile(%{ctx | lcd: %{ctx.lcd | preset: p}})
  defp menu_action({:mixer, m}, ctx), do: %{ctx | ram: Map.put(ctx.ram, :mixer, m)}
  defp menu_action(:quit, _ctx), do: :quit

  # Palette and panel both feed the same tables: whichever moved, they are
  # rebuilt. The game is paused behind the menu, so the moment it costs on a
  # color cartridge goes unnoticed.
  defp recompile(ctx),
    do: %{
      ctx
      | lcd: LCD.compile(ctx.lcd.preset, ctx.palette, Map.get(ctx.ram, :cgb, false), ctx.dial),
        ghost: nil
    }

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

  # The slot as the library knows it — a reserved state name. In sidecar
  # fallback the library itself keeps the historical file names.
  defp slot_name(ctx), do: "slot-#{ctx.state_slot}"

  # ── Rendering ───────────────────────────────────────────────────────────────

  # Run by the wx thread: read the last frame, stretch it with nearest
  # neighbour (wxIMAGE_QUALITY_NEAREST = 0), draw it.
  defp paint(panel, table) do
    dc = :wxPaintDC.new(panel)

    case :ets.lookup(table, :frame) do
      [{:frame, rgb}] ->
        {width, height} = Atomboy.PPU.dimensions()
        {pw, ph} = :wxWindow.getClientSize(panel)
        image = :wxImage.new(width, height, rgb)
        scaled = :wxImage.scale(image, max(pw, 1), max(ph, 1), quality: 0)
        bitmap = :wxBitmap.new(scaled)
        :wxDC.drawBitmap(dc, bitmap, {0, 0})
        :wxBitmap.destroy(bitmap)
        :wxImage.destroy(scaled)
        :wxImage.destroy(image)

      _ ->
        :ok
    end

    :wxPaintDC.destroy(dc)
    :ok
  end

  defp title(%{frame: n} = ctx, ram) when rem(n, 30) == 0 do
    bank = div(Map.get(ram, :rom_bank_base, 0x4000), 0x4000)

    extras =
      [
        if(ctx.turbo, do: "»»"),
        if(ctx.paused, do: "⏸"),
        if(ctx.audio, do: "♪"),
        if(Map.has_key?(ram, :link), do: "⇄"),
        case ctx.note do
          {text, _} -> text
          nil -> nil
        end
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.map_join("", &(" · " <> &1))

    fps = :io_lib.format(~c"~.1f", [ctx.fps])
    :wxFrame.setTitle(ctx.window, ~c"atomboy — #{fps} fps · bank #{bank}#{extras}")
  end

  defp title(_ctx, _ram), do: :ok

  # ── The rest, as in the terminal ────────────────────────────────────────────

  defp sound(ram, apu, audio), do: Audio.stream(audio, ram, apu)

  defp finish(ctx) do
    Save.flush(ctx.ram, ctx.sav)

    with path when is_binary(path) <- ctx.dump,
         pixels when is_binary(pixels) <- ctx.last_frame do
      File.write!(path, Screen.to_pgm(pixels))
    end

    :ok
  end

  defp fade({_text, 0}), do: nil
  defp fade({text, left}), do: {text, left - 1}
  defp fade(nil), do: nil

  defp measure_fps(%{frame: n} = ctx) when rem(n, 30) == 0 do
    now = System.monotonic_time(:microsecond)
    %{ctx | fps: 30 * 1.0e6 / max(now - ctx.fps_mark, 1), fps_mark: now}
  end

  defp measure_fps(ctx), do: ctx
end
