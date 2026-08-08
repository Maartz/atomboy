defmodule Atomboy.MovieDoorsTest do
  use ExUnit.Case

  alias Atomboy.Library
  alias Atomboy.Movie
  alias Atomboy.Play
  alias Atomboy.Screen

  @moduletag :tmp_dir

  # The doors a take is walked through by a person: the command line, the
  # in-game menu, and the file a stopped recording ends up in. The seam
  # itself belongs to `movie_loop_test.exs`; what is checked here is that
  # each door reaches it, and says the right thing when it cannot.

  setup do
    {:ok, null} = File.open("/dev/null", [:write, encoding: :unicode])
    Process.group_leader(self(), null)
    :ok
  end

  describe "the command line" do
    test "--record starts a boot-anchored take before the first frame", %{tmp_dir: dir} do
      ctx = console(dir, record: Path.join(dir, "run.tas"))

      assert {:recording, movie} = ctx.movie
      assert {:boot, :none} = movie.anchor
      assert Movie.frames(movie) == 0
    end

    test "--record carries the battery as it stood on disk", %{tmp_dir: dir} do
      sav = Library.sav_path(library(dir, rom_path(dir)))
      File.mkdir_p!(Path.dirname(sav))
      File.write!(sav, :binary.copy(<<0x5A>>, 0x2000))

      assert {:recording, movie} = console(dir, record: Path.join(dir, "run.tas")).movie
      assert {:boot, sram} = movie.anchor
      assert sram == :binary.copy(<<0x5A>>, 0x2000)
    end

    test "the session ending writes the take where it was asked for", %{tmp_dir: dir} do
      path = Path.join(dir, "run.tas")
      ctx = console(dir, record: path, frames: 4)

      ctx = Play.drive(ctx)

      assert ctx.movie == nil
      assert {:ok, movie} = Movie.read(path)
      assert Movie.frames(movie) == 4
      assert movie.header.rom.id == Library.game_id(ctx.rom)
    end

    test "--replay hands the pad to the take from its first frame", %{tmp_dir: dir} do
      path = recorded(dir, <<0x01, 0x01, 0x00, 0x10>>)
      {:ok, movie} = Movie.read(path)

      assert {:replaying, _movie, 0} = console(dir, replay: movie).movie
    end

    test "a movie from another cartridge is turned away before the terminal is taken over",
         %{tmp_dir: dir} do
      path = Path.join(dir, "stranger.tas")
      :ok = Movie.write(Movie.new(stranger(), {:boot, :none}), path)

      assert {:error, message} = Play.run(rom_path(dir), replay: path, library: library_dir(dir))
      assert message =~ "was recorded on SOMETHING_ELSE"
      assert message =~ "and this cartridge is"
    end

    test "a file that is not a movie says so, and does not crash", %{tmp_dir: dir} do
      path = Path.join(dir, "notes.tas")
      File.write!(path, "dear diary")

      assert {:error, message} = Play.run(rom_path(dir), replay: path, library: library_dir(dir))
      assert message =~ "not a movie"
    end
  end

  describe "the in-game menu" do
    test "RECORD MOVIE starts a take anchored on the machine as it stands", %{tmp_dir: dir} do
      ctx = console(dir)
      ctx = menu(ctx, 4)

      assert {:recording, movie} = ctx.movie
      assert {:snapshot, _state, _ram, _apu} = movie.anchor
    end

    test "STOP AND SAVE writes the take into the game's folder", %{tmp_dir: dir} do
      ctx = console(dir)
      ctx = menu(ctx, 4)
      ctx = Enum.reduce(1..5, ctx, fn _n, ctx -> frame(ctx) end)

      # The rows moved: with a take running, row 4 is the one that stops it.
      ctx = menu(ctx, 4)

      assert ctx.movie == nil
      assert [path] = Library.movies(ctx.lib)
      assert {:ok, movie} = Movie.read(path)
      # Six frames: the five run above, and the one the menu's own frame ran.
      assert Movie.frames(movie) == 6
      assert {"● 6 frames → " <> _name, _left} = ctx.note
    end

    test "REPLAY MOVIE plays the most recent take, and says so when there is none",
         %{tmp_dir: dir} do
      ctx = console(dir)

      empty = menu(ctx, 5)
      assert empty.movie == nil
      assert {"no movie recorded for this game yet", _left} = empty.note

      _path = recorded(dir, <<0x00, 0x01, 0x02>>)

      assert {:replaying, movie, _cursor} = menu(ctx, 5).movie
      assert Movie.frames(movie) == 3
    end
  end

  describe "the anchor a replay lands on" do
    test "a boot anchor powers the machine on, whatever the session had reached",
         %{tmp_dir: dir} do
      path = recorded(dir, <<0, 0, 0>>)

      # Half a minute of play, then the take: nothing of it may survive.
      played = Enum.reduce(1..30, console(dir), fn _n, ctx -> frame(ctx) end)
      fresh = console(dir)

      replaying = Play.replay(played, path)

      assert replaying.state == fresh.state
      assert replaying.apu == fresh.apu
      assert replaying.history == []
    end

    test "a boot anchor brings its own battery, not the player's", %{tmp_dir: dir} do
      lib = library(dir, rom_path(dir))
      sav = Library.sav_path(lib)
      File.mkdir_p!(Path.dirname(sav))

      # The take was recorded on a battery of 0x5A…
      File.write!(sav, :binary.copy(<<0x5A>>, 0x2000))
      path = recorded(dir, <<0, 0, 0>>)

      # …and the player has been playing on one of 0xA5 ever since.
      File.write!(sav, :binary.copy(<<0xA5>>, 0x2000))
      ctx = Play.replay(console(dir), path)

      assert Map.get(ctx.ram, 0xA000) == 0x5A
    end

    test "the battery a take writes goes to the sandbox, never over the player's",
         %{tmp_dir: dir} do
      path = recorded(dir, <<0, 0, 0>>)
      ctx = console(dir)

      replaying = Play.replay(ctx, path)

      refute replaying.sav == ctx.sav
      assert replaying.sav == Library.replay_sav(ctx.lib)
    end
  end

  # ── The console under test ──────────────────────────────────────────────────

  defp console(dir, opts \\ []) do
    path = rom_path(dir)
    cartridge = Screen.load(path)

    ctx =
      Play.context(cartridge, library(dir, path), Keyword.merge([frames: 0], opts))

    %{ctx | deadline: System.monotonic_time(:microsecond) - 1_000_000}
  end

  defp library_dir(dir), do: Path.join(dir, "library")

  defp library(dir, rom_path),
    do: Library.open(Screen.load(rom_path), rom_path, library: library_dir(dir))

  defp rom_path(dir) do
    path = Path.join(dir, "spin.gb")
    unless File.exists?(path), do: File.write!(path, rom("ATOMBOY SPIN"))
    path
  end

  # Another cartridge: the same code, a different name in the header.
  defp stranger, do: rom("SOMETHING ELSE")

  # A cartridge that spins in place — JR -2 at the entry point. What runs on
  # it does not matter here: these tests are about the doors, not the frames
  # behind them.
  defp rom(title) do
    header = String.pad_trailing(String.slice(title, 0, 16), 16, <<0>>)

    :binary.copy(<<0>>, 0x100) <>
      <<0x18, 0xFE>> <>
      :binary.copy(<<0>>, 0x134 - 0x102) <>
      header <> :binary.copy(<<0>>, 0x8000 - 0x144)
  end

  # One frame of the real loop: the budget is raised by exactly one, so the
  # loop runs a frame and comes back through its own finishing path.
  defp frame(ctx), do: Play.drive(%{ctx | max_frames: ctx.frame + 1})

  # The menu, opened and walked down to a row, and A pressed on it — the
  # keystrokes a player makes, through the loop's own event path. Every byte
  # is in the mailbox before the frame runs, so the whole visit happens in
  # one reduce and the frame that follows is the first one after the choice.
  defp menu(ctx, row) do
    send(self(), {:input, "m" <> String.duplicate("\e[B", row) <> "x"})
    frame(ctx)
  end

  # A take on disk: the given track, boot-anchored on this cartridge, in the
  # game's own folder — where REPLAY MOVIE goes looking.
  defp recorded(dir, track) do
    lib = library(dir, rom_path(dir))
    sram = File.read(Library.sav_path(lib))
    anchor = with {:ok, data} <- sram, do: {:boot, data}, else: (_ -> {:boot, :none})

    movie = %{Movie.new(Screen.load(rom_path(dir)), anchor) | track: track}
    path = Library.movie_path(lib, Library.movie_name())
    :ok = Movie.write(movie, path)

    path
  end
end
