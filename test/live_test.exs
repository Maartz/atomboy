defmodule Atomboy.LiveTest do
  @moduledoc """
  The decisions a reload makes, which are the part with branches in it.

  The swap itself is not tested here and cannot easily be: it happens inside
  `Atomboy.Play`, whose terminal machinery wants a pty. It was proven by hand
  instead — the same game played twice for forty frames, once plain and once
  with a reload handing over a cartridge whose sprite sits at column 100 rather
  than 40, and the dumped frames put the sprite where each cartridge said. What
  is covered below is everything that decides *whether* to hand one over.
  """

  use ExUnit.Case, async: false

  alias Mix.Tasks.Atomboy.Live

  @game """
  defmodule LiveFixture do
    use Potion

    defactor :thing do
      variables x: 40

      every_frame do
        sprite(0, x: x, y: 40, tile: 0)
      end
    end
  end

  IO.puts("this line is below the module and must not run")
  """

  setup do
    path = Path.join(System.tmp_dir!(), "live_#{:erlang.unique_integer([:positive])}.exs")
    File.write!(path, @game)
    on_exit(fn -> File.rm(path) end)
    %{path: path}
  end

  # The file ends with a line that would print into a raw alternate screen. The
  # builder stops at the module's closing `end` for that reason, and this is
  # what says it did.
  test "the lines under the module are not run", %{path: path} do
    assert ExUnit.CaptureIO.capture_io(fn -> Live.build!(path) end) == ""
  end

  test "a build gives a cartridge and the cells", %{path: path} do
    {module, rom, cells} = Live.build!(path)

    assert byte_size(rom) == 32_768
    assert Map.keys(cells) == [:x]
    assert function_exported?(module, :rom, 0)
  end

  # The watch, from the cells a build returns to the text the status line
  # shows: names in declaration order (which is address order), values padded
  # to three so the line holds still while they run.
  test "the watch line reads the game's cells by name" do
    cells = %{y: 0xC101, x: 0xC100, score: 0xC102}
    ram = %{0xC100 => 80, 0xC101 => 7, 0xC102 => 255}

    assert Atomboy.Play.watch_line(cells, ram) == "x  80 · y   7 · score 255"
  end

  test "a cell nobody wrote yet reads as the zero the init left" do
    assert Atomboy.Play.watch_line(%{x: 0xC100}, %{}) == "x   0"
  end

  test "the watch reads a booted game truthfully", %{path: path} do
    {module, rom, cells} = Live.build!(path)

    {_pixels, _state, ram} =
      Enum.reduce(
        1..8,
        {<<>>, Atomboy.Screen.boot_state(rom), Atomboy.Screen.boot_ram(rom)},
        fn _, {_p, state, ram} ->
          Atomboy.Screen.frame(state, rom, ram, false)
        end
      )

    assert Atomboy.Play.watch_line(cells, ram) == "x  40"
    assert function_exported?(module, :addresses, 0)
  end

  # The listener's sentence, from the text to the RAM. `poke` is pure -- the
  # machine is never half-written -- which is what makes it testable here
  # without a terminal.
  test "the listener writes a named cell, and the game reads it next frame", %{path: path} do
    {_module, rom, cells} = Live.build!(path)

    {_pixels, state, ram} =
      Enum.reduce(
        1..8,
        {<<>>, Atomboy.Screen.boot_state(rom), Atomboy.Screen.boot_ram(rom)},
        fn _, {_p, state, ram} ->
          Atomboy.Screen.frame(state, rom, ram, false)
        end
      )

    assert {:ok, ram, "x ← 120"} = Atomboy.Play.poke(cells, ram, "x = 120")

    {_pixels, _state, ram} = Atomboy.Screen.frame(state, rom, ram, false)

    # The game's own frame put the poked value into the sprite: the mirror
    # holds x + 8, the hardware's offset. The write reached the machine, not
    # just the map.
    assert Map.get(ram, 0xC001) == 120 + 8
  end

  test "the listener reads a cell back, and honours the language's negatives" do
    cells = %{vx: 0xC100}

    assert {:ok, ram, "vx ← 255"} = Atomboy.Play.poke(cells, %{}, "vx = -1")
    assert {:ok, ^ram, "vx = 255"} = Atomboy.Play.poke(cells, ram, "vx")
  end

  test "the listener refuses whole: bad names and bad bytes write nothing" do
    cells = %{x: 0xC100}

    assert {:error, "no cell named vy"} = Atomboy.Play.poke(cells, %{}, "vy = 3")
    assert {:error, message} = Atomboy.Play.poke(cells, %{}, "x = 300")
    assert message =~ "a cell holds a byte"
    assert {:error, message} = Atomboy.Play.poke(cells, %{}, "x = fast")
    assert message =~ "not a number"

    # A typo must not mint an atom: the name is looked up among the existing.
    assert {:error, "no cell named xyzzy_never_seen"} =
             Atomboy.Play.poke(cells, %{}, "xyzzy_never_seen = 1")
  end

  test "a file that has not moved asks for nothing", %{path: path} do
    {_module, _rom, cells} = Live.build!(path)
    seed(path, cells)

    assert Live.reload(path) == :unchanged
  end

  test "a changed constant comes back as a new cartridge", %{path: path} do
    {_module, before, cells} = Live.build!(path)
    seed(path, cells)

    touch(path, String.replace(@game, "x: 40", "x: 100"))

    assert {:ok, rom} = Live.reload(path)
    refute rom == before
  end

  # The one thing a reload cannot carry. The cells are an allocation, and a new
  # line moves the addresses -- the values already in WRAM would then be read
  # under a map that does not describe them.
  test "a moved cell layout is refused, and the message says which name did it", %{path: path} do
    {_module, _rom, cells} = Live.build!(path)
    seed(path, cells)

    touch(path, String.replace(@game, "variables x: 40", "variables x: 40, y: 8"))

    assert {:error, message} = Live.reload(path)
    assert message =~ "the cells moved"
    assert message =~ "added :y"
    assert message =~ "restart"
  end

  test "a game that does not compile leaves the running one alone", %{path: path} do
    {_module, _rom, cells} = Live.build!(path)
    seed(path, cells)

    # `x = x * 2` stood here until the day it compiled; `/` is refused for
    # good — a byte has no halves.
    touch(path, String.replace(@game, "sprite(0, x: x, y: 40, tile: 0)", "x = x / 2"))

    assert {:error, message} = Live.reload(path)
    assert message =~ "halves"
  end

  defp seed(path, cells) do
    {:ok, stat} = File.stat(path, time: :posix)
    :persistent_term.put({Live, :seen}, {{stat.mtime, stat.size}, cells})
  end

  # A second's worth of stat resolution is a real thing on some filesystems, so
  # the size is part of what the watcher compares and the rewrites here all
  # change it.
  defp touch(path, contents) do
    File.write!(path, contents <> "\n# #{:erlang.unique_integer([:positive])}\n")
  end
end
