defmodule Atomboy.Window do
  @moduledoc """
  La Game Boy dans une vraie fenêtre — wxWidgets, livré avec OTP.

  La fenêtre efface d'un coup toutes les conquêtes durement gagnées du
  terminal : pas de pty à retrouver par `ps`, pas de `-noinput`, pas de
  protocole clavier à négocier — wx livre les **vrais** événements
  presse/relâchement de chaque touche. L'état du clavier est exact par
  construction, les diagonales aussi.

  ## L'architecture

  La boucle de jeu vit dans le processus qui a créé la fenêtre : les
  événements wx arrivent dans sa boîte aux lettres, drainés à chaque frame
  comme le clavier du terminal. Le rendu passe par une table ETS : la
  boucle y dépose le RGB de la frame et demande un rafraîchissement ; le
  *callback* de peinture — exécuté par le thread wx, jamais bloqué par la
  boucle — le lit, le met à l'échelle de la fenêtre (au plus proche voisin :
  du pixel net, pas du flou) et le dessine.

  Mêmes touches qu'au terminal : flèches, x/c, Entrée, Espace, s/r état,
  Tab turbo, p pause, q ou Échap pour quitter — et la croix de la fenêtre.
  Le son garde ffplay. La ligne de statut devient le titre de la fenêtre.
  """

  alias Atomboy.APU
  alias Atomboy.Joypad
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
  # wxWANTS_CHARS : sans lui, les flèches servent à naviguer les widgets.
  @wants_chars 0x00040000

  # WXK_LEFT..WXK_DOWN, et les lettres en majuscules — les codes wx.
  @keys %{
    314 => :left,
    315 => :up,
    316 => :right,
    317 => :down,
    ?X => :a,
    ?C => :b,
    13 => :start,
    ?\s => :select,
    # WXK_BACK : Retour arrière — le rembobinage, tenu.
    8 => :rewind
  }
  @actions %{?S => :save_state, ?R => :load_state, 9 => :turbo, ?P => :pause}
             |> Map.merge(for n <- 1..9, into: %{}, do: {?0 + n, {:slot, n}})
             # Échap et M ouvrent le menu — quitter vit sur Q et dans le menu.
             |> Map.merge(%{27 => :menu, ?M => :menu})
  @quits [?Q]

  @doc "Joue `rom_path` dans une fenêtre. Mêmes options que le terminal."
  @spec run(Path.t(), keyword()) :: :ok | {:error, String.t()}
  def run(rom_path, opts \\ []) do
    rom = Screen.load(rom_path)
    sav = Save.path(rom_path, Keyword.get(opts, :sauvegarde))

    link =
      cond do
        port = Keyword.get(opts, :ecoute) ->
          case Link.listen(port) do
            {:ok, l} -> l
            {:error, m} -> throw({:lien, m})
          end

        lien = Keyword.get(opts, :lien) ->
          {host, port} =
            case String.split(lien, ":") do
              [h, p] -> {h, String.to_integer(p)}
              [h] -> {h, Link.default_port()}
            end

          case Link.connect(host, port) do
            {:ok, l} -> l
            {:error, m} -> throw({:lien, m})
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

    audio = if Keyword.get(opts, :son, true), do: Audio.open()

    ctx = %{
      state: Screen.boot_state(rom, Keyword.get(opts, :dmg, false)),
      rom: rom,
      ram:
        Screen.boot_ram(rom, Keyword.get(opts, :dmg, false))
        |> then(&if(link, do: Map.put(&1, :link, link), else: &1))
        |> Save.load(sav),
      sav: sav,
      state_base: Path.rootname(sav),
      state_slot: 1,
      palette: Keyword.get(opts, :palette, :dmg),
      down: MapSet.new(),
      audio: audio,
      son?: audio != nil,
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
    {:lien, message} -> {:error, message}
  end

  # ── La boucle ───────────────────────────────────────────────────────────────

  defp loop(%{frame: n, max_frames: max} = ctx) when n >= max, do: finish(ctx)

  defp loop(ctx) do
    case drain(ctx) do
      :quit -> finish(ctx)
      ctx when ctx.menu != nil -> menu_idle(ctx)
      ctx when ctx.paused -> idle(ctx)
      ctx -> if MapSet.member?(ctx.down, :rewind), do: rewind_step(ctx), else: step(ctx)
    end
  end

  # Menu ouvert : la machine dort, la dernière frame porte le menu en
  # surimpression — même rendu que le jeu, le peintre n'en sait rien.
  defp menu_idle(ctx) do
    if ctx.last_frame do
      composée = Menu.render(ctx.menu, ctx.last_frame)
      :ets.insert(ctx.table, {:frame, Screen.to_rgb(composée, ctx.palette)})
      :wxWindow.refresh(ctx.panel, eraseBackground: false)
    end

    Process.sleep(50)
    loop(%{ctx | deadline: System.monotonic_time(:microsecond) + @frame_us})
  end

  # Un pas en arrière : dépiler un instantané (dix frames de jeu), le
  # dessiner tel quel — la machine ne tourne pas, le temps recule.
  defp rewind_step(ctx) do
    ctx =
      case ctx.history do
        [{state, ram, apu} | rest] ->
          %{ctx | state: state, ram: ram, apu: apu, history: rest}

        [] ->
          ctx
      end

    pixels = PPU.render_frame(ctx.ram)
    :ets.insert(ctx.table, {:frame, Screen.to_rgb(pixels, ctx.palette)})
    :wxWindow.refresh(ctx.panel, eraseBackground: false)
    :wxFrame.setTitle(ctx.window, ~c"atomboy — ⏪ rembobinage")

    now = System.monotonic_time(:microsecond)
    deadline = max(ctx.deadline, now - 100_000)
    if deadline > now + 999, do: Process.sleep(div(deadline - now, 1000))

    loop(%{ctx | last_frame: pixels, deadline: deadline + @frame_us})
  end

  # La mémoire du rembobinage : un instantané toutes les dix frames, un
  # anneau de 240 — quarante secondes, structurellement partagées.
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

    render? = not ctx.turbo or rem(ctx.frame, 4) == 0

    # Un déraillement tue la partie, pas la progression : la pile de la
    # cartouche est écrite avant de laisser filer le rapport de crash.
    {pixels, state, ram} =
      try do
        Screen.frame(ctx.state, ctx.rom, ram, render?)
      rescue
        e in [Atomboy.CPU.Unimplemented, Atomboy.CPU.Deraille] ->
          Save.flush(ram, ctx.sav)
          reraise e, __STACKTRACE__
      end
    {ram, apu, audio} = sound(ram, ctx.apu, ctx.audio)

    if render? do
      :ets.insert(ctx.table, {:frame, Screen.to_rgb(pixels, ctx.palette)})
      :wxWindow.refresh(ctx.panel, eraseBackground: false)
      title(ctx, ram)
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

  # ── Les événements wx ───────────────────────────────────────────────────────

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

  # Menu ouvert : les touches Game Boy le pilotent, le reste attend.
  defp on_key(%{menu: menu} = ctx, code) when menu != nil do
    touche =
      case Map.get(@keys, code) do
        nil -> if Map.get(@actions, code) == :menu, do: :menu
        key -> key
      end

    if touche do
      {menu, actions} = Menu.touche(ctx.menu, touche)

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
    Save.write_state(state_path(ctx), {ctx.state, ctx.ram, ctx.apu})
    %{ctx | note: {"état sauvé (case #{ctx.state_slot})", 120}}
  end

  defp act(ctx, :load_state) do
    case Save.read_state(state_path(ctx)) do
      {:ok, {state, ram, apu}} ->
        ram =
          case Map.get(ctx.ram, :link) do
            nil -> Map.delete(ram, :link)
            link -> Map.put(ram, :link, link)
          end

        %{ctx | state: state, ram: ram, apu: apu, note: {"état repris (case #{ctx.state_slot})", 120}}

      :error ->
        %{ctx | note: {"case #{ctx.state_slot} vide", 120}}
    end
  end

  defp act(ctx, {:slot, n}), do: %{ctx | state_slot: n, note: {"case d'état #{n}", 120}}

  defp act(ctx, :menu),
    do: %{ctx | menu: Menu.open(ctx.state_slot, ctx.palette, Map.get(ctx.ram, :cgb, false)), down: MapSet.new()}

  defp act(ctx, :turbo) do
    if Map.has_key?(ctx.ram, :link) do
      %{ctx | note: {"turbo indisponible : câble branché", 120}}
    else
      turbo_toggle(ctx)
    end
  end


  defp act(ctx, :pause), do: %{ctx | paused: not ctx.paused}

  # Les actions choisies au menu passent par les mêmes chemins que les
  # raccourcis directs — le menu n'est qu'une autre façon d'appuyer.
  defp menu_action(_action, :quit), do: :quit
  defp menu_action(:save_state, ctx), do: act(ctx, :save_state)
  defp menu_action(:load_state, ctx), do: act(ctx, :load_state)
  defp menu_action({:slot, n}, ctx), do: act(ctx, {:slot, n})
  defp menu_action({:palette, p}, ctx), do: %{ctx | palette: p}
  defp menu_action(:quit, _ctx), do: :quit

  defp turbo_toggle(ctx) do
    turbo = not ctx.turbo

    audio =
      if turbo do
        Audio.close(ctx.audio)
        nil
      else
        if ctx.son?, do: Audio.open()
      end

    %{ctx | turbo: turbo, audio: audio, deadline: System.monotonic_time(:microsecond) + @frame_us}
  end

  defp state_path(ctx) do
    if ctx.state_slot == 1 do
      ctx.state_base <> ".state"
    else
      ctx.state_base <> ".case#{ctx.state_slot}.state"
    end
  end


  # ── Le rendu ────────────────────────────────────────────────────────────────

  # Exécuté par le thread wx : lire la dernière frame, l'étirer au plus
  # proche voisin (wxIMAGE_QUALITY_NEAREST = 0), la dessiner.
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
    :wxFrame.setTitle(ctx.window, ~c"atomboy — #{fps} fps · banque #{bank}#{extras}")
  end

  defp title(_ctx, _ram), do: :ok

  # ── Le reste, comme au terminal ─────────────────────────────────────────────

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
