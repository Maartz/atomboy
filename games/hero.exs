# The first Potion game: a square hero who walks under your thumb.
#
#     mix run games/hero.exs
#
# writes `games/hero.gb` — a real 32 KB cartridge, to open in Atomboy.app, in
# the terminal (`bin/play games/hero.gb`), or to burn onto a flashcart. Editing
# this file and running the command again is all it takes: the compiler refuses
# at compile time whatever the console cannot do.

defmodule Hero do
  use Potion

  defactor :hero do
    variables x: 80, y: 72

    every_frame do
      if pressed?(:right), do: x = x + 1
      if pressed?(:left), do: x = x - 1
      if pressed?(:up), do: y = y - 1
      if pressed?(:down), do: y = y + 1
      sprite(0, x: x, y: y, tile: 0)
    end
  end
end

path = Path.join(__DIR__, "hero.gb")
File.write!(path, Hero.rom())
IO.puts("#{path} — #{byte_size(Hero.rom())} bytes, ready to play.")
