defmodule Atomboy.CLITest do
  use ExUnit.Case, async: true

  alias Atomboy.CLI

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
end
