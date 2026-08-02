# Pong: a title screen, a rally, and a winner at five.
#
#     mix run games/pong.exs
#
# writes `games/pong.gb`. Play it with `bin/play games/pong.gb` — start begins,
# up and down move the left paddle, the right one plays for itself.
#
# Two things are worth reading for rather than around. The ball's vertical speed
# is a fraction of a pixel a frame and where the paddle is struck decides which,
# so a ball can leave at an angle other than 45 degrees — `acc` below. And the
# rival moves through that same mechanism at a speed chosen by playing the game
# two thousand frames at a time and counting, which the comment above it sets
# out — a ceiling alone turned out not to be enough.

defmodule Pong do
  use Potion

  # The drawing, cut into tiles while this file compiles. Reading order, so the
  # ball is the left square and the paddle the right one — and the names are how
  # the game refers to them from here on. Nothing below knows a tile index.
  tiles from: "art/pong.png", names: [:ball, :paddle]

  # The title's tune, on channel 1 — `beep` has channel 2, so a paddle can be
  # struck over a bar without either cutting the other. It loops on its own: the
  # player reads a length of zero and goes back to the start.
  music(:attract, "c4 . e4 . g4 . c5 . . . g4 . e4 . c4 . . . - -", beat: 9)

  # ── The director ───────────────────────────────────────────────────────────
  #
  # The screens, and nothing else. It owns `playing`, which the three actors
  # below read to know whether there is a game on — they are declared after it,
  # and the kernel calls actors in declaration order, so what they read is what
  # this wrote a moment ago rather than last frame's.
  #
  # A screen is painted in `on_enter` and never again. That is the whole reason
  # states are here: `every_frame` would repaint PRESS START sixty times a second
  # to no effect, and the ball would have to draw itself over it.

  defactor :director do
    variables playing: 0

    state :title do
      on_enter do
        playing = 0

        text(7, 5, "POTION")
        text(6, 8, "P O N G")
        text(4, 12, "PRESS START")

        # Whatever the last game left: the two scores, and the five sprites. A
        # sprite is hidden by being put below the 144 lines the panel shows —
        # the OAM has no "off" bit, only a position nobody can see.
        text(4, 2, " ")
        text(15, 2, " ")

        play(:attract)

        sprite(0, x: 0, y: 160, tile: :paddle)
        sprite(1, x: 0, y: 160, tile: :paddle)
        sprite(2, x: 0, y: 160, tile: :paddle)
        sprite(3, x: 0, y: 160, tile: :paddle)
        sprite(4, x: 0, y: 160, tile: :ball)

        mine = 0
        theirs = 0
      end

      every_frame do
        if pressed?(:start) do
          beep(:c6)
          become(:playing)
        end
      end
    end

    state :playing do
      on_enter do
        playing = 1
        silence()

        # The title, wiped a square at a time. A space is the empty tile the
        # init already filled the whole map with, so this costs nothing to say.
        text(7, 5, "      ")
        text(6, 8, "       ")
        text(4, 12, "           ")
      end

      every_frame do
        if mine >= 5, do: become(:over)
        if theirs >= 5, do: become(:over)
      end
    end

    state :over do
      on_enter do
        playing = 0

        # The field goes with the game. Without this the ball freezes wherever
        # the last point left it, which is over the O of GAME OVER as often as
        # not — the actors have stopped writing the mirror, and the DMA keeps
        # publishing whatever was in it.
        sprite(0, x: 0, y: 160, tile: :paddle)
        sprite(1, x: 0, y: 160, tile: :paddle)
        sprite(2, x: 0, y: 160, tile: :paddle)
        sprite(3, x: 0, y: 160, tile: :paddle)
        sprite(4, x: 0, y: 160, tile: :ball)

        text(5, 6, "GAME OVER")
        text(4, 10, "PRESS START")
      end

      every_frame do
        if pressed?(:start), do: become(:title)
      end
    end
  end

  # ── The player, on the left ────────────────────────────────────────────────

  defactor :player do
    variables py: 64, ptop: 56, pmid: 72, pbot: 80

    every_frame do
      if playing == 1 do
        if pressed?(:up), do: py = py - 2
        if pressed?(:down), do: py = py + 2

        # Clamped after both, so holding up and down at once cancels out instead
        # of fighting. Two pixels a frame from a floor of 8 never reaches zero,
        # so the subtraction above cannot wrap.
        if py < 8, do: py = 8
        if py > 112, do: py = 112

        # The edges the ball will test, computed once here rather than three
        # times there. A comparison takes a literal or a cell and nothing else,
        # so `by >= py - 8` has to be spelled as a cell already holding it.
        #
        # `ptop` is also the origin the impact point is measured from: the ball
        # overlaps this paddle for `by` in ptop..pbot, so `by - ptop` runs 0 to
        # 24 and never goes negative — which matters, because a byte has no sign
        # and 0 - 1 would read as 255.
        ptop = py - 8
        pmid = py + 8
        pbot = py + 16

        sprite(0, x: 8, y: py, tile: :paddle)
        sprite(1, x: 8, y: pmid, tile: :paddle)
      end
    end
  end

  # ── The rival, on the right ────────────────────────────────────────────────
  #
  # It walks toward the ball through the same accumulator the ball uses, and
  # slower than the ball can climb. That much is structural: at 1 pixel a frame
  # against a ball that also moved at most 1, it could never fall behind by even
  # a pixel, so no shot could beat it — not difficult, impossible.
  #
  # 80 out of 128 is a measured number and not a derived one, and the first
  # attempt at deriving it was wrong. 96 gives a gap of some thirty pixels across
  # a crossing, which looked like enough against a paddle sixteen tall — but the
  # paddle answers to `by` anywhere from `ey - 8` to `ey + 16`, a window of
  # twenty-four, and every bounce off a wall turns the ball back and hands the
  # gap away. Measured over two thousand frames, a player aiming every shot at
  # the edge of its own paddle scored **once**.
  #
  # The two numbers this one is chosen on, same length of game:
  #
  #     rival 96   perfect player 1-0     paddle left alone  1-5
  #     rival 80   perfect player 4-0     paddle left alone  0-5
  #     rival 64   perfect player 5-0     paddle left alone  2-5
  #
  # 80 is where a passive player is shut out and an aiming one wins comfortably.
  # 64 reads better on paper — it is exactly the middle rung of the ball's speed
  # ladder, so balls slower than the rival would be caught and faster ones not —
  # but at 64 the rival misses on its own often enough to hand over two points.

  defactor :rival do
    variables ey: 64, etop: 56, emid: 72, ebot: 80, eacc: 0

    every_frame do
      if playing == 1 do
        eacc = eacc + 80

        if eacc >= 128 do
          eacc = eacc - 128

          if by > ey, do: ey = ey + 1
          if by < ey, do: ey = ey - 1
        end

        if ey < 8, do: ey = 8
        if ey > 112, do: ey = 112

        etop = ey - 8
        emid = ey + 8
        ebot = ey + 16

        sprite(2, x: 144, y: ey, tile: :paddle)
        sprite(3, x: 144, y: emid, tile: :paddle)
      end
    end
  end

  # ── The ball ───────────────────────────────────────────────────────────────

  defactor :ball do
    variables bx: 80, by: 68, vx: -1, vy: 1, speed: 64, acc: 0, off: 0, mine: 0, theirs: 0

    # The angle a paddle gives, written once and called by both of them.
    #
    # `off` is where the ball struck: 0 at the top of the overlap and 24 at the
    # bottom, so 12 is the middle. Above it the ball leaves upward, below it
    # downward, and the further from the middle the steeper — which is what lets
    # a player aim rather than merely return.
    #
    # No parameters, and none are missing. The caller works `off` out from its
    # own paddle's top and sets `vx` and `bx` before calling, which is what an
    # argument would have compiled to anyway: an actor's cells are the only
    # storage there is.
    #
    # The ladders count *away* from the middle, and each rung is a plain
    # comparison against a literal — there is no `abs`, and `12 - off` would put
    # a literal on the left of a subtraction, which the v0 does not spell.
    routine :bounce do
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

    every_frame do
      if playing == 1 do
        # Horizontally, one pixel a frame, always. Vertically, a fraction.
        #
        # `speed` is how much of a pixel a frame is worth, out of 128: the frame
        # adds it to `acc` and the ball only steps when that carries past a
        # whole one. 128 is a pixel a frame, 64 is one every two, 32 one every
        # four. `acc` peaks at 127 + 128 = 255 and so cannot wrap, which is the
        # reason the whole is 128 and not 256.
        bx = bx + vx

        acc = acc + speed

        if acc >= 128 do
          by = by + vy
          acc = acc - 128
        end

        # The walls set the direction rather than reverse it. `vy = -vy` is the
        # sentence a bounce wants and it sticks: a ball that lands two frames
        # running inside the same wall flips twice and swims into it. The speed
        # is left alone — a wall changes where the ball goes, not how steeply.
        if by <= 8 do
          vy = 1
          beep(:c5)
        end

        if by >= 128 do
          vy = -1
          beep(:c5)
        end

        # ── The left paddle, and the angle it gives ──────────────────────────
        #
        # `bx = 17` after the bounce is not decoration. Without it the ball can
        # spend a second frame under 16 and bounce again, back into the paddle.
        if bx <= 16 and by >= ptop and by <= pbot do
          vx = 1
          bx = 17
          beep(:e5)

          # Where it struck, 0 at the top of the overlap and 24 at the bottom,
          # so 12 is the middle. Above the middle it leaves upward, below it
          # downward, and the further from the middle the steeper — which is
          # what lets a player aim rather than merely return.
          off = by - ptop

          bounce()
        end

        # ── The rival's paddle, the same rule ────────────────────────────────
        #
        # Written out a second time because the language has no way to name a
        # routine and call it. The two blocks differ in `vx` and in which
        # paddle's top the offset is measured from, and that is the next thing
        # worth taking back into the compiler.
        if bx >= 136 and by >= etop and by <= ebot do
          vx = -1
          bx = 135
          beep(:g4)

          off = by - etop

          bounce()
        end

        # A miss, and the reason these thresholds are 4 and 152 rather than 0
        # and 160: a byte wraps. At bx = 0 one more step left gives 255, which
        # reads as far right and would trigger the rival's paddle.
        if bx <= 4 do
          theirs = theirs + 1
          beep(:c3)
          bx = 80
          by = 68
          vx = 1
          vy = 1
          speed = 64
          acc = 0
        end

        if bx >= 152 do
          mine = mine + 1
          beep(:c6)
          bx = 80
          by = 68
          vx = -1
          vy = 1
          speed = 64
          acc = 0
        end

        sprite(4, x: bx, y: by, tile: :ball)

        background(4, 2, digit: mine)
        background(15, 2, digit: theirs)
      end
    end
  end
end

path = Path.join(__DIR__, "pong.gb")
File.write!(path, Pong.rom())
IO.puts("#{path} — #{byte_size(Pong.rom())} bytes, ready to play.")
