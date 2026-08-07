defmodule Atomboy.Library do
  @moduledoc """
  The saves' home — one folder per game, named by the cartridge, not the file.

  Until now every artifact landed next to the ROM: `.sav`, `.state`,
  `.caseN.state`, `.profile.sav` — one well-played game left half a dozen
  sidecar files in whatever folder the ROM happened to sit in, and a ROM
  that moved or was renamed silently orphaned all of them.

  The library keys a game by its **header** — title plus global checksum —
  so its folder follows the game wherever the file goes. Inside, batteries
  are profiles (`game.sav`, `nolan.sav`: one cartridge per player) and
  states are *named*: a `.state`, a `meta.json`, a screenshot. The numbered
  slots the frontends have always offered are simply names the keyboard
  reserves — `slot-1` to `slot-9` — which is how they get screenshots and
  timestamps without anyone changing a keybinding.

  ## Interop

  The sidecar convention is how emulators share saves, so it is adopted,
  not abandoned: on the first boot of a game (its folder does not exist
  yet) any sidecar files are *copied* in — originals untouched. From then
  on the library is the single truth: no newer-file heuristics, ever.
  `export/1` copies the battery back beside the ROM for other emulators.

  If the library root cannot be written, everything falls back to the
  sidecar behaviour of old — the mode rides in the struct and every path
  function branches on it, so callers never know.
  """

  alias Atomboy.Save
  alias Atomboy.Screen

  defstruct mode: :library, dir: nil, rom_path: nil, profile: "game"

  @type t :: %__MODULE__{
          mode: :library | :sidecar,
          dir: Path.t() | nil,
          rom_path: Path.t(),
          profile: String.t()
        }

  @default_profile "game"

  # ── Opening ─────────────────────────────────────────────────────────────────

  @doc """
  Opens the library for a cartridge: resolves the root, creates the game's
  folder, adopts sidecar files on first sight. `opts` honours `:library`
  (the root override) and `:save` (the profile name).

  An unwritable root degrades to sidecar mode — the behaviour of old, with
  a line on stderr.
  """
  @spec open(binary(), Path.t(), keyword()) :: t()
  def open(rom, rom_path, opts \\ []) do
    profile = sanitize(Keyword.get(opts, :save) || @default_profile)
    dir = Path.join(root(opts), game_id(rom))

    case prepare(dir, rom_path) do
      :ok ->
        %__MODULE__{mode: :library, dir: dir, rom_path: rom_path, profile: profile}

      {:error, reason} ->
        IO.warn("library unwritable (#{inspect(reason)}): falling back to sidecar files")
        %__MODULE__{mode: :sidecar, rom_path: rom_path, profile: profile}
    end
  end

  @doc "The library root: `--library` if given, the platform's user-data dir otherwise."
  @spec root(keyword()) :: Path.t()
  def root(opts \\ []) do
    Keyword.get(opts, :library) || to_string(:filename.basedir(:user_data, ~c"atomboy"))
  end

  @doc """
  A game's identity: the header title (0x134-0x143, printable ASCII) and
  the global checksum (0x14E-0x14F) — `POKEMON_CRYSTAL-91E2`. Stable when
  the file moves; distinct across revisions, which differ by checksum.
  """
  @spec game_id(binary()) :: String.t()
  def game_id(rom) do
    title =
      rom
      |> binary_part(0x134, 0x10)
      |> :binary.bin_to_list()
      |> Enum.take_while(&(&1 in 0x20..0x7E))
      |> List.to_string()
      |> String.replace(~r/[^A-Za-z0-9]+/, "_")
      |> String.trim("_")

    checksum = rom |> binary_part(0x14E, 2) |> Base.encode16()
    "#{if title == "", do: "UNTITLED", else: title}-#{checksum}"
  end

  # ── Paths ───────────────────────────────────────────────────────────────────

  @doc "The battery of the current profile."
  @spec sav_path(t()) :: Path.t()
  def sav_path(%{mode: :library} = lib), do: Path.join(lib.dir, lib.profile <> ".sav")
  def sav_path(%{mode: :sidecar} = lib), do: Save.path(lib.rom_path, sidecar_profile(lib))

  @doc """
  A named state's file. In sidecar mode the historical names survive:
  `slot-1` is the bare `.state`, `slot-N` the `.caseN.state`.
  """
  @spec state_path(t(), String.t()) :: Path.t()
  def state_path(%{mode: :library} = lib, name),
    do: Path.join(states_dir(lib), sanitize(name) <> ".state")

  def state_path(%{mode: :sidecar} = lib, name) do
    base = Path.rootname(sav_path(lib))

    case name do
      "slot-1" -> base <> ".state"
      "slot-" <> n -> base <> ".case#{n}.state"
      other -> base <> "." <> sanitize(other) <> ".state"
    end
  end

  defp states_dir(lib), do: Path.join([lib.dir, "states", lib.profile])

  defp sidecar_profile(%{profile: @default_profile}), do: nil
  defp sidecar_profile(%{profile: profile}), do: profile

  # ── Named states ────────────────────────────────────────────────────────────

  @doc """
  Saves the machine under a name, with its portrait: the state itself, a
  `meta.json`, and — when the frame is there to take — a 160×144 PNG.
  Saving an existing name overwrites the trio.
  """
  @spec save_state(t(), String.t(), {struct(), map(), struct()}, binary() | nil) :: :ok
  def save_state(lib, name, payload, rgb \\ nil) do
    name = sanitize(name)
    path = state_path(lib, name)
    File.mkdir_p!(Path.dirname(path))
    Save.write_state(path, payload)

    if lib.mode == :library do
      meta = %{
        name: name,
        created_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        profile: lib.profile
      }

      File.write!(meta_path(path), JSON.encode!(meta))
      if rgb, do: File.write!(png_path(path), png(rgb, 160, 144))
    end

    :ok
  end

  @doc "Reads a named state back — `:error` when it does not exist."
  @spec load_state(t(), String.t()) :: {:ok, {struct(), map(), struct()}} | :error
  def load_state(lib, name), do: Save.read_state(state_path(lib, name))

  @doc "Removes a named state, portrait and metadata included."
  @spec delete_state(t(), String.t()) :: :ok
  def delete_state(lib, name) do
    path = state_path(lib, name)
    Enum.each([path, meta_path(path), png_path(path)], &File.rm/1)
    :ok
  end

  @doc """
  The current profile's states, newest first: name, ISO 8601 timestamp,
  and the screenshot's absolute path when one exists. A state without its
  `meta.json` still lists — the name from the filename, the time from the
  file — never a crash.
  """
  @spec list(t()) :: [%{name: String.t(), at: String.t(), png: String.t() | nil}]
  def list(%{mode: :sidecar}), do: []

  def list(lib) do
    dir = states_dir(lib)

    # File.ls, not Path.wildcard: paths carry spaces and worse, and a ROM
    # called "Tetris [!]" must not become a character class.
    for file <- ls(dir), String.ends_with?(file, ".state") do
      path = Path.join(dir, file)
      name = Path.basename(file, ".state")

      at =
        with {:ok, raw} <- File.read(meta_path(path)),
             {:ok, %{"created_at" => at}} <- JSON.decode(raw) do
          at
        else
          _ ->
            path
            |> File.stat!(time: :posix)
            |> Map.fetch!(:mtime)
            |> DateTime.from_unix!()
            |> DateTime.to_iso8601()
        end

      png = if File.exists?(png_path(path)), do: png_path(path)
      %{name: name, at: at, png: png}
    end
    |> Enum.sort_by(& &1.at, :desc)
  end

  @doc "The profiles of this game — every battery in its folder, `game` first."
  @spec profiles(t()) :: [String.t()]
  def profiles(%{mode: :sidecar} = lib), do: [lib.profile]

  def profiles(lib) do
    found =
      for file <- ls(lib.dir), String.ends_with?(file, ".sav"), do: Path.basename(file, ".sav")

    ([@default_profile | found] ++ [lib.profile])
    |> Enum.uniq()
    |> Enum.sort_by(&(&1 != @default_profile))
  end

  @doc "Switches profile — the caller owns the power cycle around it."
  @spec set_profile(t(), String.t()) :: t()
  def set_profile(lib, profile), do: %{lib | profile: sanitize(profile)}

  @doc "Copies the current battery back beside the ROM — the door to other emulators."
  @spec export(t()) :: :ok | {:error, term()}
  def export(%{mode: :sidecar}), do: :ok

  def export(lib) do
    target = Save.path(lib.rom_path, sidecar_profile(lib))

    case File.copy(sav_path(lib), target) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # ── Adoption ────────────────────────────────────────────────────────────────

  # First sight of a game: its folder is created and whatever the sidecar
  # convention left beside the ROM is copied in. `.sav` becomes the default
  # battery, `.state` becomes slot-1, `.caseN.state` slot-N, and the
  # `.name.`-prefixed variants land in profile `name`. Copies, never moves:
  # the originals belong to the player.
  defp prepare(dir, rom_path) do
    if File.dir?(dir) do
      :ok
    else
      case File.mkdir_p(dir) do
        :ok -> adopt(dir, rom_path)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp adopt(dir, rom_path) do
    stem = Path.basename(Path.rootname(rom_path)) <> "."

    for file <- ls(Path.dirname(rom_path)),
        String.starts_with?(file, stem),
        target = adopted_target(dir, String.replace_prefix(file, stem, "")),
        target != nil do
      path = Path.join(Path.dirname(rom_path), file)
      File.mkdir_p!(Path.dirname(target))
      File.copy(path, target)

      if String.ends_with?(target, ".state") do
        name = Path.basename(target, ".state")
        profile = target |> Path.dirname() |> Path.basename()

        at =
          path
          |> File.stat!(time: :posix)
          |> Map.fetch!(:mtime)
          |> DateTime.from_unix!()
          |> DateTime.to_iso8601()

        File.write!(
          meta_path(target),
          JSON.encode!(%{name: name, created_at: at, profile: profile})
        )
      end
    end

    :ok
  end

  # The sidecar suffix, decoded into a library destination. `nil` skips a
  # file the convention does not know.
  defp adopted_target(dir, suffix) do
    case String.split(suffix, ".") do
      ["sav"] ->
        Path.join(dir, "game.sav")

      ["state"] ->
        Path.join([dir, "states", "game", "slot-1.state"])

      ["case" <> n, "state"] ->
        Path.join([dir, "states", "game", "slot-#{n}.state"])

      [profile, "sav"] ->
        Path.join(dir, sanitize(profile) <> ".sav")

      [profile, "case" <> n, "state"] ->
        Path.join([dir, "states", sanitize(profile), "slot-#{n}.state"])

      [profile, "state"] ->
        Path.join([dir, "states", sanitize(profile), "slot-1.state"])

      _ ->
        nil
    end
  end

  # ── Small change ────────────────────────────────────────────────────────────

  defp ls(dir) do
    case File.ls(dir) do
      {:ok, files} -> files
      _ -> []
    end
  end

  defp meta_path(state_path), do: Path.rootname(state_path) <> ".meta.json"
  defp png_path(state_path), do: Path.rootname(state_path) <> ".png"

  @doc """
  A name made filesystem-safe: letters, digits, space, dash, underscore;
  everything else folds to `_`, and emptiness becomes `state`.
  """
  @spec sanitize(String.t()) :: String.t()
  def sanitize(name) do
    case name |> String.replace(~r/[^A-Za-z0-9 _-]+/, "_") |> String.trim() do
      "" -> "state"
      safe -> safe
    end
  end

  @doc """
  The frame as PNG: 8-bit RGB, no filtering, one IDAT — thirty lines
  instead of a dependency, `:zlib` doing the real work. `Screen.to_rgb`
  feeds it; any PNG reader eats it.
  """
  @spec png(binary(), pos_integer(), pos_integer()) :: binary()
  def png(rgb, width, height) when byte_size(rgb) == width * height * 3 do
    # Every scanline opens with filter byte 0: None.
    raw =
      for row <- 0..(height - 1),
          into: <<>>,
          do: <<0>> <> binary_part(rgb, row * width * 3, width * 3)

    header = <<width::32, height::32, 8, 2, 0, 0, 0>>

    <<0x89, ?P, ?N, ?G, ?\r, ?\n, 0x1A, ?\n>> <>
      chunk("IHDR", header) <> chunk("IDAT", :zlib.compress(raw)) <> chunk("IEND", <<>>)
  end

  defp chunk(type, data) do
    payload = type <> data
    <<byte_size(data)::32>> <> payload <> <<:erlang.crc32(payload)::32>>
  end

  @doc "The screenshot for a raw frame — through the panel the player sees."
  @spec screenshot(binary() | nil, :gray | :dmg, Atomboy.LCD.t() | nil) :: binary() | nil
  def screenshot(nil, _palette, _lcd), do: nil
  def screenshot(frame, palette, lcd), do: Screen.to_rgb(frame, palette, lcd)
end
