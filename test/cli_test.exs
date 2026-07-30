defmodule Atomboy.CLITest do
  use ExUnit.Case, async: true

  alias Atomboy.CLI

  @rom "test/fixtures/dmg-acid2.gb"

  test "--listen nu prend le port par défaut" do
    assert {:ok, @rom, opts} = CLI.parse([@rom, "--window", "--listen", "--save", "will"])
    assert opts[:listen] == 7373
    assert opts[:save] == "will"
    assert opts[:window] == true
  end

  test "--listen avec port explicite le garde" do
    assert {:ok, @rom, opts} = CLI.parse([@rom, "--listen", "9999"])
    assert opts[:listen] == 9999
  end

  test "--listen nu en fin d'arguments" do
    assert {:ok, @rom, opts} = CLI.parse([@rom, "--listen"])
    assert opts[:listen] == 7373
  end
end
