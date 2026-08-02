# Two screens and a walker between them.
#
#     mix run games/walk.exs
#
# writes `games/walk.gb`. Play it with `bin/play games/walk.gb` — the d-pad
# moves the square, and walking off the right edge of the meadow puts you in
# the cave, off the left edge of the cave back in the meadow.
#
# This is the smallest game that changes screens, and it is honest about what
# it does not do: the walls are painted, not solid. Walking through them works
# fine, because collision is reading the map back and the language does not
# read the map yet. That is the next piece, and this file is where it will show.

defmodule Walk do
  use Potion

  # The two screens, as module attributes: a room's drawing is ordinary Elixir,
  # so the border is built once and both rooms wear it.
  @top String.duplicate("#", 20)
  @side "#" <> String.duplicate(" ", 18) <> "#"

  @meadow ([@top] ++
             List.duplicate(@side, 7) ++
             ["#" <> String.duplicate(" ", 19)] ++
             List.duplicate(@side, 8) ++
             [@top])
          |> Enum.join("\n")

  @cave ([@top] ++
           List.duplicate(@side, 7) ++
           [String.duplicate(" ", 19) <> "#"] ++
           ["#   ###  ###  ###  #"] ++
           List.duplicate(@side, 7) ++
           [@top])
        |> Enum.join("\n")

  room :meadow, @meadow, tiles: %{?# => 0}
  room :cave, @cave, tiles: %{?# => 0}

  defactor :walker do
    variables x: 80, y: 72, arrived: 0

    every_frame do
      # The first turn paints the first screen. An actor has no startup — the
      # kernel calls it once a frame and that is all — so the first frame
      # recognises itself the way the initial values do.
      if arrived == 0 do
        arrived = 1
        show(:meadow)
      end

      if pressed?(:right), do: x = x + 1
      if pressed?(:left), do: x = x - 1
      if pressed?(:up), do: y = y - 1
      if pressed?(:down), do: y = y + 1

      # The edges are doors. Crossing one shows the other room and carries the
      # walker to its far side — the position survives the move because cells
      # are WRAM and a room only rewrites the background map.
      if x > 152 do
        show(:cave)
        x = 8
      end

      if x < 8 do
        show(:meadow)
        x = 152
      end

      sprite(0, x: x, y: y, tile: 0)
    end
  end
end

path = Path.join(__DIR__, "walk.gb")
File.write!(path, Walk.rom())
IO.puts("#{path} — #{byte_size(Walk.rom())} bytes, ready to play.")
