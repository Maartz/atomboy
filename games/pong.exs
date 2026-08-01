# Pong: two paddles, a ball that leaves them at an angle, and two digits.
#
#     mix run games/pong.exs
#
# writes `games/pong.gb`. Play it with `bin/play games/pong.gb` — up and down
# move the left paddle, the right one follows the ball on its own.
#
# The ball's vertical speed is a fraction, and where it is struck decides which:
# near the middle of a paddle it leaves flat, near an edge it leaves steep. That
# needs no more than eight-bit addition — see `acc` below.

defmodule Pong do
  use Potion

  # The screen is 160x144 and a tile is 8x8. Paddles are two stacked sprites,
  # the ball is one, and tile 0 is the kernel's solid square.
  #
  # Vertical range is 8 to 112 for a paddle top: it then occupies 8..127, which
  # leaves the ball's 8 rows of travel visible above and below.

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

      # The edges the ball will test, computed once here rather than three times
      # there. A comparison takes a literal or a cell and nothing else, so
      # `by >= py - 8` has to be spelled as a cell already holding `py - 8`.
      #
      # `ptop` is also the origin the impact point is measured from: the ball
      # overlaps this paddle for `by` in ptop..pbot, so `by - ptop` runs 0 to 24
      # and never goes negative — which matters, because a byte has no sign and
      # 0 - 1 would read as 255.
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
  # is beatable because a ball leaving on a steep angle now outruns it
  # vertically — before the angles existed, one pixel a frame tracked one pixel
  # a frame and only the reset ever gave it the slip.

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
    variables bx: 80, by: 68, vx: -1, vy: 1, speed: 64, acc: 0, off: 0, mine: 0, theirs: 0

    every_frame do
      # Horizontally, one pixel a frame, always. Vertically, a fraction.
      #
      # `speed` is how much of a pixel a frame is worth, out of 128: the frame
      # adds it to `acc` and the ball only steps when that carries past a whole
      # one. 128 is a pixel a frame, 64 is one every two, 32 one every four.
      # `acc` peaks at 127 + 128 = 255 and so cannot wrap, which is the reason
      # the whole is 128 and not 256.
      #
      # This is the sub-pixel speed the ball needs to travel at an angle other
      # than 45 degrees, and it costs one cell and one comparison.
      bx = bx + vx

      acc = acc + speed

      if acc >= 128 do
        by = by + vy
        acc = acc - 128
      end

      # The walls set the direction rather than reverse it. `vy = -vy` is the
      # sentence a bounce wants and it sticks: a ball that lands two frames
      # running inside the same wall flips twice and swims into it. The speed is
      # left alone — a wall changes where the ball goes, not how steeply.
      if by <= 8, do: vy = 1
      if by >= 128, do: vy = -1

      # ── The left paddle, and the angle it gives ────────────────────────────
      #
      # Three nested ifs and not one condition, because the language has no
      # `and` — which costs nothing here, since nested jumps are what an `and`
      # would have compiled to anyway.
      #
      # `bx = 17` after the bounce is not decoration. Without it the ball can
      # spend a second frame under 16 and bounce again, back into the paddle.
      if bx <= 16 do
        if by >= ptop do
          if by <= pbot do
            vx = 1
            bx = 17

            # Where it struck, 0 at the top of the overlap and 24 at the bottom,
            # so 12 is the middle. Above the middle it leaves upward, below it
            # downward, and the further from the middle the steeper — which is
            # what lets a player aim rather than merely return.
            off = by - ptop

            # Two separate ifs rather than an if/else: the two branches want a
            # block each, and this shape needs nothing from the language beyond
            # what the walls above already use.
            #
            # The ladders count *away* from the middle, and each rung is written
            # as a plain comparison against a literal — there is no `abs`, and
            # `12 - off` would put a literal on the left of a subtraction, which
            # the v0 does not spell.
            if off < 12 do
              vy = -1
              speed = 32
              if off < 9, do: speed = 64
              if off < 6, do: speed = 96
              if off < 3, do: speed = 128
            end

            if off >= 12 do
              vy = 1
              speed = 32
              if off > 14, do: speed = 64
              if off > 17, do: speed = 96
              if off > 20, do: speed = 128
            end
          end
        end
      end

      # ── The rival's paddle, the same rule ──────────────────────────────────
      #
      # Written out a second time because the language has no way to name a
      # routine and call it twice. That is the next thing worth taking back into
      # the compiler: this block and the one above differ only in `vx` and in
      # which paddle's `top` the offset is measured from.
      if bx >= 136 do
        if by >= etop do
          if by <= ebot do
            vx = -1
            bx = 135

            off = by - etop

            if off < 12 do
              vy = -1
              speed = 32
              if off < 9, do: speed = 64
              if off < 6, do: speed = 96
              if off < 3, do: speed = 128
            end

            if off >= 12 do
              vy = 1
              speed = 32
              if off > 14, do: speed = 64
              if off > 17, do: speed = 96
              if off > 20, do: speed = 128
            end
          end
        end
      end

      # A miss, and the reason these thresholds are 4 and 152 rather than 0 and
      # 160: a byte wraps. At bx = 0 one more step left gives 255, which reads
      # as far right and would trigger the rival's paddle.
      #
      # The serve goes back to a middling angle. Serving at the angle the point
      # ended on would be a way of playing too, and it is one line.
      if bx <= 4 do
        theirs = theirs + 1
        bx = 80
        by = 68
        vx = 1
        vy = 1
        speed = 64
        acc = 0
      end

      if bx >= 152 do
        mine = mine + 1
        bx = 80
        by = 68
        vx = -1
        vy = 1
        speed = 64
        acc = 0
      end

      # One digit each, so ten wraps to nothing. A second digit is a second
      # `background` and a tens cell, which needs a compare and a carry the
      # language can already write.
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
