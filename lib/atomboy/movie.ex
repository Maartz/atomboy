defmodule Atomboy.Movie do
  @moduledoc """
  A movie: an anchor, and every button pressed since — the machine's memoir.

  The emulation core touches no randomness, so a session is entirely
  determined by where it started and what was held on each frame. That is
  the whole artifact: an **anchor** (a starting machine) and a **track**
  (one byte per frame). Replay is not a recording of the screen; it is the
  same arithmetic run again, and it lands on the same pixel.

  One thing in the machine would have answered differently tomorrow: an
  MBC3's real-time clock. So the take carries its own hour too, and it is
  the third thing the file holds — see `clock/2`.

  The file is a versioned term in the snapshot idiom `Atomboy.Save` set —
  `{:atomboy_movie, 1, header, anchor, track}` through
  `term_to_binary(…, [:compressed])` — and wears the `.tas` extension.

  ## The anchor

  `{:boot, sram}` is power-on, and it carries the battery as it stood when
  recording began (`:none` when the cartridge had none, or the file did not
  exist yet). Boot purity means ROM + embedded SRAM + track, and nothing
  else: Pokémon from power-on plays differently with yesterday's save, so
  the save travels inside the movie.

  `{:snapshot, state, ram, apu}` is a mid-game start — exactly the three
  values `Save.write_state/2` freezes, so a savestate and a movie's anchor
  are the same term and stay interchangeable.

  ## The track's byte

  One byte per frame, active **high** — a set bit is a key held, and a frame
  with nothing pressed is `0x00`:

      bit 0 Right   bit 1 Left   bit 2 Up      bit 3 Down
      bit 4 A       bit 5 B      bit 6 Select  bit 7 Start

  The order is `Atomboy.Joypad`'s, nibble for nibble: directions in the low
  nibble and buttons in the high one, each in the order the hardware lines
  carry them. Only the polarity is flipped — the lines are active low (0 =
  pressed) because that is how the matrix reads, but a movie is read by
  people as often as by machines, and a run of `0x00` is a run of a player
  holding still. `from_lines/2` and `to_lines/1` cross that boundary, and
  they are the only two places the inversion lives.

  ## The track's shape

  The track is a plain binary. Appending a byte to a binary the process
  itself built is amortised O(1) — the VM keeps slack at the end and writes
  in place — `:binary.at/2` is O(1) for `at/2`, `binary_part/3` makes
  truncation a sub-binary rather than a copy, and `term_to_binary` writes
  bytes as bytes instead of tagging a list element by element. An hour of
  play is ~216 KB raw, and far less once compressed.

  The frame count in the header is derived from the track and restamped by
  every operation that changes it: there is one truth about how long a movie
  is, and it is the track's size.

  Pure data and file IO — the play loop's business (when to append, when to
  override the joypad) lives in the loop.
  """

  import Bitwise

  alias Atomboy.Library

  @extension ".tas"

  # The cartridge header's own checksum (0x14D) — one byte covering
  # 0x134-0x14C. `Library.game_id/1` already carries the title and the global
  # checksum; this is the third witness the spec asks for, and the cheapest
  # to compare.
  @header_checksum 0x14D

  # Everything below 0x150 is header: a shorter binary is not a cartridge.
  @min_rom 0x150

  defstruct header: %{}, anchor: {:boot, :none}, track: <<>>

  @typedoc "The identity a movie refuses to be replayed against the wrong ROM by."
  @type rom_id :: %{id: String.t(), header_checksum: byte()}

  @typedoc "Where the movie starts: power-on with its battery, or a frozen machine."
  @type anchor :: {:boot, binary() | :none} | {:snapshot, struct(), map(), struct()}

  @type header :: %{
          rom: rom_id(),
          anchor: :boot | :snapshot,
          frames: non_neg_integer(),
          rerecords: non_neg_integer(),
          codes: [Atomboy.Codes.poke()],
          created_at: String.t() | nil,
          epoch: integer() | nil,
          author: String.t()
        }

  @type t :: %__MODULE__{header: header(), anchor: anchor(), track: binary()}

  # What a header is missing when it comes from an older file. The read path
  # merges onto these the way `Save.read_state/1` rehydrates structs: a movie
  # written before a field existed still plays.
  @header_defaults %{
    rom: %{id: "", header_checksum: nil},
    anchor: :boot,
    frames: 0,
    rerecords: 0,
    codes: [],
    created_at: nil,
    epoch: nil,
    author: ""
  }

  @doc "The extension movies wear on disk."
  @spec extension() :: String.t()
  def extension, do: @extension

  # ── Building ────────────────────────────────────────────────────────────────

  @doc """
  A fresh movie for a ROM and an anchor, its track empty.

  `opts` fills the rest of the header: `:codes` (the active GameShark pokes,
  kept in the shape `Atomboy.Codes` parses them into — they poke memory every
  frame, so they are part of the recording's truth), `:author`, `:created_at`
  (an ISO 8601 string; stamped now when absent), `:epoch` (the console clock
  at the anchor — see `clock/2`) and `:rerecords` for a counter that starts
  somewhere other than zero.
  """
  @spec new(binary(), anchor(), keyword()) :: t()
  def new(rom, anchor, opts \\ []) when is_binary(rom) do
    header = %{
      rom: rom_id(rom),
      anchor: kind(anchor),
      frames: 0,
      rerecords: Keyword.get(opts, :rerecords, 0),
      codes: Keyword.get(opts, :codes, []),
      created_at: Keyword.get(opts, :created_at) || DateTime.to_iso8601(DateTime.utc_now()),
      epoch: Keyword.get(opts, :epoch),
      author: Keyword.get(opts, :author, "")
    }

    %__MODULE__{header: header, anchor: anchor, track: <<>>}
  end

  @doc """
  A cartridge's identity: the library's game key — title and global checksum,
  the same string that names the game's folder — plus the header checksum.

  One identity path, not two: a movie and the save folder it sits in can
  never disagree about which game they belong to.
  """
  @spec rom_id(binary()) :: rom_id()
  def rom_id(rom) when is_binary(rom) and byte_size(rom) >= @min_rom do
    %{id: Library.game_id(rom), header_checksum: :binary.at(rom, @header_checksum)}
  end

  @doc """
  Appends a frame's joypad byte — the last frame of the movie so far.
  """
  @spec append_frame(t(), byte()) :: t()
  def append_frame(%__MODULE__{} = movie, byte) when byte in 0..255 do
    restamp(%{movie | track: <<movie.track::binary, byte>>})
  end

  @doc """
  The byte held on `frame`, counting from zero — `nil` past the end of the
  track, which is how a replay learns it has run out of future.
  """
  @spec at(t() | binary(), integer()) :: byte() | nil
  def at(%__MODULE__{track: track}, frame), do: at(track, frame)

  def at(track, frame)
      when is_binary(track) and is_integer(frame) and frame >= 0 and frame < byte_size(track),
      do: :binary.at(track, frame)

  def at(track, _frame) when is_binary(track), do: nil

  @doc "How many frames the movie holds."
  @spec frames(t()) :: non_neg_integer()
  def frames(%__MODULE__{track: track}), do: byte_size(track)

  # ── The take's own clock ────────────────────────────────────────────────────

  @doc """
  What time it is on frame `frame` of this take — Unix seconds.

  A cartridge with a clock in it (MBC3's RTC: Pokémon's berries, Crystal's
  calendar) is the one thing in the machine that would answer differently
  tomorrow, and a movie that asked the wall what time it was would desync on
  the second replay. So a take carries its own hour: the header's **epoch**,
  the console clock as it stood at the anchor, and time thereafter is
  counted in frames — 70,224 T-cycles of a 4.194304 MHz machine each, in
  integer arithmetic, which never runs backwards and never depends on how
  fast the replay is going.

  Because the hour is a function of the frame index alone, re-recording
  needs no bookkeeping: `truncate/2` cuts the track, the frames that follow
  are played again from the same anchor, and they are told the same time
  they were told the first time round. A take's clock belongs to the take,
  not to the attempt.

  A movie written before this field existed has no epoch. Its `created_at`
  stands in — the hour it was recorded, to the second the file remembers —
  and failing even that, the Unix epoch itself: an old take replays with a
  clock that is at least the same on every machine, which is the property
  that matters.
  """
  @spec clock(t(), non_neg_integer()) :: integer()
  def clock(%__MODULE__{} = movie, frame) when is_integer(frame) and frame >= 0,
    do: epoch(movie) + div(frame * 70_224, 4_194_304)

  @doc "The console clock at the anchor — see `clock/2` for what stands in when the file has none."
  @spec epoch(t()) :: integer()
  def epoch(%__MODULE__{header: header}) do
    case Map.get(header, :epoch) do
      seconds when is_integer(seconds) -> seconds
      _absent -> created_at_epoch(Map.get(header, :created_at))
    end
  end

  defp created_at_epoch(stamp) when is_binary(stamp) do
    case DateTime.from_iso8601(stamp) do
      {:ok, datetime, _offset} -> DateTime.to_unix(datetime)
      _ -> 0
    end
  end

  defp created_at_epoch(_absent), do: 0

  @doc """
  Cuts the movie back to `frame` frames — frames 0 to `frame - 1` survive,
  everything after is forgotten, and the header's frame count follows.

  This is re-recording's blade: a state loaded at frame N while recording
  means the take from N onwards never happened. Bumping the re-record
  counter is the **caller's** job (`rerecorded/1`) — truncation also happens
  for reasons that are not a re-record, and this function refuses to guess
  which one it is looking at.

  A frame beyond the track leaves the movie alone; a negative one empties it.
  """
  @spec truncate(t(), integer()) :: t()
  def truncate(%__MODULE__{track: track} = movie, frame) do
    keep = frame |> max(0) |> min(byte_size(track))
    restamp(%{movie | track: binary_part(track, 0, keep)})
  end

  @doc "One more take: the re-record counter, incremented."
  @spec rerecorded(t()) :: t()
  def rerecorded(%__MODULE__{header: header} = movie),
    do: %{movie | header: %{header | rerecords: header.rerecords + 1}}

  # ── The joypad byte ─────────────────────────────────────────────────────────

  @doc """
  The track's byte from the two nibbles `Atomboy.Joypad.set/3` is handed —
  active low on the lines, active high in the movie.
  """
  @spec from_lines(0..15, 0..15) :: byte()
  def from_lines(dpad, btns) when dpad in 0..15 and btns in 0..15 do
    bxor(dpad, 0x0F) ||| bxor(btns, 0x0F) <<< 4
  end

  @doc "The byte back into `{dpad, buttons}` lines, ready for `Joypad.set/3`."
  @spec to_lines(byte()) :: {0..15, 0..15}
  def to_lines(byte) when byte in 0..255 do
    {bxor(byte &&& 0x0F, 0x0F), bxor(byte >>> 4, 0x0F)}
  end

  # ── The file ────────────────────────────────────────────────────────────────

  @doc "Writes the movie — one compressed term, the whole take."
  @spec write(t(), Path.t()) :: :ok | {:error, File.posix()}
  def write(%__MODULE__{} = movie, path) do
    movie = restamp(movie)
    term = {:atomboy_movie, 1, movie.header, movie.anchor, movie.track}
    File.write(path, :erlang.term_to_binary(term, [:compressed]))
  end

  @doc """
  Reads a movie back. It knows nothing of any ROM — a file alone cannot say
  whether it belongs to the cartridge in the drive, and that is `verify/2`'s
  question. What it does refuse is a term that is not a movie: a wrong tag, a
  version from a future release, an anchor of an unknown shape or a track
  that is not bytes all come back `{:error, :corrupt}`, never as an
  exception.
  """
  @spec read(Path.t()) :: {:ok, t()} | {:error, :corrupt | File.posix()}
  def read(path) do
    case File.read(path) do
      {:ok, data} -> decode(data)
      {:error, reason} -> {:error, reason}
    end
  end

  # The file's own bytes, kept apart from the file's own errors: a term that
  # happens to look like `{:error, :enoent}` is a corrupt movie, not a
  # missing one.
  defp decode(data) do
    with {:atomboy_movie, 1, header, anchor, track} <- :erlang.binary_to_term(data),
         true <- is_map(header) and is_binary(track),
         {:ok, anchor} <- revive(anchor) do
      movie = %__MODULE__{
        header: Map.merge(@header_defaults, header),
        anchor: anchor,
        track: track
      }

      {:ok, restamp(movie)}
    else
      _ -> {:error, :corrupt}
    end
  rescue
    ArgumentError -> {:error, :corrupt}
  end

  @doc """
  Whether this movie belongs to this ROM. A movie replayed against another
  dump desynchronises within seconds and blames the emulator, so the three
  witnesses of the cartridge header are compared before a single frame runs.
  """
  @spec verify(t(), binary()) :: :ok | {:error, :wrong_rom}
  def verify(%__MODULE__{header: %{rom: rom_id}}, rom)
      when is_binary(rom) and byte_size(rom) >= @min_rom do
    if rom_id == rom_id(rom), do: :ok, else: {:error, :wrong_rom}
  end

  def verify(%__MODULE__{}, _rom), do: {:error, :wrong_rom}

  # ── Small change ────────────────────────────────────────────────────────────

  # The header's frame count is a copy of a fact the track already states.
  # Every operation that moves the track passes through here, so the copy
  # cannot drift — including on read, where a hand-edited count loses to the
  # bytes.
  defp restamp(%__MODULE__{header: header, track: track} = movie),
    do: %{movie | header: %{header | frames: byte_size(track)}}

  defp kind({:boot, _sram}), do: :boot
  defp kind({:snapshot, _state, _ram, _apu}), do: :snapshot

  # An anchor read from a file, checked for shape and — for a snapshot —
  # brought onto today's structs. The rehydration is `Save.read_state/1`'s,
  # for the same reason: a movie anchored on a machine frozen by last
  # month's release must still start, with new fields taking their defaults
  # rather than raising a KeyError one frame in.
  defp revive({:boot, sram}) when is_binary(sram) or sram == :none, do: {:ok, {:boot, sram}}

  defp revive({:snapshot, %{__struct__: _} = state, ram, %{__struct__: _} = apu})
       when is_map(ram),
       do: {:ok, {:snapshot, rehydrate(state), ram, rehydrate(apu)}}

  defp revive(_other), do: :error

  defp rehydrate(%{__struct__: module} = frozen),
    do: struct(module, Map.delete(frozen, :__struct__))
end
