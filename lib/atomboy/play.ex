defmodule Atomboy.Play do
  @moduledoc """
  La Game Boy jouable dans le terminal.

  La boucle : lire le clavier, poser les touches sur les lignes du joypad,
  faire tourner une frame de machine (154 scanlines), l'afficher, tenir la
  cadence — 59,7 Hz, celle de la dalle.

  ## Le terminal comme console

    * L'écran alternatif (`\\e[?1049h`) : le jeu occupe tout, et le shell
      retrouve son historique intact à la sortie.
    * `stty -icanon -echo -isig` : les frappes arrivent une à une, sans écho,
      et Ctrl-C nous parvient en octet 0x03 — décodé en « quitter », pour
      restaurer le terminal proprement au lieu de mourir dessus.
    * Chaque frame se redessine par-dessus la précédente (`\\e[H`), sans
      effacement — pas de scintillement.

  ## Le relâchement qui n'existe pas

  Un terminal ne signale que les frappes, jamais les relâchements. Chaque
  frappe devient donc une pression tenue `hold` frames (~170 ms), rafraîchie
  par la répétition automatique du clavier — un maintien réel reste tenu,
  une frappe brève reste brève. Réglable par `hold:` si un jeu s'y prête mal.
  """

  alias Atomboy.Joypad
  alias Atomboy.Play.Input
  alias Atomboy.Screen

  # La période d'une frame DMG : 70 224 T-cycles à 4,194 MHz.
  @frame_us 16_742
  @default_hold 10

  @doc """
  Joue `rom_path` jusqu'à `q`/Ctrl-C — ou `frames:` frames, pour les essais
  sans clavier.
  """
  @spec run(Path.t(), keyword()) :: :ok
  def run(rom_path, opts \\ []) do
    rom = Screen.load(rom_path)
    saved = terminal_setup()
    parent = self()
    reader = spawn_link(fn -> read_keys(parent) end)

    try do
      loop(%{
        state: Screen.boot_state(),
        rom: rom,
        ram: %{rom_banks: div(byte_size(rom), 0x4000)},
        hold: %{},
        pending: "",
        frame: 0,
        max_frames: Keyword.get(opts, :frames, :infinity),
        hold_frames: Keyword.get(opts, :hold, @default_hold),
        fps: 0.0,
        fps_mark: System.monotonic_time(:microsecond)
      })
    after
      Process.unlink(reader)
      Process.exit(reader, :kill)
      terminal_restore(saved)
    end
  end

  # ── La boucle de frame ──────────────────────────────────────────────────────

  defp loop(%{frame: n, max_frames: max}) when n >= max, do: :ok

  defp loop(ctx) do
    started = System.monotonic_time(:microsecond)
    {keys, pending} = Input.decode(ctx.pending <> collect_input([]))

    if :quit in keys do
      :ok
    else
      hold = Enum.reduce(keys, ctx.hold, &Map.put(&2, &1, ctx.hold_frames))
      held = Map.keys(hold)
      ram = Joypad.set(ctx.ram, Input.dpad_lines(held), Input.button_lines(held))

      {pixels, state, ram} = Screen.frame(ctx.state, ctx.rom, ram, true)
      IO.write(["\e[H", Screen.to_text(pixels), status(ctx, ram, held)])

      now = System.monotonic_time(:microsecond)
      spare = @frame_us - (now - started)
      if spare > 999, do: Process.sleep(div(spare, 1000))

      hold = for {key, left} <- hold, left > 1, into: %{}, do: {key, left - 1}
      ctx = %{ctx | state: state, ram: ram, hold: hold, pending: pending, frame: ctx.frame + 1}
      loop(measure_fps(ctx))
    end
  end

  defp collect_input(acc) do
    receive do
      {:input, data} -> collect_input([acc | data])
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

    [
      "\e[0m flèches ✚ · x A · c B · ⏎ Start · ␣ Select · q quitte    ",
      :io_lib.format(~c"~5.1f fps · banque ~2..0B", [ctx.fps, bank]),
      keys,
      "\e[K"
    ]
  end

  # ── Le clavier ──────────────────────────────────────────────────────────────

  # Un octet à la fois depuis stdin — le terminal en -icanon les livre dès la
  # frappe. La fin de flux (entrée redirigée épuisée) arrête juste la lecture :
  # la partie continue au joypad relâché.
  defp read_keys(parent) do
    case IO.getn("", 1) do
      data when is_binary(data) ->
        send(parent, {:input, data})
        read_keys(parent)

      _eof_or_error ->
        :ok
    end
  end

  # ── Le terminal ─────────────────────────────────────────────────────────────

  defp terminal_setup do
    saved = ~c"stty -g < /dev/tty" |> :os.cmd() |> List.to_string() |> String.trim()
    :os.cmd(~c"stty -icanon -echo -isig min 1 time 0 < /dev/tty")
    IO.write("\e[?1049h\e[?25l\e[2J")
    saved
  end

  defp terminal_restore(saved) do
    IO.write("\e[?1049l\e[?25h\e[0m")

    if saved =~ ~r/^[\w:=,]+$/ do
      :os.cmd(String.to_charlist("stty #{saved} < /dev/tty"))
    else
      :os.cmd(~c"stty sane < /dev/tty")
    end

    :ok
  end

  @doc """
  La taille du terminal en `{lignes, colonnes}` — via `stty size`, la seule
  voie fiable sous `-noshell`. `:unknown` sans tty (sortie redirigée, CI).
  """
  @spec terminal_size() :: {pos_integer(), pos_integer()} | :unknown
  def terminal_size do
    case ~c"stty size < /dev/tty 2> /dev/null" |> :os.cmd() |> List.to_string() |> String.split() do
      [rows, cols] -> {String.to_integer(rows), String.to_integer(cols)}
      _ -> :unknown
    end
  end
end
