defmodule Atomboy.Play do
  @moduledoc """
  La Game Boy jouable dans le terminal.

  La boucle : lire le clavier, poser les touches sur les lignes du joypad,
  faire tourner une frame de machine (154 scanlines), l'afficher, tenir la
  cadence — 59,7 Hz, celle de la dalle.

  ## Le terminal comme console — la voie du pty nommé

  Le clavier ne passe **pas** par l'étage d'E/S d'Erlang, pour deux raisons
  mesurées à la sonde (`scripts/probe_clavier*.exs`) :

    * `:shell.start_interactive({:noshell, :raw})`, l'API d'OTP 26, ne
      réveille jamais une lecture en attente quand la frappe arrive après
      elle — l'entrée déjà tamponnée passe, la frappe humaine jamais.
    * Le BEAM détache ses processus fils du terminal de contrôle (`setsid`
      avant exec) : `/dev/tty` est mort pour eux, tout `stty < /dev/tty`
      est un no-op silencieux.

  Mais le pty a un *nom* (`/dev/ttysNNN`), que `ps -o tty=` sait donner, et
  un device se manipule sans lien de contrôle : `stty -f` pose les modes
  (`-icanon -echo -isig` : frappes une à une, sans écho, Ctrl-C en octet
  0x03 décodé en « quitter »), et `:file.read` octet par octet livre les
  frappes en temps réel — vérifié écritures simultanées comprises.

  Dernier voleur : même sans aucune demande de lecture, `prim_tty` lit le
  terminal en permanence et rafle un octet sur trois — les flèches, trois
  octets, n'arrivent presque jamais entières. Le drapeau `-noinput` l'éteint
  (mesuré : 0/301 octets reçus sans, 301/301 avec), d'où le lanceur
  `bin/play` ; sur un tty sans ce drapeau, `run/2` refuse de démarrer avec
  le mode d'emploi.

    * L'écran alternatif (`\\e[?1049h`) : le jeu occupe tout, et le shell
      retrouve son historique intact à la sortie ; les réglages `stty`
      d'origine sont sauvés (`-g`) et restaurés.
    * Chaque frame se redessine par-dessus la précédente (`\\e[H`), sans
      effacement — pas de scintillement.
    * Sans pty visible (`--frames` en test, entrée redirigée), la lecture
      se replie sur `/dev/fd/0` et aucune taille n'est exigée.

  ## Le relâchement, selon le terminal

  Sur un terminal parlant le protocole clavier kitty (Ghostty, kitty,
  WezTerm…), chaque touche envoie presse *et* relâchement : l'état du
  clavier est réel, les diagonales et les accords A+direction marchent. Le
  protocole se demande au démarrage (`CSI > 11 u` puis requête) — la réponse
  confirme, un terminal muet ignore tout.

  Sans lui, un terminal ne signale que les frappes, et macOS ne répète que
  la dernière touche enfoncée : chaque frappe devient une pression tenue
  `hold` frames (~170 ms), rafraîchie par la répétition automatique —
  un maintien réel reste tenu, une frappe brève reste brève, mais les
  accords ne durent que leur fenêtre de maintien. Réglable par `hold:`.
  """

  alias Atomboy.APU
  alias Atomboy.Joypad
  alias Atomboy.Play.Audio
  alias Atomboy.Play.Input
  alias Atomboy.Save
  alias Atomboy.Screen

  # La période d'une frame DMG : 70 224 T-cycles à 4,194 MHz.
  @frame_us 16_742
  @default_hold 10

  @doc """
  Joue `rom_path` jusqu'à `q`/Ctrl-C — ou `frames:` frames, pour les essais
  sans clavier. `dump:` écrit la dernière frame en PGM à la sortie.

  Renvoie `:ok`, ou `{:error, message}` si le terminal est trop petit.
  """
  @spec run(Path.t(), keyword()) :: :ok | {:error, String.t()}
  def run(rom_path, opts \\ []) do
    rom = Screen.load(rom_path)
    sav = Save.path(rom_path)
    tty = pty_path()

    with :ok <- ensure_sole_reader(tty) do
      saved = terminal_setup(tty)

      try do
        play(rom, sav, tty, opts)
      after
        terminal_restore(tty, saved)
      end
    end
  end

  # Sans -noinput, prim_tty lit le terminal en permanence et vole un octet
  # sur trois au jeu — les flèches (3 octets) n'arrivent jamais entières.
  # Mesuré : 0/301 octets reçus sans -noinput, 301/301 avec. Pas de tty,
  # pas de voleur : les essais --frames redirigés passent sans le drapeau.
  defp ensure_sole_reader(tty) do
    if tty != nil and :init.get_argument(:noinput) == :error do
      {:error,
       "Le BEAM lit le terminal en même temps que le jeu (il vole un octet\n" <>
         "sur trois — les flèches n'arrivent jamais entières). Relancer avec :\n\n" <>
         "    bin/play <rom.gb>\n\n" <>
         "ou  ELIXIR_ERL_OPTIONS=\"-noinput\" mix atomboy.play <rom.gb>"}
    else
      :ok
    end
  end

  defp play(rom, sav, tty, opts) do
    (fn ->
      parent = self()
      input = tty || "/dev/fd/0"
      reader = spawn_link(fn -> read_keys(parent, input) end)

      # Le son suit le clavier : présent en interactif, coupé dans les
      # essais redirigés — sauf demande explicite (son: true/false).
      audio = if Keyword.get(opts, :son, tty != nil), do: Audio.open()

      try do
        loop(%{
          state: Screen.boot_state(),
          rom: rom,
          ram: Save.load(Screen.boot_ram(rom), sav),
          sav: sav,
          hold: %{},
          down: MapSet.new(),
          kitty: false,
          audio: audio,
          son?: audio != nil,
          apu: %APU{},
          pending: "",
          frame: 0,
          max_frames: Keyword.get(opts, :frames, :infinity),
          hold_frames: Keyword.get(opts, :hold, @default_hold),
          dump: Keyword.get(opts, :dump),
          state_path: Path.rootname(sav) <> ".state",
          palette: Keyword.get(opts, :palette, :dmg),
          gfx: false,
          gfx_id: 1,
          dims: terminal_dims(tty),
          size_ok: Keyword.has_key?(opts, :frames),
          turbo: false,
          paused: false,
          note: nil,
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

  # La taille du terminal, sur le pty nommé (`stty -f … -a` — « 66 rows;
  # 269 columns; » sur mac, « rows 66; columns 269 » ailleurs).
  defp terminal_dims(tty) do
    with out when is_binary(out) <- tty && to_string(:os.cmd(stty(tty, "-a 2> /dev/null"))),
         [_, rows] <- Regex.run(~r/(\d+) rows|rows (?:= )?(\d+)/, out) |> compact(),
         [_, cols] <- Regex.run(~r/(\d+) columns|columns (?:= )?(\d+)/, out) |> compact() do
      {String.to_integer(rows), String.to_integer(cols)}
    else
      _ -> nil
    end
  end

  # Les demi-blocs exigent 160×73 ; les vraies images non. Le verdict attend
  # donc la demi-seconde où le terminal a pu répondre à la requête graphique.
  defp ensure_size(%{size_ok: true}), do: :ok
  defp ensure_size(%{gfx: true}), do: :ok
  defp ensure_size(%{frame: n}) when n < 30, do: :wait

  defp ensure_size(%{dims: {rows, cols}}) when rows < 73 or cols < 160 do
    {:error,
     "Le terminal fait #{cols}×#{rows} ; il faut 160×73 pour l'écran DMG en\n" <>
       "demi-blocs. Réduire la police (Cmd -), agrandir la fenêtre — ou un\n" <>
       "terminal parlant le protocole graphique kitty (Ghostty, kitty, WezTerm)\n" <>
       "affiche de vraies images sans contrainte de taille."}
  end

  defp ensure_size(_ctx), do: :ok

  # Regex.run à deux alternatives : ne garder que les groupes capturés.
  defp compact(nil), do: nil
  defp compact(matches), do: Enum.reject(matches, &(&1 in [nil, ""]))

  # ── La boucle de frame ──────────────────────────────────────────────────────

  defp loop(%{frame: n, max_frames: max} = ctx) when n >= max, do: finish(ctx)

  defp loop(ctx) do
    {events, pending} = Input.decode(ctx.pending <> collect_input([]))

    if Enum.any?(events, &match?({tag, :quit} when tag != :release, &1)) do
      finish(ctx)
    else
      ctx = Enum.reduce(events, %{ctx | pending: pending}, &apply_event/2)

      case ensure_size(ctx) do
        {:error, _} = error ->
          finish(ctx)
          error

        _ ->
          resume(ctx)
      end
    end
  end

  defp resume(ctx) do
    ctx =
      if ctx.frame >= 30 and not ctx.size_ok do
        %{ctx | size_ok: true}
      else
        ctx
      end

    (fn ->
      if ctx.paused do
        # En pause, la machine dort — l'écran reste, le clavier veille.
        ctx = if ctx.last_frame, do: draw(ctx, ctx.last_frame, ctx.ram, []), else: ctx

        Process.sleep(50)
        loop(%{ctx | deadline: System.monotonic_time(:microsecond) + @frame_us})
      else
        step(ctx)
      end
    end).()
  end

  defp step(ctx) do
    held = Enum.uniq(MapSet.to_list(ctx.down) ++ Map.keys(ctx.hold))
    ram = Joypad.set(ctx.ram, Input.dpad_lines(held), Input.button_lines(held))

    # En turbo, une frame sur quatre s'affiche — le rendu est le coût.
    render? = not ctx.turbo or rem(ctx.frame, 4) == 0

    # Un opcode inconnu tue la partie, pas la progression : la pile de la
    # cartouche est écrite avant de laisser filer le rapport de crash.
    {pixels, state, ram} =
      try do
        Screen.frame(ctx.state, ctx.rom, ram, render?)
      rescue
        e in Atomboy.CPU.Unimplemented ->
          Save.flush(ram, ctx.sav)
          reraise e, __STACKTRACE__
      end

    # Pendant le turbo le port audio est fermé : sound/3 jette les
    # déclenchements sans rien pousser.
    {ram, apu, audio} = sound(ram, ctx.apu, ctx.audio)

    ctx = if render?, do: draw(ctx, pixels, ram, held), else: ctx

    # La cadence par échéancier absolu : chaque excès de sommeil se reprend
    # à la frame suivante, le débit long terme est exactement 59,7275 Hz —
    # la condition pour que la production d'échantillons suive ffplay, qui
    # consomme au vrai 32 768 Hz. Une cadence relative dérive de ~0,7 % et
    # affame le tampon audio en une demi-minute. Après un blocage franc
    # (> 100 ms), l'échéancier se recale : pas de sprint de rattrapage.
    # Le turbo suspend l'échéancier — l'émulation file aussi vite que le BEAM.
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

    # L'autosauvegarde : la pile de la cartouche n'attend pas la sortie.
    ram = if rem(ctx.frame, 600) == 599, do: Save.flush(ram, ctx.sav), else: ram

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

    loop(measure_fps(ctx))
  end

  # Deux chemins d'affichage. Demi-blocs : le texte, curseur en haut.
  # Protocole graphique : l'image se transmet sous un identifiant alterné —
  # la nouvelle se pose par-dessus l'ancienne, qui n'est effacée qu'ensuite
  # (pas de trou entre deux frames) — et le statut s'ancre à la dernière
  # ligne du terminal.
  defp draw(%{gfx: true} = ctx, pixels, ram, held) do
    id = ctx.gfx_id
    old = 3 - id
    rows = with {r, _c} <- ctx.dims, do: r, else: (_ -> 24)

    IO.write([
      "\e[H",
      Screen.to_kitty(pixels, ctx.palette, id, rows - 1),
      "\e_Ga=d,d=I,i=#{old},q=2\e\\",
      "\e[#{rows};1H",
      status(ctx, ram, held)
    ])

    %{ctx | gfx_id: old}
  end

  defp draw(ctx, pixels, ram, held) do
    IO.write(["\e[H", crlf(Screen.to_text(pixels, ctx.palette)), status(ctx, ram, held)])
    ctx
  end

  # Le message éphémère de la ligne de statut s'éteint de lui-même.
  defp fade({_text, 0}), do: nil
  defp fade({text, left}), do: {text, left - 1}
  defp fade(nil), do: nil

  # La frame de son suit la frame d'image ; un lecteur disparu coupe le son
  # sans arrêter la partie. Sans lecteur, les déclenchements capturés se
  # jettent — la liste ne doit pas enfler pour rien.
  defp sound(ram, apu, audio), do: Audio.stream(audio, ram, apu)

  # ── L'état des touches ──────────────────────────────────────────────────────

  # La réponse à la requête kitty : le terminal parle le protocole. L'état
  # réel n'est fiable qu'avec les relâchements (bit 2 des flags).
  defp apply_event({:kitty, flags}, ctx), do: %{ctx | kitty: Bitwise.band(flags, 2) != 0}

  # Le terminal sait afficher des images : on nettoie les demi-blocs et on
  # bascule — la contrainte de taille tombe avec eux.
  defp apply_event({:graphics, true}, ctx) do
    IO.write("\e[2J")
    %{ctx | gfx: true}
  end

  defp apply_event({:graphics, false}, ctx), do: ctx

  # Les actions — au front montant seulement : presse ou frappe, jamais la
  # répétition (un p tenu ne doit pas faire clignoter la pause).
  defp apply_event({tag, :save_state}, ctx) when tag in [:key, :press] do
    Save.write_state(ctx.state_path, {ctx.state, ctx.ram, ctx.apu})
    %{ctx | note: {"état sauvé", 120}}
  end

  defp apply_event({tag, :load_state}, ctx) when tag in [:key, :press] do
    case Save.read_state(ctx.state_path) do
      {:ok, {state, ram, apu}} ->
        %{ctx | state: state, ram: ram, apu: apu, note: {"état repris", 120}}

      :error ->
        %{ctx | note: {"aucun état à reprendre", 120}}
    end
  end

  # Le turbo affame tout lecteur audio (production stoppée, consommation
  # continue) : on ferme ffplay à l'entrée, on en rouvre un neuf à la
  # sortie — tampon vierge, pas de famine héritée.
  defp apply_event({tag, :turbo}, ctx) when tag in [:key, :press] do
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

  defp apply_event({tag, :pause}, ctx) when tag in [:key, :press],
    do: %{ctx | paused: not ctx.paused}

  defp apply_event({_tag, key}, ctx)
       when key in [:save_state, :load_state, :turbo, :pause],
       do: ctx

  defp apply_event({:release, key}, %{kitty: true} = ctx),
    do: %{ctx | down: MapSet.delete(ctx.down, key), hold: Map.delete(ctx.hold, key)}

  defp apply_event({tag, key}, %{kitty: true} = ctx) when tag in [:press, :repeat],
    do: %{ctx | down: MapSet.put(ctx.down, key)}

  # En kitty, la presse nue d'une flèche (« ESC [ A ») aura son relâchement.
  defp apply_event({:key, key}, %{kitty: true} = ctx)
       when key in [:up, :down, :left, :right],
       do: %{ctx | down: MapSet.put(ctx.down, key)}

  # Régime classique : frappe sans relâchement connu → pression tenue.
  defp apply_event({tag, key}, ctx) when tag in [:key, :press, :repeat],
    do: %{ctx | hold: Map.put(ctx.hold, key, ctx.hold_frames)}

  # Relâchement sans protocole confirmé : ignoré.
  defp apply_event(_event, ctx), do: ctx

  # Le \r explicite avant chaque \n : inoffensif quand opost traduit déjà,
  # salvateur si un environnement l'a éteint — l'affichage ne dépend ainsi
  # d'aucun réglage de sortie du terminal.
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
      # Les messages du port audio (sortie, code de fin) : sans intérêt,
      # mais à drainer — une boîte aux lettres qui enfle ralentit tout.
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

    [
      "\e[0m ✚ flèches · x A · c B · ⏎ Start · ␣ Select · s/r état · ⇥ turbo · p pause · q quitte   ",
      :io_lib.format(~c"~5.1f fps · banque ~2..0B", [ctx.fps, bank]),
      if(ctx.audio, do: " · ♪", else: ""),
      if(ctx.turbo, do: " · »»", else: ""),
      if(ctx.paused, do: " · ⏸ pause", else: ""),
      note,
      keys,
      "\e[K"
    ]
  end

  # ── Le clavier ──────────────────────────────────────────────────────────────

  # Le pty s'ouvre ici même : un descripteur :raw ne se lit que depuis le
  # processus qui l'a ouvert. Puis un octet à la fois, en lecture bloquante
  # hors de l'étage d'E/S d'Erlang — c'est elle que le terminal en -icanon
  # réveille à chaque frappe. La fin de flux (entrée redirigée épuisée)
  # arrête juste la lecture : la partie continue au joypad relâché.
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

  # ── Le terminal ─────────────────────────────────────────────────────────────

  # Le nom du pty de ce BEAM — « ttys005 » — par ps, seul lien qui survive
  # au setsid. nil sans terminal (entrée redirigée, CI).
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

    # Le protocole clavier kitty, s'il est parlé : pousser les flags
    # (1 désambiguïser, 2 événements presse/relâchement, 8 toutes les touches
    # en séquences) puis interroger — la réponse « CSI ? … u » confirme, et
    # les relâchements donnent l'état réel du clavier (diagonales, accords).
    # Un terminal muet ignore tout : le maintien par frames reste en place.
    if tty, do: IO.write("\e[>11u\e[?u")

    # Et le protocole graphique : transmettre un pixel en requête (a=q) —
    # « OK » en réponse = de vraies images plutôt que des demi-blocs.
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

  # macOS dit `stty -f fichier`, GNU dit `stty -F fichier`.
  defp stty(tty, args) do
    flag = if match?({:unix, :linux}, :os.type()), do: "-F", else: "-f"
    String.to_charlist("stty #{flag} #{tty} #{args}")
  end
end
