defmodule Atomboy.ServerTest do
  use ExUnit.Case

  import ExUnit.CaptureIO

  alias Atomboy.Library
  alias Atomboy.Movie
  alias Atomboy.Screen

  # A ROM that spins in place: JR -2 at the 0x100 entry point.
  defp spinning_rom(dir) do
    rom = :binary.copy(<<0>>, 0x100) <> <<0x18, 0xFE>> <> :binary.copy(<<0>>, 0x8000 - 0x102)
    path = Path.join(dir, "loop.gb")
    File.write!(path, rom)
    path
  end

  defp split(<<?F, rgb::binary-size(160 * 144 * 3), rest::binary>>, frames, pcm, panels),
    do: split(rest, frames + 1, pcm, panels)

  defp split(<<?A, n::16-big, block::binary-size(n), rest::binary>>, frames, pcm, panels),
    do: split(rest, frames, pcm + byte_size(block), panels)

  defp split(<<?P, preset, rest::binary>>, frames, pcm, panels),
    do: split(rest, frames, pcm, panels ++ [preset])

  defp split(<<>>, frames, pcm, panels), do: {frames, pcm, panels}

  @tag :tmp_dir
  test "the server stream: RGB24 frames, PCM and the panel, nothing else", %{tmp_dir: dir} do
    rom = spinning_rom(dir)

    stream =
      capture_io([encoding: :latin1], fn ->
        assert :ok = Atomboy.Server.run(rom, frames: 3)
      end)

    {frames, pcm, panels} = split(stream, 0, 0, [])
    assert frames == 3
    # The wall-clock pacing starts with its lead (~2048 samples × 4).
    assert pcm >= 8192
    # s16le stereo: always a multiple of 4.
    assert rem(pcm, 4) == 0
    # The panel announced once, before anything else: raw is index 0.
    assert panels == [0]
    assert :binary.first(stream) == ?P
  end

  @tag :tmp_dir
  test "--panel travels down the wire as its preset index", %{tmp_dir: dir} do
    rom = spinning_rom(dir)

    stream =
      capture_io([encoding: :latin1], fn ->
        assert :ok = Atomboy.Server.run(rom, frames: 1, panel: :pocket)
      end)

    {_frames, _pcm, panels} = split(stream, 0, 0, [])
    assert panels == [Enum.find_index(Atomboy.LCD.presets(), &(&1 == :pocket))]
  end

  # The loop drains its mailbox before the first frame, and the stdin
  # reader is nothing but a process filling that mailbox: an op posted
  # before `run/2` arrives exactly as one read off the wire would.
  defp send_ops(ops), do: Enum.each(ops, &send(self(), &1))

  @tag :tmp_dir
  test "a capped turbo emits one frame per speed step, and no sound", %{tmp_dir: dir} do
    rom = spinning_rom(dir)

    stream =
      capture_io([encoding: :latin1], fn ->
        send_ops([{:key, ?T, 2}, {:key, ?+, ?T}])
        assert :ok = Atomboy.Server.run(rom, frames: 4)
      end)

    {frames, pcm, _panels} = split(stream, 0, 0, [])
    assert frames == 2
    assert pcm == 0
  end

  @tag :tmp_dir
  test "turbo is held: the release gives the frames and the sound back", %{tmp_dir: dir} do
    rom = spinning_rom(dir)

    stream =
      capture_io([encoding: :latin1], fn ->
        send_ops([{:key, ?T, 4}, {:key, ?+, ?T}, {:key, ?-, ?T}])
        assert :ok = Atomboy.Server.run(rom, frames: 4)
      end)

    {frames, pcm, _panels} = split(stream, 0, 0, [])
    assert frames == 4
    assert pcm > 0
  end

  @tag :tmp_dir
  test "a turbo speed nobody knows leaves the speed where it stands", %{tmp_dir: dir} do
    rom = spinning_rom(dir)

    stream =
      capture_io([encoding: :latin1], fn ->
        send_ops([{:key, ?T, 2}, {:key, ?T, 3}, {:key, ?+, ?T}])
        assert :ok = Atomboy.Server.run(rom, frames: 4)
      end)

    # Still the 2× asked for first — not uncapped's one frame in four.
    {frames, _pcm, _panels} = split(stream, 0, 0, [])
    assert frames == 2
  end

  @tag :tmp_dir
  test "--turbo caps the speed of a server started from the command line", %{tmp_dir: dir} do
    rom = spinning_rom(dir)

    stream =
      capture_io([encoding: :latin1], fn ->
        send_ops([{:key, ?+, ?T}])
        assert :ok = Atomboy.Server.run(rom, frames: 4, turbo_speed: 2)
      end)

    {frames, _pcm, _panels} = split(stream, 0, 0, [])
    assert frames == 2
  end

  # ── The movies ──────────────────────────────────────────────────────────────

  # The stream read for the movie's announcements alone. The frames and the
  # PCM are skipped by their own lengths, which is the only way to know that
  # a byte in this stream is an op and not a pixel that happens to be one.
  defp movie_states(<<?F, _rgb::binary-size(160 * 144 * 3), rest::binary>>),
    do: movie_states(rest)

  defp movie_states(<<?A, n::16-big, _pcm::binary-size(n), rest::binary>>),
    do: movie_states(rest)

  defp movie_states(<<?P, _preset, rest::binary>>), do: movie_states(rest)
  defp movie_states(<<?R, state, rest::binary>>), do: [state | movie_states(rest)]
  defp movie_states(<<>>), do: []

  defp library(dir), do: Path.join(dir, "library")

  # The takes this game has on disk, newest first — through the library's own
  # eyes, so the test and the engine agree on where a movie lands.
  defp newest_take(dir, rom_path) do
    rom = Screen.load(rom_path)
    lib = Library.open(rom, rom_path, library: library(dir))
    [path | _older] = Library.movies(lib)
    {:ok, movie} = Movie.read(path)
    movie
  end

  # An op posted to arrive while the game is already running: everything sent
  # before `run/2` lands in the same first drain, and a take that is meant to
  # hold frames needs the machine to have run some. Only the ORDER of these
  # matters to what is asserted — a slow machine that delivers all three into
  # one drain still saves, then loads, then stops.
  defp later(ops) do
    ops
    |> Enum.with_index(1)
    |> Enum.each(fn {op, n} -> Process.send_after(self(), op, n * 50) end)
  end

  @tag :tmp_dir
  test "the record op starts a take, and the engine says so itself", %{tmp_dir: dir} do
    rom = spinning_rom(dir)

    stream =
      capture_io([encoding: :latin1], fn ->
        send_ops([{:key, ?R, 1}])
        assert :ok = Atomboy.Server.run(rom, frames: 3, library: library(dir))
      end)

    # One announcement, and only one: the state is said when it changes.
    assert movie_states(stream) == [1]
  end

  @tag :tmp_dir
  test "the stop op writes the take into the game's own folder", %{tmp_dir: dir} do
    rom = spinning_rom(dir)

    stream =
      capture_io([encoding: :latin1], fn ->
        send_ops([{:key, ?R, 1}])
        later([{:key, ?R, 0}])
        assert :ok = Atomboy.Server.run(rom, frames: 20, library: library(dir))
      end)

    assert movie_states(stream) == [1, 0]

    movie = newest_take(dir, rom)
    # Started mid-game, so the machine itself is the anchor.
    assert {:snapshot, _state, _ram, _apu} = movie.anchor
    assert movie.header.rom.id == Library.game_id(Screen.load(rom))
  end

  @tag :tmp_dir
  test "the replay op plays a take back, by path", %{tmp_dir: dir} do
    rom = spinning_rom(dir)
    path = Path.join(dir, "run.tas")

    movie = %{Movie.new(Screen.load(rom), {:boot, :none}) | track: <<0, 0, 0, 0, 0, 0>>}
    :ok = Movie.write(movie, path)

    stream =
      capture_io([encoding: :latin1], fn ->
        send_ops([{:movie, :replay, path}])
        assert :ok = Atomboy.Server.run(rom, frames: 3, library: library(dir))
      end)

    assert movie_states(stream) == [2]
  end

  # The door the engine must not open on trust: a take installed without
  # asking the cartridge whether it is its own desynchronises within seconds
  # and blames the emulator.
  @tag :tmp_dir
  test "a take recorded on another cartridge is refused at the door", %{tmp_dir: dir} do
    rom = spinning_rom(dir)
    path = Path.join(dir, "stranger.tas")

    # Another cartridge means another identity, and the identity is read off
    # the header: a title where the header keeps one.
    stranger =
      binary_part(File.read!(rom), 0, 0x134) <>
        "SOMETHING ELSE  " <> binary_part(File.read!(rom), 0x144, 0x8000 - 0x144)

    :ok = Movie.write(%{Movie.new(stranger, {:boot, :none}) | track: <<0, 0, 0>>}, path)

    stream =
      capture_io([encoding: :latin1], fn ->
        send_ops([{:movie, :replay, path}])
        assert :ok = Atomboy.Server.run(rom, frames: 3, library: library(dir))
      end)

    # Nothing announced, because nothing happened.
    assert movie_states(stream) == []
  end

  @tag :tmp_dir
  test "a state loaded while recording re-records rather than desynchronising",
       %{tmp_dir: dir} do
    rom = spinning_rom(dir)

    capture_io([encoding: :latin1], fn ->
      send_ops([{:key, ?R, 1}])
      later([{:library, :save, "mid"}, {:library, :load, "mid"}, {:key, ?R, 0}])
      assert :ok = Atomboy.Server.run(rom, frames: 30, library: library(dir))
    end)

    # The counter is the whole proof: only a load that went through the
    # loop's own door — the one that reads the take's stamp off the machine
    # — ever moves it.
    assert newest_take(dir, rom).header.rerecords == 1
  end

  @tag :tmp_dir
  test "a machine loaded mid-take carries no stamp into the next one", %{tmp_dir: dir} do
    rom = spinning_rom(dir)

    capture_io([encoding: :latin1], fn ->
      send_ops([{:key, ?R, 1}])

      later([
        {:library, :save, "mid"},
        {:library, :load, "mid"},
        {:key, ?R, 0},
        {:key, ?R, 1},
        {:key, ?R, 0}
      ])

      assert :ok = Atomboy.Server.run(rom, frames: 40, library: library(dir))
    end)

    # The second take is anchored on the machine the first one left behind.
    # A load that skipped the door would have left the take's bookkeeping in
    # the memory map, and it would be sitting in this anchor.
    assert {:snapshot, _state, ram, _apu} = newest_take(dir, rom).anchor
    refute Map.has_key?(ram, :movie_take)
  end

  @tag :tmp_dir
  test "frame advance buys exactly one frame while the menu holds the world still",
       %{tmp_dir: dir} do
    rom = spinning_rom(dir)

    # The budget is one frame and the menu is open: nothing but `.` can
    # spend it. A frame advance that stopped working hangs this test rather
    # than failing it, which is the loudest a missing frame gets.
    stream =
      capture_io([encoding: :latin1], fn ->
        send_ops([{:key, ?+, ?M}, {:key, ?+, ?.}])
        assert :ok = Atomboy.Server.run(rom, frames: 1, library: library(dir))
      end)

    {frames, _pcm, _panels} = split(stream, 0, 0, [])
    assert frames == 1
  end
end
