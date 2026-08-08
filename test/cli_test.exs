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
end
