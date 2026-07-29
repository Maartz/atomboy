defmodule Atomboy.CLITest do
  use ExUnit.Case, async: true

  alias Atomboy.CLI

  @rom "test/fixtures/dmg-acid2.gb"

  test "--ecoute nu prend le port par défaut" do
    assert {:ok, @rom, opts} = CLI.parse([@rom, "--fenetre", "--ecoute", "--sauvegarde", "will"])
    assert opts[:ecoute] == 7373
    assert opts[:sauvegarde] == "will"
    assert opts[:fenetre] == true
  end

  test "--ecoute avec port explicite le garde" do
    assert {:ok, @rom, opts} = CLI.parse([@rom, "--ecoute", "9999"])
    assert opts[:ecoute] == 9999
  end

  test "--ecoute nu en fin d'arguments" do
    assert {:ok, @rom, opts} = CLI.parse([@rom, "--ecoute"])
    assert opts[:ecoute] == 7373
  end
end
