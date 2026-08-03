# The Tower: a platformer, upward.
#
#     mix run games/tower.exs
#
# writes `games/tower.gb`. Play it with `bin/play games/tower.gb` — or hot,
# with the watch on, via `ELIXIR_ERL_OPTIONS="-noinput" mix atomboy.live
# games/tower.exs`. Start begins; arrows walk, A jumps — tap for a hop, hold
# for the full leap, and a held button is one jump, not one per landing.
# Three storeys of planks, each the size of the whole map; jump through the
# hole in a ceiling and the next storey is shown. The flag at the top is the
# game.
#
# The hero is 16 by 16 — four OAM entries a frame, mirrored by swapping the
# columns and flipping each — with two walking poses, a jump pose, and a
# march on the title screen. The walls are brick courses, the rooms are
# dressed to the last cell: the late era never left a void, and neither does
# this.
defmodule Tower do
  use Potion

  tiles from: "art/tower.png",
        names: [
          :stand_tl,
          :stand_tr,
          :stand_bl,
          :stand_br,
          :step_tl,
          :step_tr,
          :step_bl,
          :step_br,
          :jump_tl,
          :jump_tr,
          :jump_bl,
          :jump_br,
          :brick,
          :plank,
          :flag_top,
          :flag_base,
          :backwall,
          :window
        ]

  # ── The three storeys ───────────────────────────────────────────────────────
  #
  # Drawn by rule rather than by hand: 32 rows of 32, brick walls all round, a
  # faint masonry backwall on every interior cell, slit windows down the
  # sides, planks on every third row zig-zagging up, and a hole in the
  # ceiling where the next storey begins.

  wall = String.duplicate("#", 32)

  # The rungs are planks, not bricks, and the difference is the game: a plank
  # is landed on from above and passed through from below, so a jump straight
  # up pops the climber onto the rung over his head instead of knocking it.
  interior_row = fn spans, windows ->
    for col <- 0..31, into: "" do
      cond do
        col in [0, 31] -> "#"
        Enum.any?(spans, fn {a, b} -> col in a..b end) -> "="
        col in windows -> "o"
        true -> ":"
      end
    end
  end

  gap_top = fn {a, b} ->
    for col <- 0..31, into: "", do: if(col in a..b, do: ":", else: "#")
  end

  flag_rows = fn col ->
    top =
      for c <- 0..31,
          into: "",
          do: if(c == col, do: "F", else: if(c in [0, 31], do: "#", else: ":"))

    base =
      for c <- 0..31,
          into: "",
          do: if(c == col, do: "B", else: if(c in [0, 31], do: "#", else: ":"))

    {top, base}
  end

  # Windows march down both sides every sixth row, offset per storey so no
  # two storeys look stamped from the same plate.
  storey = fn top, platforms, special, window_rows ->
    for row <- 0..31 do
      windows = if row in window_rows, do: [4, 27], else: []

      cond do
        row == 0 -> top
        row == 31 -> wall
        Map.has_key?(special, row) -> Map.fetch!(special, row)
        Map.has_key?(platforms, row) -> interior_row.(Map.fetch!(platforms, row), windows)
        true -> interior_row.([], windows)
      end
    end
    |> Enum.join("\n")
  end

  # Up the right side first, exit top-right. The rungs are three rows apart
  # -- 24 pixels, inside the jump's 25 -- and each touches the next one's
  # columns, so no leap asks for more air than the game gives.
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
         %{},
         [2, 8, 14, 20, 26]
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
         %{},
         [3, 9, 15, 21, 27]
       )

  # The summit: a closed ceiling, and the flag on its own platform.
  {flag_top_row, flag_base_row} = flag_rows.(15)

  @three storey.(
           wall,
           %{
             7 => [{12, 19}],
             10 => [{6, 10}],
             13 => [{11, 15}],
             16 => [{16, 20}],
             19 => [{21, 25}],
             22 => [{16, 20}],
             25 => [{11, 15}],
             28 => [{6, 10}]
           },
           %{5 => flag_top_row, 6 => flag_base_row},
           [2, 11, 17, 23]
         )

  # The facade, for the title to stand on: brick frame, masonry night,
  # windows lit down the middle heights.
  @sky (for row <- 0..31 do
          cond do
            row in [0, 31] -> wall
            row in [3, 8, 13] -> interior_row.([], [6, 12, 19, 25])
            true -> interior_row.([], [])
          end
        end)
       |> Enum.join("\n")

  @tiles %{
    ?# => :brick,
    ?= => :plank,
    ?F => :flag_top,
    ?B => :flag_base,
    ?: => :backwall,
    ?o => :window
  }

  room :one, @one, tiles: @tiles
  room :two, @two, tiles: @tiles
  room :three, @three, tiles: @tiles
  room :sky, @sky, tiles: @tiles

  # ── The music ───────────────────────────────────────────────────────────────

  # The climb, in A minor: a rising phrase asked three times, a step higher
  # each time, and answered on the way down into the cadence -- the bass
  # walks its fifths under it and the harmony arpeggiates the chord of the
  # bar. Plucked, breathing (gap 3), with the gentle wobble on held notes.
  music :anthem,
        [
          lead:
            "e5 . c5 . a4 . . . b4 c5 b4 . g4 . . . | a4 . c5 . e5 . . . d5 e5 d5 . b4 . . . | c5 . e5 . g5 . . . f5 g5 f5 . d5 . . . | e5 . d5 c5 b4 . d5 . c5 . a4 . . . . .",
          harmony:
            "a3 e4 c4 e4 a3 e4 c4 e4 a3 e4 c4 e4 g3 d4 b3 d4 | f3 c4 a3 c4 f3 c4 a3 c4 f3 c4 a3 c4 e3 c4 g3 c4 | c4 g4 e4 g4 c4 g4 e4 g4 g3 d4 b3 d4 g3 d4 b3 d4 | a3 e4 c4 e4 e3 b3 gs3 b3 a3 e4 c4 e4 a3 c4 e4 a4",
          bass:
            "a2 . . a2 . . a2 . a2 . . a2 . . g2 . | f2 . . f2 . . f2 . f2 . . f2 . . e2 . | c2 . . c2 . . c2 . g2 . . g2 . . g2 . | a2 . . a2 e2 . . e2 a1 . . . . . . ."
        ],
        beat: 9,
        duty: :eighth,
        gap: 3,
        vibrato: :gentle,
        envelope: :pluck

  # The summit fanfare: the triad climbed whole, a breath, and the tonic
  # planted twice with its fourth-and-fifth underneath.
  music :fanfare,
        [
          lead: "c5 e5 g5 c6 . . a5 b5 c6 . . g5 c6 . . .",
          harmony: "e4 g4 c5 e5 . . f5 g5 e5 . . e5 e5 . . .",
          bass: "c2 . c2 . c2 . f1 g1 c2 . . c2 c2 . . ."
        ],
        beat: 8,
        gap: 2

  # ── The climber ─────────────────────────────────────────────────────────────

  defactor :climber do
    variables x: 16,
              y: 232,
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
              sx8: 0,
              sy8: 0,
              x15: 0,
              y15: 0,
              y16: 0,
              ymid: 0,
              frow: 0,
              nrow: 0,
              primed: 0,
              armed: 1

    state :title do
      on_enter do
        show(:sky)
        scroll(0, 0)
        cx = 0
        cy = 0
        primed = 0
        text(7, 5, "TOWER")
        text(4, 15, "PRESS START")
        play(:anthem)
      end

      every_frame do
        # The hero marches in place under the title: the same two poses the
        # climb uses, at a strolling eight frames each.
        anim = anim + 1
        if anim == 16, do: anim = 0

        if anim < 8 do
          sprite(0, x: 72, y: 88, tile: :stand_tl)
          sprite(1, x: 80, y: 88, tile: :stand_tr)
          sprite(2, x: 72, y: 96, tile: :stand_bl)
          sprite(3, x: 80, y: 96, tile: :stand_br)
        else
          sprite(0, x: 72, y: 88, tile: :step_tl)
          sprite(1, x: 80, y: 88, tile: :step_tr)
          sprite(2, x: 72, y: 96, tile: :step_bl)
          sprite(3, x: 80, y: 96, tile: :step_br)
        end

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
        y = 232
        vy = 0
        grounded = 0
        facing = 0
        storey = 1
        cx = 0
        cy = 112
        armed = 1
        show(:one)
      end

      every_frame do
        # ── Walking. The step is taken and unmade, walk.exs's bargain. A
        # sixteen-tall body can straddle three brick rows, so the middle
        # row is asked too -- the corners alone would walk through the
        # side of a one-brick ledge. ──
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

        x15 = x + 15
        y15 = y + 15
        ymid = y + 8

        if touching?(:brick, x, y) or touching?(:brick, x15, y) or touching?(:brick, x, ymid) or
             touching?(:brick, x15, ymid) or touching?(:brick, x, y15) or
             touching?(:brick, x15, y15) do
          x = ox
          x15 = x + 15
        end

        # ── The jump. Two decisions live here, and both are edges rather
        # than levels. `armed` is the debounce: a held A is one jump, not a
        # jump per landing — the button must come up before it means again.
        # And the *release* is the height: the impulse leaves whole, and
        # letting go mid-rise cuts the speed to -2 — a tap is a hop, a held
        # press the full twenty-five pixels, and everything between is
        # between. ──
        if pressed?(:a) do
          if armed == 1 and grounded == 1 do
            vy = -5
            # The gravity phase restarts with the jump, or the frame you
            # pressed on would decide between a 25- and a 20-pixel leap.
            tick = 0
            grounded = 0
            armed = 0
            beep(:e5)
          end
        else
          armed = 1
          if negative?(vy) and vy < 254, do: vy = 254
        end

        # ── Gravity, every other frame; the fall is capped under the
        # bricks' eight so nothing tunnels. ──
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
        frow = y + 15
        frow = div(frow, 8)
        y = y + vy
        y15 = y + 15
        nrow = div(y15, 8)

        if touching?(:brick, x, y) or touching?(:brick, x15, y) or touching?(:brick, x, y15) or
             touching?(:brick, x15, y15) do
          y = oy
          y15 = y + 15

          # There is no `not`: rising or falling is an `else`, and only the
          # falling arm knocks -- a head bump is the same sentence, silent.
          if negative?(vy) do
            vy = 0
          else
            if grounded == 0, do: noise(:tick)
            vy = 0
          end
        else
          if nrow > frow and (touching?(:plank, x, y15) or touching?(:plank, x15, y15)) do
            # Landed on a plank: the feet snap to its top edge.
            y = nrow * 8
            y = y - 16
            y15 = y + 15
            if grounded == 0, do: noise(:tick)
            vy = 0
          end
        end

        # ── Standing on something? One pixel below the feet answers. ──
        y16 = y15 + 1
        grounded = 0

        if touching?(:brick, x, y16) or touching?(:brick, x15, y16) or
             touching?(:plank, x, y16) or touching?(:plank, x15, y16),
           do: grounded = 1

        # ── The ceilings' holes. A door is a place, not an edge: the row
        # *and* the columns, or the top of every jump would change storeys. ──
        if storey == 1 and y < 6 and x > 204 and x < 226 do
          storey = 2
          show(:two)
          y = 224
          cy = 112
          beep(:a5)
        end

        if storey == 2 and y < 6 and x > 12 and x < 34 do
          storey = 3
          show(:three)
          y = 224
          cy = 112
          beep(:a5)
        end

        # ── The flag: its base stands at the feet's height when the hero
        # is on its plank, so the bottom corners are the question. ──
        if touching?(:flag_base, x, y15) or touching?(:flag_base, x15, y15), do: become(:won)

        # ── The camera, chasing on both axes: roam.exs's dead zone. ──
        sx = x - cx
        if sx > 80 and cx < 96, do: cx = cx + 1
        if sx < 64 and cx > 0, do: cx = cx - 1
        sy = y - cy
        if sy > 68 and cy < 112, do: cy = cy + 1
        if sy < 52 and cy > 0, do: cy = cy - 1

        scroll(cx, cy)
        sx = x - cx
        sy = y - cy
        sx8 = sx + 8
        sy8 = sy + 8

        # ── The hero, in four quarters. Mirroring a 16-wide drawing is a
        # swap and a flip: the right tile drawn at the left, each half
        # turned by the hardware's own bit. ──
        anim = anim + 1
        if anim == 16, do: anim = 0

        if grounded == 0 do
          if facing == 0 do
            sprite(0, x: sx, y: sy, tile: :jump_tl)
            sprite(1, x: sx8, y: sy, tile: :jump_tr)
            sprite(2, x: sx, y: sy8, tile: :jump_bl)
            sprite(3, x: sx8, y: sy8, tile: :jump_br)
          else
            sprite(0, x: sx, y: sy, tile: :jump_tr, flip: :x)
            sprite(1, x: sx8, y: sy, tile: :jump_tl, flip: :x)
            sprite(2, x: sx, y: sy8, tile: :jump_br, flip: :x)
            sprite(3, x: sx8, y: sy8, tile: :jump_bl, flip: :x)
          end
        else
          if moving == 0 or anim < 8 do
            if facing == 0 do
              sprite(0, x: sx, y: sy, tile: :stand_tl)
              sprite(1, x: sx8, y: sy, tile: :stand_tr)
              sprite(2, x: sx, y: sy8, tile: :stand_bl)
              sprite(3, x: sx8, y: sy8, tile: :stand_br)
            else
              sprite(0, x: sx, y: sy, tile: :stand_tr, flip: :x)
              sprite(1, x: sx8, y: sy, tile: :stand_tl, flip: :x)
              sprite(2, x: sx, y: sy8, tile: :stand_br, flip: :x)
              sprite(3, x: sx8, y: sy8, tile: :stand_bl, flip: :x)
            end
          else
            if facing == 0 do
              sprite(0, x: sx, y: sy, tile: :step_tl)
              sprite(1, x: sx8, y: sy, tile: :step_tr)
              sprite(2, x: sx, y: sy8, tile: :step_bl)
              sprite(3, x: sx8, y: sy8, tile: :step_br)
            else
              sprite(0, x: sx, y: sy, tile: :step_tr, flip: :x)
              sprite(1, x: sx8, y: sy, tile: :step_tl, flip: :x)
              sprite(2, x: sx, y: sy8, tile: :step_br, flip: :x)
              sprite(3, x: sx8, y: sy8, tile: :step_bl, flip: :x)
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
