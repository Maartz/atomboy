defmodule Atomboy.Serveur do
  @moduledoc """
  Le mode serveur : atomboy comme moteur derrière une coquille native.

  La coquille (SwiftUI sur macOS, ou n'importe quoi qui sait lire un
  tuyau) lance `atomboy rom.gb --serveur` et parle un protocole binaire
  minimal :

  ## Sortie (stdout)

      <<?F, rgb::binary-69120>>          une frame 160×144 en RGB24
      <<?A, n::16-big, pcm::binary-n>>   du PCM s16le stéréo 32 768 Hz

  Le RGB sort du même `Screen.to_rgb` que la fenêtre — palette comprise,
  menu en surimpression compris : la coquille dessine, elle ne sait rien.
  Le PCM suit la cadence anti-famine de l'horloge murale (`Audio.cadence`) ;
  la coquille le joue au fil de l'eau. Les messages de statut (câble…)
  vont sur stderr — stdout reste un flux binaire pur.

  ## Entrée (stdin)

  Des enregistrements de deux octets : `<<op, touche>>`, `op` valant `?+`
  (presse) ou `?-` (relâchement). Touches : `?U ?D ?L ?R` les directions,
  `?A ?B` les boutons, `?S` Start, `?E` Select, `?M` le menu, `?W` le
  rembobinage (tenu), `?P` pause — et les actions directes pour la barre
  de menus native : `?s`/`?r` sauver/charger l'état, `?1`-`?9` la case.
  Deux opérations portent une valeur plutôt qu'une touche : `<<?V, v>>`
  pose le volume du mixer (0-100), `<<?X, masque>>` les quatre voix
  (bits 0-3) — le panneau natif de la coquille s'en sert. La fin de
  l'entrée (coquille fermée) arrête la partie proprement — sauvegarde
  écrite.

  Tout le reste est la machinerie habituelle : menu dans la frame, états,
  mixer, câble link (`--ecoute`/`--lien` marchent aussi en serveur).
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

  @touches %{
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
                # Les actions directes — la barre de menus native s'en sert.
                ?s => :save_state,
                ?r => :load_state
              }
              |> Map.merge(for n <- 1..9, into: %{}, do: {?0 + n, {:slot, n}})

  @boutons [:up, :down, :left, :right, :a, :b, :start, :select, :rewind]

  @doc "Joue `rom_path` en mode serveur. Mêmes options que la fenêtre."
  @spec run(Path.t(), keyword()) :: :ok | {:error, String.t()}
  def run(rom_path, opts \\ []) do
    rom = Screen.load(rom_path)
    sav = Save.path(rom_path, Keyword.get(opts, :sauvegarde))

    with {:ok, link} <- link_up(opts) do
      # stdout est un flux binaire : en Unicode (le défaut du BEAM), tout
      # octet ≥ 128 deviendrait deux octets UTF-8 — frames déchirées.
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
      port = Keyword.get(opts, :ecoute) -> Link.listen(port)
      lien = Keyword.get(opts, :lien) -> connect(lien)
      true -> {:ok, nil}
    end
  end

  defp connect(lien) do
    case String.split(lien, ":") do
      [host, port] -> Link.connect(host, String.to_integer(port))
      [host] -> Link.connect(host, Link.default_port())
    end
  end

  # ── La boucle ───────────────────────────────────────────────────────────────

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

    # En turbo : une frame émise sur quatre, pas de PCM, pas d'échéancier.
    render? = not ctx.turbo or rem(ctx.frame, 4) == 0

    {pixels, state, ram} =
      try do
        Screen.frame(ctx.state, ctx.rom, ram, render?)
      rescue
        e in [Atomboy.CPU.Unimplemented, Atomboy.CPU.Deraille] ->
          Save.flush(ram, ctx.sav)
          reraise e, __STACKTRACE__
      end

    {ram, apu, audio} =
      if ctx.turbo do
        # Les déclenchements se consomment quand même — l'état de l'APU
        # reste cohérent, seul le PCM se tait.
        {_, ram, apu} = APU.samples(ram, ctx.apu, 0)
        {ram, apu, ctx.audio}
      else
        son(ram, ctx.apu, ctx.audio)
      end

    if render?, do: émet_frame(pixels, ctx.palette)

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

  # Le PCM dû par l'horloge murale, poussé dans le flux — la coquille joue.
  defp son(ram, apu, audio) do
    {audio, needed} = Audio.cadence(audio)
    {pcm, ram, apu} = APU.samples(ram, apu, needed)

    if byte_size(pcm) > 0 do
      IO.binwrite(:stdio, [<<?A, byte_size(pcm)::16-big>>, pcm])
    end

    {ram, apu, %{audio | sent: audio.sent + needed}}
  end

  defp émet_frame(pixels, palette) do
    IO.binwrite(:stdio, [<<?F>>, Screen.to_rgb(pixels, palette)])
  end

  defp menu_idle(ctx) do
    if ctx.last_frame do
      émet_frame(Menu.render(ctx.menu, ctx.last_frame), ctx.palette)
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
    émet_frame(pixels, ctx.palette)

    now = System.monotonic_time(:microsecond)
    deadline = max(ctx.deadline, now - 100_000)
    if deadline > now + 999, do: Process.sleep(div(deadline - now, 1000))

    loop(%{ctx | last_frame: pixels, deadline: deadline + @frame_us})
  end

  defp remember(%{frame: n} = ctx) when rem(n, 10) == 0 do
    %{ctx | history: Enum.take([{ctx.state, ctx.ram, ctx.apu} | ctx.history], 240)}
  end

  defp remember(ctx), do: ctx

  # ── Les touches ─────────────────────────────────────────────────────────────

  defp drain(ctx) do
    receive do
      # Le mixer natif de la coquille : volume (?V, 0-100) et masque des
      # quatre voix (?X, bits 0-3) — appliqués au même ram[:mixer] que le
      # menu en jeu, replié par l'APU dans sa config par frame.
      {:touche, ?V, volume} ->
        drain(%{ctx | ram: mixer_maj(ctx.ram, :volume, min(volume, 100))})

      {:touche, ?X, masque} ->
        voix =
          {(masque &&& 1) != 0, (masque &&& 2) != 0, (masque &&& 4) != 0, (masque &&& 8) != 0}

        drain(%{ctx | ram: mixer_maj(ctx.ram, :voix, voix)})

      {:codes, chaîne} ->
        drain(%{ctx | ram: Codes.installe(ctx.ram, Codes.analyse(chaîne))})

      {:touche, op, key} ->
        case appuie(ctx, op, Map.get(@touches, key)) do
          :quit -> :quit
          ctx -> drain(ctx)
        end

      :stdin_fermé ->
        # La coquille est partie : conclure — sauf en essai borné
        # (--frames), où l'entrée peut légitimement être déjà close.
        if ctx.max_frames == :infinity, do: :quit, else: ctx
    after
      0 -> ctx
    end
  end

  defp appuie(ctx, _op, nil), do: ctx

  defp appuie(%{menu: menu} = ctx, ?+, key) when menu != nil do
    {menu, actions} = Menu.touche(ctx.menu, key)

    case Enum.reduce(actions, %{ctx | menu: menu}, &menu_action/2) do
      :quit -> :quit
      ctx -> ctx
    end
  end

  defp appuie(%{menu: menu} = ctx, ?-, _key) when menu != nil, do: ctx

  defp appuie(ctx, ?+, :menu),
    do: %{
      ctx
      | menu:
          Menu.open(ctx.state_slot, ctx.palette, Map.get(ctx.ram, :cgb, false), Map.get(ctx.ram, :mixer)),
        down: MapSet.new()
    }

  defp appuie(ctx, ?+, :pause), do: appuie(ctx, ?+, :menu)

  # Le turbo : indisponible câble branché (le protocole série exige le
  # tempo) ; à la sortie, la cadence audio repart de zéro — pas de rafale
  # de rattrapage héritée du sprint.
  defp appuie(ctx, ?+, :turbo) do
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
  defp appuie(ctx, ?+, :save_state), do: menu_action(:save_state, ctx)
  defp appuie(ctx, ?+, :load_state), do: menu_action(:load_state, ctx)
  defp appuie(ctx, ?+, {:slot, n}), do: %{ctx | state_slot: n}
  defp appuie(ctx, ?+, key) when key in @boutons, do: %{ctx | down: MapSet.put(ctx.down, key)}
  defp appuie(ctx, ?-, key) when key in @boutons, do: %{ctx | down: MapSet.delete(ctx.down, key)}
  defp appuie(ctx, _op, _key), do: ctx

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

  defp state_path(ctx) do
    if ctx.state_slot == 1 do
      ctx.state_base <> ".state"
    else
      ctx.state_base <> ".case#{ctx.state_slot}.state"
    end
  end

  defp mixer_maj(ram, clé, valeur) do
    mixer = Map.get(ram, :mixer, Menu.mixer_défaut())
    Map.put(ram, :mixer, Map.put(mixer, clé, valeur))
  end

  # ── L'entrée ────────────────────────────────────────────────────────────────

  # Deux octets par événement, lus au fil de l'eau ; la fin du flux (la
  # coquille est partie) conclut la partie.
  defp read_stdin(parent) do
    case :file.open(~c"/dev/fd/0", [:read, :binary, :raw]) do
      {:ok, f} -> read_loop(parent, f)
      _ -> send(parent, :stdin_fermé)
    end
  end

  defp read_loop(parent, f) do
    case :file.read(f, 2) do
      # ?C : les codes GameShark — longueur puis la liste ASCII, qui
      # REMPLACE l'ensemble actif (une liste vide efface tout).
      {:ok, <<?C, longueur>>} ->
        chaîne =
          case :file.read(f, longueur) do
            {:ok, données} when longueur > 0 -> données
            _ -> ""
          end

        send(parent, {:codes, chaîne})
        read_loop(parent, f)

      {:ok, <<op, key>>} ->
        send(parent, {:touche, op, key})
        read_loop(parent, f)

      _fin ->
        send(parent, :stdin_fermé)
    end
  end
end
