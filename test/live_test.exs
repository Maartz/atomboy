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
