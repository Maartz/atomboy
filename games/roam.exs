# A room bigger than the screen, and a camera that follows.
#
#     mix run games/roam.exs
#
# writes `games/roam.gb`. Play it with `bin/play games/roam.gb`. The field is
# the whole background map -- 32 by 32 tiles, 256 pixels a side -- and the
# panel is a 160×144 window onto it. Walk with the d-pad: the camera stays put
# while you cross the middle of the screen, then walks after you, one pixel a
# frame, and stops at the field's edge the way the field stops you at its
# walls.
#
# The camera *chases* instead of computing `cx = x - 76`, and that is not just
# taste: that subtraction's -66 and its +190 are the same byte, and no `if`
# can tell them apart. The chase compares `x - cx` -- where the walker stands
# on the screen, always 0 to 160 -- and never meets the ambiguity.
defmodule Roam do
  use Potion

  @top String.duplicate("#", 32)

  # The interior grows a pillar every sixth row and column: something for the
  # eye to measure the scrolling against, and for the shoulder to bump into --
  # a pillar is the wall tile, so it is solid by the same collision.
  @field ([@top] ++
            (for row <- 1..30 do
               "#" <>
                 for col <- 1..30, into: "" do
                   if rem(row, 6) == 0 and rem(col, 6) == 0, do: "#", else: " "
                 end <>
                 "#"
             end) ++
            [@top])
         |> Enum.join("\n")

  room :field, @field, tiles: %{?# => 0}

  defactor :roamer do
    variables x: 124, y: 124, ox: 0, oy: 0, cx: 0, cy: 0, sx: 0, sy: 0, x7: 0, y7: 0, arrived: 0

    every_frame do
      if arrived == 0 do
        arrived = 1
        show(:field)
      end

      ox = x
      oy = y

      if pressed?(:right), do: x = x + 1
      if pressed?(:left), do: x = x - 1
      if pressed?(:up), do: y = y - 1
      if pressed?(:down), do: y = y + 1

      x7 = x + 7
      y7 = y + 7

      if touching?(0, x, y) or touching?(0, x7, y) or touching?(0, x, y7) or
           touching?(0, x7, y7) do
        x = ox
        y = oy
      end

      # The dead zone: the walker owns the middle of the screen, the camera
      # owns the edges. `cx < 96` and `cy < 112` are the room's own limits --
      # 256 minus the panel -- so the view never slides off the map.
      sx = x - cx
      if sx > 84 and cx < 96, do: cx = cx + 1
      if sx < 68 and cx > 0, do: cx = cx - 1
      sy = y - cy
      if sy > 76 and cy < 112, do: cy = cy + 1
      if sy < 60 and cy > 0, do: cy = cy - 1

      scroll(cx, cy)
      sx = x - cx
      sy = y - cy
      sprite(0, x: sx, y: sy, tile: 0)
    end
  end
end

path = Path.join(__DIR__, "roam.gb")
File.write!(path, Roam.rom())
IO.puts("#{path} — #{byte_size(Roam.rom())} bytes, ready to play.")
