defmodule Atomboy.CLITest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Atomboy.CLI
  alias Atomboy.Movie
  alias Atomboy.Screen

  @rom "test/fixtures/dmg-acid2.gb"

  test "a bare --listen takes the default port" do
    assert {:ok, @rom, opts} = CLI.parse([@rom, "--window", "--listen", "--save", "will"])
    assert opts[:listen] == 7373
    assert opts[:save] == "will"
    assert opts[:window] == true
  end

  test "--listen with an explicit port keeps it" do
    assert {:ok, @rom, opts} = CLI.parse([@rom, "--listen", "9999"])
    assert opts[:listen] == 9999
  end

  test "a bare --listen at the end of the arguments" do
    assert {:ok, @rom, opts} = CLI.parse([@rom, "--listen"])
    assert opts[:listen] == 7373
  end

  test "--turbo names a capped speed" do
    for speed <- [2, 4, 8] do
      assert {:ok, @rom, opts} = CLI.parse([@rom, "--turbo", "#{speed}"])
      assert opts[:turbo_speed] == speed
      # The flag is spent: only the speed reaches the game.
      refute Keyword.has_key?(opts, :turbo)
    end
  end

  test "without --turbo the speed stays uncapped — nothing changes for anyone" do
    assert {:ok, @rom, opts} = CLI.parse([@rom])
    refute Keyword.has_key?(opts, :turbo_speed)
  end

  test "a speed nobody offers is refused, not rounded" do
    assert {:error, message} = CLI.parse([@rom, "--turbo", "3"])
    assert message =~ "unknown turbo speed: 3"
    assert message =~ "2, 4, 8"

    assert {:error, _} = CLI.parse([@rom, "--turbo", "0"])
    assert {:error, _} = CLI.parse([@rom, "--turbo", "16"])
  end

  test "--turbo without a number is a parse error, not a silent uncapped" do
    assert {:error, _message} = CLI.parse([@rom, "--turbo"])
  end

  describe "the movie flags" do
    @tag :tmp_dir
    test "--record names the file the take is written to", %{tmp_dir: dir} do
      take = Path.join(dir, "run.tas")

      assert {:ok, @rom, opts} = CLI.parse([@rom, "--record", take])
      assert opts[:record] == take
    end

    @tag :tmp_dir
    test "--replay names a movie that is there", %{tmp_dir: dir} do
      take = Path.join(dir, "run.tas")
      File.write!(take, "not read at parse time")

      assert {:ok, @rom, opts} = CLI.parse([@rom, "--replay", take])
      assert opts[:replay] == take
    end

    test "a movie that is not there is said so, not opened later" do
      assert {:error, message} = CLI.parse([@rom, "--replay", "nowhere/run.tas"])
      assert message =~ "movie not found: nowhere/run.tas"
    end

    test "recording into a folder that does not exist is refused" do
      assert {:error, message} = CLI.parse([@rom, "--record", "nowhere/run.tas"])
      assert message =~ "nowhere to record"
    end

    @tag :tmp_dir
    test "the two flags are two ends of the same session", %{tmp_dir: dir} do
      take = Path.join(dir, "run.tas")
      File.write!(take, "")

      assert {:error, message} = CLI.parse([@rom, "--record", take, "--replay", take])
      assert message =~ "pick one"
    end

    @tag :tmp_dir
    test "neither travels with the cable: it is the one input a track cannot deal again",
         %{tmp_dir: dir} do
      take = Path.join(dir, "run.tas")
      File.write!(take, "")

      for flags <- [["--listen", "9999"], ["--link", "host:7373"]],
          movie <- [["--record", take], ["--replay", take]] do
        assert {:error, message} = CLI.parse([@rom | flags] ++ movie)
        assert message =~ "cannot share a session"
      end
    end
  end

  # The door the app knocks on: the shell has no `mix`, so "Export Movie…"
  # launches a second engine with these very flags. What is checked here is
  # what that engine agrees to do, and the number it exits with — the
  # replay and the encode themselves belong to `export_test.exs`.
  describe "the export door" do
    @tag :tmp_dir
    test "--replay and --export together name a movie and a file", %{tmp_dir: dir} do
      take = written(dir)
      out = Path.join(dir, "run.mp4")

      assert {:ok, @rom, opts} = CLI.parse([@rom, "--replay", take, "--export", out])
      assert opts[:export] == out
      assert opts[:replay] == take
    end

    @tag :tmp_dir
    test "--scale rides along with the export", %{tmp_dir: dir} do
      take = written(dir)

      assert {:ok, @rom, opts} =
               CLI.parse([
                 @rom,
                 "--replay",
                 take,
                 "--export",
                 Path.join(dir, "run.gif"),
                 "--scale",
                 "3"
               ])

      assert opts[:scale] == 3
    end

    @tag :tmp_dir
    test "an export with no take to export is refused by name", %{tmp_dir: dir} do
      assert {:error, message} = CLI.parse([@rom, "--export", Path.join(dir, "run.mp4")])
      assert message =~ "--export renders a movie"
      assert message =~ "--replay take.tas"
    end

    @tag :tmp_dir
    test "an export opens no window and speaks no protocol", %{tmp_dir: dir} do
      take = written(dir)
      out = Path.join(dir, "run.mp4")

      for flag <- ["--window", "--server"] do
        assert {:error, message} =
                 CLI.parse([@rom, "--replay", take, "--export", out, flag])

        assert message =~ "writes a file and exits"
      end
    end

    @tag :tmp_dir
    test "--scale without an export has nothing to size", %{tmp_dir: dir} do
      assert {:error, message} = CLI.parse([@rom, "--replay", written(dir), "--scale", "3"])
      assert message =~ "--scale belongs to --export"
    end

    @tag :tmp_dir
    test "a scale of no pixels at all is refused", %{tmp_dir: dir} do
      take = written(dir)
      out = Path.join(dir, "run.mp4")

      assert {:error, message} =
               CLI.parse([@rom, "--replay", take, "--export", out, "--scale", "0"])

      assert message =~ "1 or more"
    end

    @tag :tmp_dir
    test "a refused export exits 2 and says so on stderr", %{tmp_dir: dir} do
      out = Path.join(dir, "run.mp4")

      assert capture_io(:stderr, fn ->
               assert CLI.main([@rom, "--export", out]) == 2
             end) =~ "--export renders a movie"

      refute File.exists?(out)
    end

    @tag :tmp_dir
    test "a format nobody can write exits 1, with nothing replayed", %{tmp_dir: dir} do
      take = written(dir)

      assert capture_io(:stderr, fn ->
               assert CLI.main([@rom, "--replay", take, "--export", Path.join(dir, "run.webm")]) ==
                        1
             end) =~ "neither .mp4 nor .gif"
    end

    if System.find_executable("ffmpeg") do
      @tag :ffmpeg
      @tag :tmp_dir
      test "a take goes in, a file comes out, and the exit code is zero", %{tmp_dir: dir} do
        take = written(dir)
        out = Path.join(dir, "run.mp4")

        stderr =
          capture_io(:stderr, fn ->
            assert CLI.main([@rom, "--replay", take, "--export", out, "--scale", "1"]) == 0
          end)

        assert File.regular?(out)
        # The progress lines and the closing note, both on the stream the
        # app's sheet reads.
        assert stderr =~ "replaying"
        assert stderr =~ "#{out} — 8 frames"
      end
    end
  end

  # ── The bench ───────────────────────────────────────────────────────────────

  # A short take on the fixture cartridge, on disk where a flag can name it.
  defp written(dir) do
    path = Path.join(dir, "run.tas")

    movie =
      Enum.reduce(
        [0x00, 0x00, 0x01, 0x01, 0x10, 0x10, 0x00, 0x00],
        Movie.new(Screen.load(@rom), {:boot, :none}),
        &Movie.append_frame(&2, &1)
      )

    :ok = Movie.write(movie, path)
    path
  end
end
