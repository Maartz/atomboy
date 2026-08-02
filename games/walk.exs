# Two screens and a walker between them.
#
#     mix run games/walk.exs
#
# writes `games/walk.gb`. Play it with `bin/play games/walk.gb` — the d-pad
# moves the square, and walking off the right edge of the meadow puts you in
# the cave, off the left edge of the cave back in the meadow.
#
# This is the smallest game that changes screens -- and now the walls are
# solid. A step is taken and then unmade if any corner of the square stands on
# a wall tile: the old position is cheaper to keep than the collision is to
# predict, which is how most games this size did it.

defmodule Walk do
  use Potion

  # The two screens, as module attributes: a room's drawing is ordinary Elixir,
  # so the border is built once and both rooms wear it.
  @top String.duplicate("#", 20)
  @side "#" <> String.duplicate(" ", 18) <> "#"

  # The doors are two tiles tall, and that is walkability rather than looks: the
  # walker is eight pixels and a tile is eight pixels, so a one-tile door would
  # want pixel-perfect alignment to pass -- a wall that pretends to be a door.
  @meadow ([@top] ++
             List.duplicate(@side, 7) ++
             List.duplicate("#" <> String.duplicate(" ", 19), 2) ++
             List.duplicate(@side, 7) ++
             [@top])
          |> Enum.join("\n")

  @cave ([@top] ++
           List.duplicate(@side, 7) ++
           List.duplicate(String.duplicate(" ", 19) <> "#", 2) ++
           ["#   ###  ###  ###  #"] ++
           List.duplicate(@side, 6) ++
           [@top])
        |> Enum.join("\n")

  room :meadow, @meadow, tiles: %{?# => 0}
  room :cave, @cave, tiles: %{?# => 0}

  defactor :walker do
    variables x: 80, y: 72, ox: 80, oy: 72, x7: 0, y7: 0, arrived: 0

    every_frame do
      # The first turn paints the first screen. An actor has no startup — the
      # kernel calls it once a frame and that is all — so the first frame
      # recognises itself the way the initial values do.
      if arrived == 0 do
        arrived = 1
        show(:meadow)
      end

      # The position before the step, kept so the step can be unmade. Cheaper
      # than predicting: one wrong frame of position that nobody ever sees,
      # against four look-aheads per direction.
      ox = x
      oy = y

      if pressed?(:right), do: x = x + 1
      if pressed?(:left), do: x = x - 1
      if pressed?(:up), do: y = y - 1
      if pressed?(:down), do: y = y + 1

      # The doors come *before* the walls, and the order is load-bearing. One
      # step past the threshold the far corner is off the screen, and
      # `touching?` answers about whatever cell its arithmetic lands on -- a
      # wall, as it happens. Cross first, and the collision below only ever
      # sees on-screen pixels.
      #
      # And a door is a *place*, not an edge. Without the rows in the test,
      # pushing into the left wall anywhere reached x = 7, fired the door, and
      # re-showed the room -- every frame. The position reverted each time, so
      # nothing looked wrong in the cells; but every `show` switches the panel
      # off for a third of a frame, and the top of the picture is scanned while
      # it is dark. The screen flickered blank at the top, the walker vanished
      # into it, and the map was innocent all along.
      if x > 152 and y >= 64 and y <= 72 do
        show(:cave)
        x = 8
      end

      if x < 8 and y >= 64 and y <= 72 do
        show(:meadow)
        x = 152
      end

      # The square is eight pixels wide, so a wall is hit by whichever corner
      # reaches it first. `touching?` asks about one pixel; the corners are
      # four questions joined with `or`, which costs what the nested ifs it
      # replaces would have.
      x7 = x + 7
      y7 = y + 7

      if touching?(0, x, y) or touching?(0, x7, y) or touching?(0, x, y7) or
           touching?(0, x7, y7) do
        x = ox
        y = oy
      end

      sprite(0, x: x, y: y, tile: 0)
    end
  end
end

path = Path.join(__DIR__, "walk.gb")
File.write!(path, Walk.rom())
IO.puts("#{path} — #{byte_size(Walk.rom())} bytes, ready to play.")
