# The Tower: a platformer, upward.
#
#     mix run games/tower.exs
#
# writes `games/tower.gb`. Play it with `bin/play games/tower.gb` — or hot,
# with the watch on, via `ELIXIR_ERL_OPTIONS="-noinput" mix atomboy.live
# games/tower.exs`. Start begins; arrows walk, A jumps. Three storeys of
# platforms, each the size of the whole map; jump through the hole in a
# ceiling and the next storey is shown. The flag at the top is the game.
#
# This is the first Potion game with gravity, and the first with a drawn,
# animated character: two walking poses swapped on a frame counter, a jump
# pose in the air, and `flip:` turning all three to face where he goes.
defmodule Tower do
  use Potion

  tiles from: "art/tower.png", names: [:stand, :step, :jump, :brick, :flag, :plank]

  # ── The three storeys ───────────────────────────────────────────────────────
  #
  # Drawn by rule rather than by hand: a storey is 32 rows of 32, walls all
  # round, platforms on every third row zig-zagging up, and a hole in the
  # ceiling where the next storey begins. The rule is ordinary Elixir running
  # while the module compiles; the strings it makes are what `room` gets.

  wall = String.duplicate("#", 32)

  # The rungs are planks, not bricks, and the difference is the game: a plank
  # is landed on from above and passed through from below, so a jump straight
  # up pops the climber onto the rung over his head instead of knocking it.
  brick_row = fn spans ->
    for col <- 0..31, into: "" do
      cond do
        col in [0, 31] -> "#"
        Enum.any?(spans, fn {a, b} -> col in a..b end) -> "="
        true -> " "
      end
    end
  end

  gap_top = fn {a, b} ->
    for col <- 0..31, into: "", do: if(col in a..b, do: " ", else: "#")
  end

  flag_row = fn {a, b} ->
    for col <- 0..31, into: "" do
      cond do
        col in [0, 31] -> "#"
        col in a..b -> "F"
        true -> " "
      end
    end
  end

  storey = fn top, platforms, special ->
    for row <- 0..31 do
      cond do
        row == 0 -> top
        row == 31 -> wall
        Map.has_key?(special, row) -> Map.fetch!(special, row)
        Map.has_key?(platforms, row) -> brick_row.(Map.fetch!(platforms, row))
        true -> brick_row.([])
      end
    end
    |> Enum.join("\n")
  end

  # Up the right side first, exit top-right. The ladder rungs are three rows
  # apart -- 24 pixels, inside the jump's 30 -- and each rung touches the next
  # one's columns, so no leap asks for more air than the game gives.
  @one storey.(
         gap_top.({26, 29}),
         %{
           4 => [{24, 30}],
           7 => [{19, 23}],
           10 => [{14, 18}],
           13 => [{9, 13}],
           16 => [{4, 8}],
           19 => [{9, 13}],
           22 => [{14, 18}],
           25 => [{19, 23}],
           28 => [{24, 28}]
         },
         %{}
       )

  # Arrive bottom-right, climb left, exit top-left.
  @two storey.(
         gap_top.({2, 5}),
         %{
           4 => [{1, 7}],
           7 => [{8, 12}],
           10 => [{13, 17}],
           13 => [{18, 22}],
           16 => [{23, 27}],
           19 => [{18, 22}],
           22 => [{13, 17}],
           25 => [{8, 12}],
           28 => [{3, 7}]
         },
         %{}
       )

  # The summit: a closed ceiling, and the flag on its own platform.
  three_platforms = %{
    7 => [{12, 19}],
    10 => [{6, 10}],
    13 => [{11, 15}],
    16 => [{16, 20}],
    19 => [{21, 25}],
    22 => [{16, 20}],
    25 => [{11, 15}],
    28 => [{6, 10}]
  }

  @three storey.(wall, three_platforms, %{6 => flag_row.({15, 16})})

  # An empty sky, for the title to stand on: `show` is also how a screen is
  # wiped.
  @sky (for row <- 0..31 do
          if row in [0, 31], do: wall, else: brick_row.([])
        end)
       |> Enum.join("\n")

  room :one, @one, tiles: %{?# => :brick, ?= => :plank, ?F => :flag}
  room :two, @two, tiles: %{?# => :brick, ?= => :plank, ?F => :flag}
  room :three, @three, tiles: %{?# => :brick, ?= => :plank, ?F => :flag}
  room :sky, @sky, tiles: %{?# => :brick}

  # ── The music ───────────────────────────────────────────────────────────────

  # A minor, walking down a4-g4-f4-e4 under an arpeggio: the anthem plays on
  # the title and keeps climbing with you.
  music :anthem,
        [
          lead:
            "a4 . c5 e5 a4 . c5 e5 | g4 . b4 d5 g4 . b4 d5 | f4 . a4 c5 f4 . a4 c5 | e4 g4 b4 g4 e5 . b4 .",
          harmony:
            "a3 c4 e4 c4 a3 c4 e4 c4 | g3 b3 d4 b3 g3 b3 d4 b3 | f3 a3 c4 a3 f3 a3 c4 a3 | e3 g3 b3 g3 e3 g3 b3 g3",
          bass: "a2 . . . . . . . | g2 . . . . . . . | f2 . . . . . . . | e2 . . e2 . . e2 ."
        ],
        beat: 10,
        duty: :quarter,
        gap: 2,
        vibrato: :gentle

  music :fanfare,
        [
          lead: "c5 . e5 . g5 . c6 . . . g5 c6 . . . .",
          harmony: "e4 . g4 . c5 . e5 . . . c5 e5 . . . .",
          bass: "c2 . . . c2 . . . c2 . . . c2 . . ."
        ],
        beat: 8,
        gap: 1

  # ── The climber ─────────────────────────────────────────────────────────────

  defactor :climber do
    variables x: 16,
              y: 240,
              ox: 0,
              oy: 0,
              vy: 0,
              tick: 0,
              grounded: 0,
              facing: 0,
              moving: 0,
              anim: 0,
              storey: 1,
              cx: 0,
              cy: 112,
              sx: 0,
              sy: 0,
              x7: 0,
              y7: 0,
              y8: 0,
              frow: 0,
              nrow: 0,
              primed: 0

    state :title do
      on_enter do
        show(:sky)
        scroll(0, 0)
        cx = 0
        cy = 0
        primed = 0
        text(7, 4, "TOWER")
        text(4, 10, "PRESS START")
        play(:anthem)
      end

      every_frame do
        sprite(0, x: 80, y: 200, tile: :stand)

        # `pressed?` reads a level, not an edge: coming back from the summit
        # with Start still held would sail through this screen. The title
        # listens only after it has seen the button up once.
        if pressed?(:start) do
          if primed == 1, do: become(:climb)
        else
          primed = 1
        end
      end
    end

    state :climb do
      on_enter do
        x = 16
        y = 240
        vy = 0
        grounded = 0
        facing = 0
        storey = 1
        cx = 0
        cy = 112
        show(:one)
      end

      every_frame do
        # ── Walking. The step is taken and unmade, walk.exs's bargain. ──
        moving = 0
        ox = x

        if pressed?(:right) do
          x = x + 1
          facing = 0
          moving = 1
        end

        if pressed?(:left) do
          x = x - 1
          facing = 1
          moving = 1
        end

        x7 = x + 7
        y7 = y + 7

        if touching?(:brick, x, y) or touching?(:brick, x7, y) or touching?(:brick, x, y7) or
             touching?(:brick, x7, y7) do
          x = ox
          x7 = x + 7
        end

        # ── The jump: only off the ground, and the ground is last frame's. ──
        if grounded == 1 and pressed?(:a) do
          vy = -5
          grounded = 0
          beep(:e5)
        end

        # ── Gravity, every other frame: -5 rises thirty pixels in ten
        # frames, and the fall is capped under the platforms' eight. ──
        tick = tick + 1

        if tick == 2 do
          tick = 0

          if negative?(vy) do
            vy = vy + 1
          else
            if vy < 4, do: vy = vy + 1
          end
        end

        # ── The vertical move, whole. Bricks are solid both ways; planks
        # only exist for feet crossing downward into their row -- which is
        # also why rising needs no test at all: going up, the feet's row
        # never grows. ──
        oy = y
        frow = y + 7
        frow = div(frow, 8)
        y = y + vy
        y7 = y + 7
        nrow = div(y7, 8)

        if touching?(:brick, x, y) or touching?(:brick, x7, y) or touching?(:brick, x, y7) or
             touching?(:brick, x7, y7) do
          y = oy
          y7 = y + 7

          # There is no `not`: rising or falling is an `else`, and only the
          # falling arm knocks -- a head bump is the same sentence, silent.
          if negative?(vy) do
            vy = 0
          else
            if grounded == 0, do: noise(:tick)
            vy = 0
          end
        else
          if nrow > frow and (touching?(:plank, x, y7) or touching?(:plank, x7, y7)) do
            # Landed on a plank: the feet snap to its top edge.
            y = nrow * 8
            y = y - 8
            y7 = y + 7
            if grounded == 0, do: noise(:tick)
            vy = 0
          end
        end

        # ── Standing on something? One pixel below the feet answers. ──
        y8 = y7 + 1
        grounded = 0

        if touching?(:brick, x, y8) or touching?(:brick, x7, y8) or touching?(:plank, x, y8) or
             touching?(:plank, x7, y8),
           do: grounded = 1

        # ── The ceilings' holes. A door is a place, not an edge: the row
        # *and* the columns, or the top of every jump would change storeys. ──
        if storey == 1 and y < 6 and x > 204 and x < 236 do
          storey = 2
          show(:two)
          y = 232
          cy = 112
        end

        if storey == 2 and y < 6 and x > 12 and x < 44 do
          storey = 3
          show(:three)
          y = 232
          cy = 112
        end

        # ── The flag. The top corners are enough: it stands at head height. ──
        if touching?(:flag, x, y) or touching?(:flag, x7, y), do: become(:won)

        # ── The camera, chasing on both axes: roam.exs's dead zone. ──
        sx = x - cx
        if sx > 84 and cx < 96, do: cx = cx + 1
        if sx < 68 and cx > 0, do: cx = cx - 1
        sy = y - cy
        if sy > 76 and cy < 112, do: cy = cy + 1
        if sy < 60 and cy > 0, do: cy = cy - 1

        scroll(cx, cy)
        sx = x - cx
        sy = y - cy

        # ── The climber himself: jump pose in the air, two walking poses
        # swapped every eight frames on the ground, all of them mirrored to
        # face where he goes. ──
        anim = anim + 1
        if anim == 16, do: anim = 0

        if grounded == 0 do
          if facing == 0 do
            sprite(0, x: sx, y: sy, tile: :jump)
          else
            sprite(0, x: sx, y: sy, tile: :jump, flip: :x)
          end
        else
          if moving == 0 or anim < 8 do
            if facing == 0 do
              sprite(0, x: sx, y: sy, tile: :stand)
            else
              sprite(0, x: sx, y: sy, tile: :stand, flip: :x)
            end
          else
            if facing == 0 do
              sprite(0, x: sx, y: sy, tile: :step)
            else
              sprite(0, x: sx, y: sy, tile: :step, flip: :x)
            end
          end
        end
      end
    end

    state :won do
      on_enter do
        silence()
        play(:fanfare)
        text(6, 2, "THE SUMMIT")
      end

      every_frame do
        if pressed?(:start), do: become(:title)
      end
    end
  end
end

path = Path.join(__DIR__, "tower.gb")
File.write!(path, Tower.rom())
IO.puts("#{path} — #{byte_size(Tower.rom())} bytes, ready to climb.")
