# Pong: two paddles, a ball, and two digits keeping count.
#
#     mix run games/pong.exs
#
# writes `games/pong.gb`. Play it with `bin/play games/pong.gb` — up and down
# move the left paddle, the right one follows the ball on its own.
#
# This is a skeleton meant to be edited. Everything below is written in the
# vocabulary the v0 compiler actually has: one byte per cell, one pixel per
# frame, no multiplication and no loop. Where a choice was forced by that, the
# comment says so — those are the places worth attacking first.

defmodule Pong do
  use Potion

  # The screen is 160x144 and a tile is 8x8. Paddles are two stacked sprites,
  # the ball is one, and tile 0 is the kernel's solid square.
  #
  # Vertical range is 8 to 112 for a paddle top: it then occupies 8..127, which
  # leaves the ball's 8 rows of travel visible above and below. Those bounds are
  # written as literals in four places rather than named once, because a cell
  # holding a constant would cost a byte and buy nothing the compiler can use.

  # ── The player, on the left ────────────────────────────────────────────────
  #
  # Declared first, and that is the schedule: actors run in declaration order,
  # every frame, so the ball further down reads the edges this one just wrote
  # rather than last frame's.

  defactor :player do
    variables py: 64, ptop: 56, pmid: 72, pbot: 80

    every_frame do
      if pressed?(:up), do: py = py - 2
      if pressed?(:down), do: py = py + 2

      # Clamped after both, so holding up and down at once cancels out instead
      # of fighting. Two pixels a frame from a floor of 8 never reaches zero, so
      # the subtraction above cannot wrap.
      if py < 8, do: py = 8
      if py > 112, do: py = 112

      # The three edges the ball will test, computed once here rather than three
      # times there. A comparison takes a literal or a cell and nothing else, so
      # `by >= py - 8` has to be spelled as a cell that already holds `py - 8`.
      ptop = py - 8
      pmid = py + 8
      pbot = py + 16

      sprite(0, x: 8, y: py, tile: 0)
      sprite(1, x: 8, y: pmid, tile: 0)
    end
  end

  # ── The rival, on the right ────────────────────────────────────────────────
  #
  # It walks one pixel a frame toward the ball, which is the whole opponent. It
  # is beatable precisely because the ball also moves one pixel a frame and can
  # get a head start on the diagonal — make this `+ 2` and nothing beats it.

  defactor :rival do
    variables ey: 64, etop: 56, emid: 72, ebot: 80

    every_frame do
      if by > ey, do: ey = ey + 1
      if by < ey, do: ey = ey - 1

      if ey < 8, do: ey = 8
      if ey > 112, do: ey = 112

      etop = ey - 8
      emid = ey + 8
      ebot = ey + 16

      sprite(2, x: 144, y: ey, tile: 0)
      sprite(3, x: 144, y: emid, tile: 0)
    end
  end

  # ── The ball ───────────────────────────────────────────────────────────────

  defactor :ball do
    variables bx: 80, by: 68, vx: -1, vy: 1, mine: 0, theirs: 0

    every_frame do
      bx = bx + vx
      by = by + vy

      # The walls set the direction rather than reverse it. `vy = -vy` reads
      # better and sticks: a ball that lands two frames running inside the same
      # wall flips twice and swims into it. Assigning the way out cannot.
      if by <= 8, do: vy = 1
      if by >= 128, do: vy = -1

      # The left paddle. Three nested ifs and not one condition, because the
      # language has no `and` — which costs nothing here, since nested jumps are
      # what an `and` would have compiled to anyway.
      #
      # `bx = 17` after the bounce is not decoration. Without it the ball can
      # spend a second frame under 16 and bounce again, back into the paddle.
      if bx <= 16 do
        if by >= ptop do
          if by <= pbot do
            vx = 1
            bx = 17
          end
        end
      end

      if bx >= 136 do
        if by >= etop do
          if by <= ebot do
            vx = -1
            bx = 135
          end
        end
      end

      # A miss, and the reason these thresholds are 4 and 152 rather than 0 and
      # 160: a byte wraps. At bx = 0 one more step left gives 255, which reads
      # as far right and would trigger the rival's paddle. The point is caught
      # while the number is still small.
      if bx <= 4 do
        theirs = theirs + 1
        bx = 80
        by = 68
        vx = 1
      end

      if bx >= 152 do
        mine = mine + 1
        bx = 80
        by = 68
        vx = -1
      end

      # One digit each, so ten wraps to nothing. A second digit is a second
      # `background` and a tens cell, which needs a compare-and-carry the
      # language can already write — a good first thing to add.
      if mine > 9, do: mine = 0
      if theirs > 9, do: theirs = 0

      sprite(4, x: bx, y: by, tile: 0)

      background(4, 2, digit: mine)
      background(15, 2, digit: theirs)
    end
  end
end

path = Path.join(__DIR__, "pong.gb")
File.write!(path, Pong.rom())
IO.puts("#{path} — #{byte_size(Pong.rom())} bytes, ready to play.")
