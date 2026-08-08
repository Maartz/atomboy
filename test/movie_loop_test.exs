defmodule Atomboy.MovieLoopTest do
  use ExUnit.Case

  alias Atomboy.Library
  alias Atomboy.Movie
  alias Atomboy.Play
  alias Atomboy.Screen

  @moduletag :tmp_dir

  # How long a determinism run lasts. Long enough that a seam consulted
  # every frame but one cannot hide behind a short take, and cheap enough to
  # run four times over: ~5 ms of emulation per frame.
  @frames 70

  # The kitty protocol's press and release event numbers.
  @press 1
  @release 3

  # A scripted session, frame by frame — what the fingers do. D-pad and
  # buttons overlap on purpose: a track of nothing but zeros proves nothing.
  @session %{
    2 => [{:right, @press}],
    6 => [{:a, @press}],
    11 => [{:right, @release}, {:down, @press}],
    15 => [{:b, @press}, {:start, @press}],
    19 => [{:a, @release}, {:down, @release}],
    24 => [{:left, @press}, {:select, @press}],
    30 => [{:b, @release}, {:start, @release}],
    37 => [{:up, @press}],
    44 => [{:left, @release}, {:select, @release}],
    52 => [{:up, @release}, {:right, @press}, {:a, @press}],
    61 => [{:right, @release}, {:a, @release}]
  }

  # Another pair of hands on the pad while a movie plays. Every replay in
  # this file is driven with these underneath: if a single one of them
  # reached the machine, the frames would part company with the recording.
  @mischief %{
    1 => [{:left, @press}, {:b, @press}],
    9 => [{:start, @press}],
    17 => [{:left, @release}, {:up, @press}],
    28 => [{:b, @release}, {:a, @press}],
    40 => [{:up, @release}, {:down, @press}, {:select, @press}],
    55 => [{:a, @release}, {:down, @release}]
  }

  # The loop draws every frame it runs. The tests care about the machine
  # underneath the pixels, so the drawing goes where drawing goes to die.
  setup do
    {:ok, null} = File.open("/dev/null", [:write, encoding: :unicode])
    Process.group_leader(self(), null)
    :ok
  end

  describe "the determinism property" do
    test "a recorded session replays frame for frame", %{tmp_dir: dir} do
      {recorded, movie} = record_session(dir)

      # One byte per frame, no more and no fewer: the seam ran every frame.
      assert byte_size(movie.track) == @frames
      assert Movie.frames(movie) == @frames
      assert movie.header.anchor == :boot

      assert replay_session(dir, movie) == recorded
    end

    test "the same movie replayed twice lands on the same frames twice", %{tmp_dir: dir} do
      {_recorded, movie} = record_session(dir)

      assert replay_session(dir, movie) == replay_session(dir, movie, %{})
    end

    test "a movie anchored on a savestate replays from that savestate", %{tmp_dir: dir} do
      # A dozen frames of ordinary play first: the machine the recording
      # starts on is one no reset could reach.
      ctx = kitty(console(dir))
      {ctx, _warm} = run(ctx, 12, @mischief)

      ctx = Play.start_recording(ctx, author: "the test")
      assert {:snapshot, _state, _ram, _apu} = elem(ctx.movie, 1).anchor

      {ctx, recorded} = run(ctx, 40, @session)
      {movie, _ctx} = Play.stop_movie(ctx)

      # A machine fresh from power-on, which has none of that history: the
      # anchor is what puts it where the take began.
      fresh = Play.start_replay(kitty(console(dir)), movie)
      {_ctx, replayed} = run(fresh, 40, @mischief)

      assert replayed == recorded
    end
  end

  describe "recording" do
    test "the track holds the byte the pad held, frame by frame", %{tmp_dir: dir} do
      ctx = Play.start_recording(kitty(console(dir)), anchor: :boot)

      {ctx, _witnesses} =
        run(ctx, 8, %{
          2 => [{:right, @press}],
          5 => [{:right, @release}, {:a, @press}]
        })

      {movie, _ctx} = Play.stop_movie(ctx)

      # Right is bit 0, A is bit 4, and a frame with nothing held is zero.
      assert movie.track == <<0x00, 0x00, 0x01, 0x01, 0x01, 0x10, 0x10, 0x10>>
    end

    test "the anchor of a boot movie carries the battery it started with", %{tmp_dir: dir} do
      ctx = console(dir)
      File.write!(ctx.sav, :binary.copy(<<0x5A>>, 0x2000))

      assert {:recording, movie} = Play.start_recording(ctx, anchor: :boot).movie
      assert {:boot, sram} = movie.anchor
      assert sram == :binary.copy(<<0x5A>>, 0x2000)
    end

    test "with no battery on disk, a boot movie records its absence", %{tmp_dir: dir} do
      assert {:recording, movie} = Play.start_recording(console(dir), anchor: :boot).movie
      assert movie.anchor == {:boot, :none}
    end

    test "the codes poking the machine are part of the take", %{tmp_dir: dir} do
      ctx = console(dir, codes: "01FF16D1")

      assert {:recording, movie} = Play.start_recording(ctx).movie
      assert movie.header.codes == [{0xD116, 0xFF}]
    end

    test "stopping hands the movie over and gives the pad back", %{tmp_dir: dir} do
      ctx = Play.start_recording(kitty(console(dir)), anchor: :boot)
      {ctx, _witnesses} = run(ctx, 3, @session)

      assert {%Movie{} = movie, ctx} = Play.stop_movie(ctx)
      assert Movie.frames(movie) == 3
      assert ctx.movie == nil
      assert {"● stopped — 3 frames", _left} = ctx.note

      assert Play.stop_movie(ctx) == {nil, ctx}
    end
  end

  describe "replay" do
    test "when the track runs out, the pad goes back to the player", %{tmp_dir: dir} do
      {_recorded, movie} = record_session(dir, @session, 4)

      ctx = Play.start_replay(kitty(console(dir)), movie)
      {ctx, _witnesses} = run(ctx, 4, %{})
      assert {:replaying, _movie, 4} = ctx.movie

      # The fifth frame has nothing left to deal.
      ctx = frame(ctx)
      assert ctx.movie == nil
      assert {"movie ended — controls are yours", _left} = ctx.note
    end

    test "a movie recorded on another cartridge never starts", %{tmp_dir: dir} do
      ctx = console(dir)
      stranger = Movie.new(rom("SOMETHING ELSE"), {:boot, :none})

      ctx = Play.start_replay(ctx, stranger)

      assert ctx.movie == nil
      assert {"this movie was recorded on another cartridge", _left} = ctx.note
    end
  end

  describe "the link cable" do
    test "refuses recording, and leaves the loop as it was", %{tmp_dir: dir} do
      ctx = plugged(console(dir))

      refused = Play.start_recording(ctx)

      assert refused.movie == nil
      assert {"recording unavailable: link cable plugged in", _left} = refused.note
      assert %{refused | note: nil} == ctx
    end

    test "refuses replay, and leaves the loop as it was", %{tmp_dir: dir} do
      ctx = plugged(console(dir))
      movie = Movie.new(ctx.rom, {:boot, :none})

      refused = Play.start_replay(ctx, movie)

      assert refused.movie == nil
      assert {"replay unavailable: link cable plugged in", _left} = refused.note
      assert %{refused | note: nil} == ctx
    end
  end

  describe "frame advance" do
    test "while paused, `.` runs exactly one frame and stops again", %{tmp_dir: dir} do
      ctx = %{console(dir) | paused: true}

      feed(".")
      advanced = frame(ctx)

      assert advanced.frame == ctx.frame + 1
      assert advanced.paused
      refute advanced.advance
    end

    test "the movie advances with it, by one frame and no more", %{tmp_dir: dir} do
      ctx = Play.start_recording(kitty(console(dir)), anchor: :boot)
      ctx = %{ctx | paused: true}

      feed([keystrokes([{:right, @press}]), "."])
      ctx = frame(ctx)

      assert {:recording, movie} = ctx.movie
      assert movie.track == <<0x01>>
    end
  end

  describe "the status line" do
    test "a recording says how long it is, a replay how far along", %{tmp_dir: dir} do
      {_recorded, movie} = record_session(dir, @session, 3)

      # The mark is drawn after the seam has moved, so it names the frame
      # that was just played: one frame of a fresh take is one byte long.
      assert status(Play.start_recording(console(dir), anchor: :boot)) =~ "●1"

      replaying = Play.start_replay(console(dir), movie)
      assert status(replaying) =~ "▶1/3"
      assert status(%{replaying | movie: {:replaying, movie, 2}}) =~ "▶3/3"

      refute status(console(dir)) =~ "▶"
    end
  end

  # ── The bench ───────────────────────────────────────────────────────────────

  # A whole take: record `frames` frames of `session`, keeping every frame's
  # witness, and hand back the movie that came out of it.
  defp record_session(dir, session \\ @session, frames \\ @frames) do
    ctx = Play.start_recording(kitty(console(dir)), anchor: :boot, author: "the test")
    {ctx, witnesses} = run(ctx, frames, session)
    {movie, _ctx} = Play.stop_movie(ctx)

    {witnesses, movie}
  end

  # The same take, read back — on a machine that has never seen it, with
  # another pair of hands mashing the pad throughout.
  defp replay_session(dir, movie, session \\ @mischief) do
    ctx = Play.start_replay(kitty(console(dir)), movie)
    {_ctx, witnesses} = run(ctx, Movie.frames(movie), session)

    witnesses
  end

  defp run(ctx, frames, session) do
    Enum.reduce(0..(frames - 1)//1, {ctx, []}, fn n, {ctx, witnesses} ->
      feed(keystrokes(Map.get(session, n)))
      ctx = frame(ctx)

      {ctx, witnesses ++ [witness(ctx)]}
    end)
  end

  # One frame of the real loop: the frame budget is raised by exactly one,
  # so `loop/1` runs a frame and returns through its own finishing path.
  defp frame(ctx), do: Play.drive(%{ctx | max_frames: ctx.frame + 1})

  # The strongest witness this side of an hour of comparing: the CPU's
  # registers, every write the machine has made, the APU's counters, and the
  # pixels the frame put on the panel. A desync the screen hides (a byte in
  # WRAM, a timer one cycle early) shows in the registers; one the registers
  # hide shows in the pixels. Two hundredths of a millisecond either way.
  defp witness(ctx),
    do: :erlang.crc32(:erlang.term_to_binary({ctx.state, ctx.ram, ctx.apu, ctx.last_frame}))

  # The loop drains its mailbox before every frame, and the keyboard reader
  # is nothing but a process filling that mailbox: bytes posted here arrive
  # exactly as they would off the pty.
  defp feed(nil), do: :ok
  defp feed(bytes), do: send(self(), {:input, bytes})

  # The answer to the kitty query — the protocol with releases in it, so a
  # scripted session can hold two keys at once.
  defp kitty(ctx) do
    feed("\e[?15u")
    ctx
  end

  defp plugged(ctx), do: %{ctx | ram: Map.put(ctx.ram, :link, :a_socket)}

  @arrows %{up: ?A, down: ?B, right: ?C, left: ?D}
  @csi_u %{a: ?x, b: ?c, start: 13, select: ?\s}

  defp keystrokes(nil), do: nil
  defp keystrokes(events), do: Enum.map_join(events, &sequence/1)

  defp sequence({key, event}) when is_map_key(@arrows, key),
    do: "\e[1;1:#{event}#{<<@arrows[key]>>}"

  defp sequence({key, event}), do: "\e[#{@csi_u[key]};1:#{event}u"

  # The status line, as the loop writes it — captured rather than dumped
  # into the void the setup opened.
  defp status(ctx) do
    ExUnit.CaptureIO.capture_io(fn ->
      Play.drive(%{ctx | max_frames: ctx.frame + 1, last_frame: nil})
    end)
  end

  # A console at its first frame, with a deadline long past: every frame is
  # already late, so the loop never sleeps and the suite keeps its speed.
  defp console(dir, opts \\ []) do
    path = Path.join(dir, "pad.gb")
    File.write!(path, rom())
    cartridge = Screen.load(path)
    lib = Library.open(cartridge, path, library: Path.join(dir, "library"))

    ctx = Play.context(cartridge, lib, Keyword.merge([frames: 0], opts))

    %{ctx | deadline: System.monotonic_time(:microsecond) - 1_000_000}
  end

  # A cartridge that does nothing but read the pad and show it: both halves
  # of the joypad matrix, summed into WRAM, and the running total written to
  # the background palette — so every button ever held ends up in the
  # registers, in the map and in the pixels at once. It never halts, so the
  # frame boundary falls mid-loop and cycle-exactness is part of the test.
  defp rom(title \\ "ATOMBOY PAD") do
    code = <<
      # LD A,$91 / LDH ($40),A — the LCD on, the background drawn
      0x3E,
      0x91,
      0xE0,
      0x40,
      # XOR A / LDH ($47),A — the palette starts black
      0xAF,
      0xE0,
      0x47,
      # LD A,$20 / LDH ($00),A / LDH A,($00) / AND $0F / LD B,A — the d-pad
      0x3E,
      0x20,
      0xE0,
      0x00,
      0xF0,
      0x00,
      0xE6,
      0x0F,
      0x47,
      # LD A,$10 / … / SWAP A / OR B — the buttons, in the high nibble
      0x3E,
      0x10,
      0xE0,
      0x00,
      0xF0,
      0x00,
      0xE6,
      0x0F,
      0xCB,
      0x37,
      0xB0,
      # LD C,A / LD A,($C000) / ADD A,C / LD ($C000),A — the running total
      0x4F,
      0xFA,
      0x00,
      0xC0,
      0x81,
      0xEA,
      0x00,
      0xC0,
      # LDH ($47),A / JP $0157 — onto the palette, and round again
      0xE0,
      0x47,
      0xC3,
      0x57,
      0x01
    >>

    :binary.copy(<<0>>, 0x8000)
    |> put(0x100, <<0xC3, 0x50, 0x01>>)
    |> put(0x134, title |> String.pad_trailing(0x10, <<0>>) |> binary_part(0, 0x10))
    |> put(0x14D, <<0x5A>>)
    |> put(0x14E, <<0x91, 0xE2>>)
    |> put(0x150, code)
  end

  defp put(binary, at, chunk) do
    tail = at + byte_size(chunk)

    binary_part(binary, 0, at) <> chunk <> binary_part(binary, tail, byte_size(binary) - tail)
  end
end
