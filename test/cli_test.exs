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
end
