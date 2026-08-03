# Moananas Island — run the beach, jump the moai, gather the pineapples.
#
#     mix run games/moananas.exs
#
# writes `games/moananas.gb`. Play it with `bin/play games/moananas.gb`, or
# hot via `ELIXIR_ERL_OPTIONS="-noinput" mix atomboy.live games/moananas.exs`.
#
# The title is the concept art — the whole of it, deduplicated into the tile
# budget by `screen` — and Start fades to black before the beach fades up.
# The beach is a sideways-scrolling run: 256 pixels of island, the camera
# chasing, moai statues planted in the sand that cost a heart to touch,
# pineapples floating over the path and the planks, and the flag at the far
# end of the island. Three hearts; the flag is the game.
defmodule Moananas do
  use Potion

  tiles from: "art/moananas_sheet.png",
        names: [
          :pineapple_top,
          :pineapple_body,
          :moai_head,
          :moai_base,
          :palm_crown,
          :palm_trunk,
          :cloud,
          :border,
          :sand,
          :heart,
          :plank,
          :flag_top,
          :flag_base,
          :beach_sand,
          :m1_tl,
          :m1_tr,
          :m1_bl,
          :m1_br,
          :m2_tl,
          :m2_tr,
          :m2_bl,
          :m2_br,
          :m3_tl,
          :m3_tr,
          :m3_bl,
          :m3_br,
          :m4_tl,
          :m4_tr,
          :m4_bl,
          :m4_br
        ]

  # The whole drawing, one screen: 360 cells folded into the tile budget by
  # likeness — the air's dither weave repeats, the portrait does not.
  screen(:cover, from: "art/moananas_title.png", tolerance: 16)

  # ── The island ──────────────────────────────────────────────────────────────
  #
  # One room, 32 by 18: 256 pixels of beach under a horizontal camera. Sand
  # floor, planks in the air with pineapples over them, moai standing in the
  # sand — passable, and they hurt — and the flag planted at the far end.

  edge = fn -> "#" <> String.duplicate(" ", 30) <> "#" end

  place = fn row, spots ->
    Enum.reduce(spots, row, fn {col, char}, row ->
      {head, tail} = String.split_at(row, col)
      head <> char <> String.slice(tail, 1..-1//1)
    end)
  end

  # The planks sit 24 pixels over the sand -- inside the jump's 25 -- and the
  # moai keep out of their columns. Row 13 planks, rows 14-15 statues, palm
  # and flag; rows 16-17 sand.
  @beach ([place.(edge.(), [{6, "c"}, {22, "c"}])] ++
            List.duplicate(edge.(), 12) ++
            [
              place.(edge.(), [
                {9, "="},
                {10, "="},
                {11, "="},
                {16, "="},
                {17, "="},
                {18, "="},
                {24, "="},
                {25, "="},
                {26, "="}
              ])
            ] ++
            [place.(edge.(), [{2, "P"}, {6, "m"}, {13, "m"}, {19, "m"}, {28, "m"}, {30, "F"}])] ++
            [place.(edge.(), [{2, "T"}, {6, "M"}, {13, "M"}, {19, "M"}, {28, "M"}, {30, "B"}])] ++
            ["#" <> String.duplicate("f", 30) <> "#"] ++
            ["#" <> String.duplicate("f", 30) <> "#"])
         |> Enum.join("\n")

  @tiles %{
    ?# => :border,
    ?f => :beach_sand,
    ?c => :cloud,
    ?m => :moai_head,
    ?M => :moai_base,
    ?P => :palm_crown,
    ?T => :palm_trunk,
    ?F => :flag_top,
    ?B => :flag_base,
    ?= => :plank
  }

  room :beach, @beach, tiles: @tiles

  # ── The music ───────────────────────────────────────────────────────────────

  music :island,
        [
          lead:
            "e5 . g5 . e5 c5 d5 . | e5 . g5 . a5 g5 e5 . | d5 . f5 . d5 b4 c5 . | e5 c5 d5 b4 c5 . . -",
          harmony:
            "- - e5 . g5 . e5 c5 | d5 . e5 . g5 . a5 g5 | e5 . d5 . f5 . d5 b4 | c5 . e5 c5 d5 b4 c5 .",
          bass:
            "c2 . . g2 . . c2 . | c2 . . g2 . . e2 . | g1 . . d2 . . g2 . | c2 . g1 . c2 . . ."
        ],
        beat: 7,
        duty: [lead: :quarter, harmony: :eighth],
        envelope: [lead: :organ, harmony: :pluck],
        gap: 2

  music :fanfare,
        [
          lead: "c5 e5 g5 . c6 . . . b5 c6 . . . . . .",
          harmony: "- . e4 g4 e5 . g4 . f5 e5 . . . . . .",
          bass: "c2 . . . c2 . g1 . c2 . . . . . . ."
        ],
        beat: 9,
        duty: [lead: :quarter, harmony: :eighth],
        envelope: [lead: :organ, harmony: :pluck],
        gap: 2

  # ── Moananas ────────────────────────────────────────────────────────────────

  defactor :moananas do
    variables veil: 0,
              leaving: 0,
              primed: 0,
              anim: 0,
              x: 16,
              y: 112,
              ox: 0,
              oy: 0,
              vy: 0,
              tick: 0,
              grounded: 0,
              facing: 0,
              moving: 0,
              blink: 0,
              flick: 0,
              hidden: 0,
              hearts: 3,
              score: 0,
              tens_tile: 2,
              units_tile: 2,
              playing: 0,
              cx: 0,
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
              armed: 1,
              hxm8: 0,
              hxp16: 0,
              ym16: 0,
              yp16: 0,
              slot: 0

    state :title do
      on_enter do
        fade(3)
        veil = 30
        leaving = 0
        primed = 0
        playing = 0
        scroll(0, 0)
        cx = 0
        show(:cover)
        # The cover's own small type melts under the dedup tolerance; the
        # kernel's font is sharper than a mushed tile — overlay it.
        text(5, 13, "PRESS START")
        play(:island)
      end

      every_frame do
        sprite(0, x: 0, y: 200, tile: :heart)
        sprite(1, x: 0, y: 200, tile: :heart)
        sprite(2, x: 0, y: 200, tile: :heart)
        sprite(3, x: 0, y: 200, tile: :heart)
        sprite(4, x: 0, y: 200, tile: :heart)
        sprite(5, x: 0, y: 200, tile: :heart)
        sprite(6, x: 0, y: 200, tile: :heart)
        sprite(7, x: 0, y: 200, tile: :heart)
        sprite(8, x: 0, y: 200, tile: :heart)

        if veil > 0 do
          veil = veil - 1
          if veil == 20, do: fade(2)
          if veil == 10, do: fade(1)
          if veil == 0, do: fade(0)
        end

        # The fondu au noir: Start pulls the veil down before the island.
        if leaving > 0 do
          leaving = leaving - 1
          if leaving == 16, do: fade(1)
          if leaving == 8, do: fade(2)
          if leaving == 1, do: fade(3)
          if leaving == 0, do: become(:run)
        end

        if pressed?(:start) do
          if primed == 1 and leaving == 0 and veil == 0, do: leaving = 24
        else
          primed = 1
        end
      end
    end

    state :run do
      on_enter do
        show(:beach)
        veil = 30
        x = 16
        y = 112
        vy = 0
        cx = 0
        facing = 0
        blink = 0
        hearts = 3
        score = 0
        playing = 1
        primed = 0
        armed = 1
      end

      every_frame do
        if veil > 0 do
          veil = veil - 1
          if veil == 20, do: fade(2)
          if veil == 10, do: fade(1)
          if veil == 0, do: fade(0)
        end

        # ── Running. The island's ends are numbers, not walls: nothing else
        # on the beach blocks sideways, so no wall is asked about. ──
        moving = 0

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

        if x < 8, do: x = 8
        if x > 232, do: x = 232

        # ── The jump, whole from the Tower: armed is the debounce, and the
        # release cuts the rise — a tap hops, a held press leaps. ──
        if pressed?(:a) do
          if armed == 1 and grounded == 1 do
            vy = -5
            tick = 0
            grounded = 0
            armed = 0
            beep(:a4)
          end
        else
          armed = 1
          if negative?(vy) and vy < 254, do: vy = 254
        end

        tick = tick + 1

        if tick == 2 do
          tick = 0

          if negative?(vy) do
            vy = vy + 1
          else
            if vy < 4, do: vy = vy + 1
          end
        end

        # ── The vertical move: the sand is solid, the planks are landed on
        # when the feet cross downward into their row. ──
        oy = y
        frow = y + 15
        frow = div(frow, 8)
        y = y + vy
        y15 = y + 15
        nrow = div(y15, 8)

        if touching?(:beach_sand, x, y15) or touching?(:beach_sand, x15, y15) do
          y = oy
          y15 = y + 15
          if grounded == 0, do: noise(:tick)
          vy = 0
        else
          if nrow > frow and (touching?(:plank, x, y15) or touching?(:plank, x15, y15)) do
            y = nrow * 8
            y = y - 16
            y15 = y + 15
            if grounded == 0, do: noise(:tick)
            vy = 0
          end
        end

        x15 = x + 15
        ymid = y + 8
        y16 = y15 + 1
        grounded = 0

        if touching?(:beach_sand, x, y16) or touching?(:beach_sand, x15, y16) or
             touching?(:plank, x, y16) or touching?(:plank, x15, y16),
           do: grounded = 1

        # ── The moai: passable, and they cost. The blink is the mercy. ──
        hidden = 0

        if blink > 0 do
          blink = blink - 1
          flick = rem(blink, 8)
          if flick < 4, do: hidden = 1
        end

        if blink == 0 do
          if touching?(:moai_head, x, ymid) or touching?(:moai_head, x15, ymid) or
               touching?(:moai_base, x, y15) or touching?(:moai_base, x15, y15) do
            hearts = hearts - 1
            blink = 90
            noise(:boom)
          end
        end

        # ── The flag: the end of the island. ──
        if touching?(:flag_top, x, ymid) or touching?(:flag_top, x15, ymid) or
             touching?(:flag_base, x, y15) or touching?(:flag_base, x15, y15),
           do: become(:crowned)

        if hearts == 0, do: become(:sunk)

        # ── The window the pineapples read. ──
        hxm8 = x - 8
        hxp16 = x + 16
        ym16 = y - 16
        yp16 = y + 16

        # ── The camera, chasing sideways. ──
        sx = x - cx
        if sx > 80 and cx < 96, do: cx = cx + 1
        if sx < 64 and cx > 0, do: cx = cx - 1
        scroll(cx, 0)
        sx = x - cx
        sy = y
        sx8 = sx + 8
        sy8 = sy + 8

        # ── The HUD rides in sprites, so the world scrolls under it: two
        # digits of score, three hearts. The digit tiles are the kernel's
        # font, reached by arithmetic — tile 2 is the zero. ──
        tens_tile = div(score, 10)
        tens_tile = tens_tile + 2
        units_tile = rem(score, 10)
        units_tile = units_tile + 2
        sprite(4, x: 8, y: 8, tile: tens_tile)
        sprite(5, x: 16, y: 8, tile: units_tile)

        if hearts > 0,
          do: sprite(6, x: 128, y: 8, tile: :heart),
          else: sprite(6, x: 0, y: 200, tile: :heart)

        if hearts > 1,
          do: sprite(7, x: 140, y: 8, tile: :heart),
          else: sprite(7, x: 0, y: 200, tile: :heart)

        if hearts > 2,
          do: sprite(8, x: 152, y: 8, tile: :heart),
          else: sprite(8, x: 0, y: 200, tile: :heart)

        # ── The elf, four quarters, the Tower's poses. ──
        anim = anim + 1
        if anim == 16, do: anim = 0

        if hidden == 1 do
          sprite(0, x: 0, y: 200, tile: :m1_tl)
          sprite(1, x: 0, y: 200, tile: :m1_tr)
          sprite(2, x: 0, y: 200, tile: :m1_bl)
          sprite(3, x: 0, y: 200, tile: :m1_br)
        else
          if moving == 0 or anim < 8 do
            if facing == 0 do
              sprite(0, x: sx, y: sy, tile: :m1_tl)
              sprite(1, x: sx8, y: sy, tile: :m1_tr)
              sprite(2, x: sx, y: sy8, tile: :m1_bl)
              sprite(3, x: sx8, y: sy8, tile: :m1_br)
            else
              sprite(0, x: sx, y: sy, tile: :m1_tr, flip: :x)
              sprite(1, x: sx8, y: sy, tile: :m1_tl, flip: :x)
              sprite(2, x: sx, y: sy8, tile: :m1_br, flip: :x)
              sprite(3, x: sx8, y: sy8, tile: :m1_bl, flip: :x)
            end
          else
            if facing == 0 do
              sprite(0, x: sx, y: sy, tile: :m3_tl)
              sprite(1, x: sx8, y: sy, tile: :m3_tr)
              sprite(2, x: sx, y: sy8, tile: :m3_bl)
              sprite(3, x: sx8, y: sy8, tile: :m3_br)
            else
              sprite(0, x: sx, y: sy, tile: :m3_tr, flip: :x)
              sprite(1, x: sx8, y: sy, tile: :m3_tl, flip: :x)
              sprite(2, x: sx, y: sy8, tile: :m3_br, flip: :x)
              sprite(3, x: sx8, y: sy8, tile: :m3_bl, flip: :x)
            end
          end
        end
      end
    end

    state :sunk do
      on_enter do
        playing = 0
        primed = 0
        text(5, 8, "GAME OVER")
        noise(:boom)
      end

      every_frame do
        if pressed?(:start) do
          if primed == 1, do: become(:title)
        else
          primed = 1
        end
      end
    end

    state :crowned do
      on_enter do
        playing = 0
        primed = 0
        silence()
        play(:fanfare)
        text(4, 8, "ISLAND KING")
      end

      every_frame do
        if pressed?(:start) do
          if primed == 1, do: become(:title)
        else
          primed = 1
        end
      end
    end
  end

  # ── The pineapples ──────────────────────────────────────────────────────────
  #
  # Six of them, planted along the island: the even ones low over the sand,
  # the odd ones over the planks — a low jump and a climb. Each is a world
  # position and a `taken` flag; the sprite is the position minus the camera,
  # parked once it leaves the glass or the ground. `slot` is the hero's
  # scratch cell: a pooled name cannot number a sprite.
  defactor :pineapple, count: 6 do
    variables wx: 0, wy: 0, taken: 0, seeded: 0, px: 0, py8: 0

    every_frame do
      if seeded == 0 do
        seeded = 1
        wx = me * 32
        wx = wx + 44
        wy = 90
        if rem(me, 2) == 1, do: wy = 56
      end

      slot = me * 2
      slot = slot + 9

      if playing == 0 do
        taken = 0
        sprite(slot, x: 0, y: 200, tile: :pineapple_top)
        slot = slot + 1
        sprite(slot, x: 0, y: 200, tile: :pineapple_top)
      else
        if taken == 0 and wx > hxm8 and wx < hxp16 and wy > ym16 and wy < yp16 do
          taken = 1
          score = score + 1
          beep(:c6)
        end

        px = wx - cx

        if taken == 0 and px < 153 do
          py8 = wy + 8
          sprite(slot, x: px, y: wy, tile: :pineapple_top)
          slot = slot + 1
          sprite(slot, x: px, y: py8, tile: :pineapple_body)
        else
          sprite(slot, x: 0, y: 200, tile: :pineapple_top)
          slot = slot + 1
          sprite(slot, x: 0, y: 200, tile: :pineapple_top)
        end
      end
    end
  end
end

path = Path.join(__DIR__, "moananas.gb")
File.write!(path, Moananas.rom())
IO.puts("#{path} — #{byte_size(Moananas.rom())} bytes, aloha.")
