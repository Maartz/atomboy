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
# chasing, totem idols planted in the sand that cost a heart to touch, a
# slime patrolling the stretch between them, pineapples floating over the
# path and the planks, and the chest and flag at the far end of the island.
# Three hearts; the flag is the game.
#
# Every tile it draws with is built by `art/island_art.py`. The sand, the
# plank, the boulder, the totems, the chest, the skull and the slime are
# SGQ_Dungeon's pixels mapped colour-for-shade — the pack is native Game Boy
# art and arrives untouched — while the sky, the sea and the palm are drawn
# there in flat fields, and `art/title_art.py` imports the cover. The hero
# is the Eris Esra template with Moananas's hair and glasses painted on.
#
# Both scripts are written against one fact about the panel: its shade 0 and
# shade 1 are the same green. See the header of `art/island_art.py`.
defmodule Moananas do
  use Potion

  tiles from: "art/moananas_sheet.png",
        names: [
          :sky,
          :sun_tl,
          :sun_tr,
          :sun_bl,
          :sun_br,
          :cloud_l,
          :cloud_m,
          :cloud_r,
          :gull,
          :isle_l,
          :isle_m,
          :isle_r,
          :sea_crest,
          :sea_a,
          :sea_b,
          :surf_a,
          :surf_b,
          :sand_a,
          :sand_b,
          :beach_sand,
          :sand_deep,
          :plank,
          :palm_a,
          :palm_b,
          :palm_c,
          :palm_d,
          :palm_e,
          :palm_f,
          :trunk,
          :trunk_base,
          :rock_tl,
          :rock_tr,
          :rock_bl,
          :rock_br,
          :plant_tl,
          :plant_tr,
          :plant_bl,
          :plant_br,
          :skull_tl,
          :skull_tr,
          :skull_bl,
          :skull_br,
          :chest_tl,
          :chest_tr,
          :chest_bl,
          :chest_br,
          :totem_a,
          :totem_b,
          :totem_c,
          :totem_d,
          :totem_e,
          :totem_f,
          :moai_base,
          :moai_br,
          :flag_top,
          :flag_base,
          :heart,
          :pineapple_top,
          :pineapple_body,
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
          :sl1_tl,
          :sl1_tr,
          :sl1_bl,
          :sl1_br,
          :sl2_tl,
          :sl2_tr,
          :sl2_bl,
          :sl2_br
        ]

  # The whole drawing, one screen: 360 cells folded into the tile budget by
  # likeness — the paper repeats, the portrait does not. Twenty-two is as
  # sharp as the cartridge affords: 132 tiles for the cover and 79 for the
  # beach is 211 of the 212 there are. The folding only works because
  # `art/title_art.py` hands over *clean* paper — a three-pixel fleck is
  # within tolerance of blank, so before the despeckle every elected tile
  # stamped its fleck across the page.
  screen(:cover, from: "art/moananas_title.png", tolerance: 22)

  # ── The island ──────────────────────────────────────────────────────────────
  #
  # One room, 32 by 18: 256 pixels of beach under a horizontal camera.
  #
  # The composition, top to bottom: flat light sky with a sun and clouds, a
  # volcano on the horizon, flat mid sea with staggered glints, the surf
  # line, then the beach — the same flat light as the sky, the dark sea
  # between them keeping them apart, with the artist's shell-marks scattered
  # through it — and the floor's dark face under an ink crest. Flat fields,
  # sparse specks, ink silhouettes; the one dither left is the strip of wet
  # sand inside the surf tiles.
  #
  # Only two tiles are ever asked a question: `:beach_sand`, which is the
  # floor, and `:plank`. Everything else is scenery the hero runs in front of
  # — which is what lets the beach be crowded without costing a single
  # `touching?` in the frame.

  sky = fn -> List.duplicate(?\s, 32) end

  banded = fn a, b -> for c <- 0..31, do: if(rem(c, 2) == 0, do: a, else: b) end

  ground =
    for row <- 0..17 do
      case row do
        7 -> List.duplicate(?[, 32)
        8 -> banded.(?{, ?})
        9 -> banded.(?}, ?{)
        10 -> banded.(?~, ?`)
        r when r in 11..15 -> List.duplicate(?., 32)
        16 -> List.duplicate(?S, 32)
        17 -> List.duplicate(?D, 32)
        _ -> sky.()
      end
    end

  paint = fn rows, marks ->
    Enum.reduce(marks, rows, fn {col, row, text}, rows ->
      List.update_at(rows, row, fn line ->
        text
        |> String.to_charlist()
        |> Enum.with_index()
        |> Enum.reduce(line, fn {char, i}, line -> List.replace_at(line, col + i, char) end)
      end)
    end)
  end

  # The planks sit 24 pixels over the sand — inside the jump's 25 — and every
  # standing thing keeps out of their columns. The shell-marks go down first,
  # so anything standing on one simply covers it.
  @beach paint.(ground, [
           # the shell-marks in the sand
           {2, 11, ";"},
           {9, 11, ","},
           {17, 11, ","},
           {24, 11, ";"},
           {29, 11, ","},
           {7, 12, ";"},
           {16, 12, ","},
           {23, 12, ";"},
           {31, 12, ";"},
           {2, 13, ";"},
           {11, 13, ","},
           {20, 13, ";"},
           {26, 13, ";"},
           {1, 14, ";"},
           {15, 14, ","},
           {23, 14, ","},
           {29, 14, ";"},
           {3, 15, ";"},
           {14, 15, ","},
           {24, 15, ";"},
           {31, 15, ","},
           # the sky
           {25, 0, "01"},
           {25, 1, "23"},
           {2, 2, "cde"},
           {18, 3, "cde"},
           {12, 4, "v"},
           {8, 5, "v"},
           {27, 4, "v"},
           # the far island, standing on the horizon the crest draws
           {4, 6, "ijk"},
           {20, 6, "ijk"},
           # the palms: a canopy two tiles deep, then the trunk down to the sand
           {3, 12, "PQR"},
           {3, 13, "pqr"},
           {4, 14, "T"},
           {4, 15, "U"},
           {27, 12, "PQR"},
           {27, 13, "pqr"},
           {28, 14, "T"},
           {28, 15, "U"},
           # what the hero lands on
           {8, 13, "==="},
           {15, 13, "==="},
           {22, 13, "==="},
           # what stands in the sand: the boulder, the skull under the
           # boardwalk, the two totems, the plant, the chest, the flag
           {6, 14, "ab"},
           {6, 15, "AB"},
           {9, 14, "wx"},
           {9, 15, "WX"},
           {12, 12, "gh"},
           {12, 13, "IJ"},
           {12, 14, "mM"},
           {12, 15, "zZ"},
           {18, 12, "gh"},
           {18, 13, "IJ"},
           {18, 14, "mM"},
           {18, 15, "zZ"},
           {21, 14, "no"},
           {21, 15, "NO"},
           {25, 14, "<>"},
           {25, 15, "()"},
           {30, 14, "F"},
           {30, 15, "G"}
         ])
         |> Enum.map_join("\n", &List.to_string/1)

  # `.` is the open sand and it maps to `:sky` on purpose: both are the same
  # flat light tile, and naming one tile twice would spend a budget slot on
  # a duplicate bitmap.
  @tiles %{
    ?\s => :sky,
    ?. => :sky,
    ?0 => :sun_tl,
    ?1 => :sun_tr,
    ?2 => :sun_bl,
    ?3 => :sun_br,
    ?c => :cloud_l,
    ?d => :cloud_m,
    ?e => :cloud_r,
    ?v => :gull,
    ?i => :isle_l,
    ?j => :isle_m,
    ?k => :isle_r,
    ?[ => :sea_crest,
    ?{ => :sea_a,
    ?} => :sea_b,
    ?~ => :surf_a,
    ?` => :surf_b,
    ?, => :sand_a,
    ?; => :sand_b,
    ?S => :beach_sand,
    ?D => :sand_deep,
    ?= => :plank,
    ?P => :palm_a,
    ?Q => :palm_b,
    ?R => :palm_c,
    ?p => :palm_d,
    ?q => :palm_e,
    ?r => :palm_f,
    ?T => :trunk,
    ?U => :trunk_base,
    ?a => :rock_tl,
    ?b => :rock_tr,
    ?A => :rock_bl,
    ?B => :rock_br,
    ?n => :plant_tl,
    ?o => :plant_tr,
    ?N => :plant_bl,
    ?O => :plant_br,
    ?w => :skull_tl,
    ?x => :skull_tr,
    ?W => :skull_bl,
    ?X => :skull_br,
    ?g => :totem_a,
    ?h => :totem_b,
    ?I => :totem_c,
    ?J => :totem_d,
    ?m => :totem_e,
    ?M => :totem_f,
    ?z => :moai_base,
    ?Z => :moai_br,
    ?< => :chest_tl,
    ?> => :chest_tr,
    ?( => :chest_bl,
    ?) => :chest_br,
    ?F => :flag_top,
    ?G => :flag_base
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

        # ── The totems: passable, and they cost. The blink is the mercy. ──
        hidden = 0

        if blink > 0 do
          blink = blink - 1
          flick = rem(blink, 8)
          if flick < 4, do: hidden = 1
        end

        # The totem is four tiles tall, but the question is asked only of its
        # feet — the two bottom tiles, at both of the hero's edges, at the
        # height his own feet are at. Four questions, the same four the frame
        # could always afford — and a jump that grazes the wings is let
        # through, which is the forgiving way round.
        if blink == 0 do
          if touching?(:moai_base, x, y15) or touching?(:moai_base, x15, y15) or
               touching?(:moai_br, x, y15) or touching?(:moai_br, x15, y15) do
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

        # ── Moananas, four quarters and three poses: standing, mid-stride,
        # airborne. The mirror is the flip and a swap of the columns, so the
        # left-facing run costs no tiles at all. ──
        anim = anim + 1
        if anim == 16, do: anim = 0

        if hidden == 1 do
          sprite(0, x: 0, y: 200, tile: :m1_tl)
          sprite(1, x: 0, y: 200, tile: :m1_tr)
          sprite(2, x: 0, y: 200, tile: :m1_bl)
          sprite(3, x: 0, y: 200, tile: :m1_br)
        else
          if grounded == 0 do
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
                sprite(0, x: sx, y: sy, tile: :m2_tl)
                sprite(1, x: sx8, y: sy, tile: :m2_tr)
                sprite(2, x: sx, y: sy8, tile: :m2_bl)
                sprite(3, x: sx8, y: sy8, tile: :m2_br)
              else
                sprite(0, x: sx, y: sy, tile: :m2_tr, flip: :x)
                sprite(1, x: sx8, y: sy, tile: :m2_tl, flip: :x)
                sprite(2, x: sx, y: sy8, tile: :m2_br, flip: :x)
                sprite(3, x: sx8, y: sy8, tile: :m2_bl, flip: :x)
              end
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
  # ── The slime ───────────────────────────────────────────────────────────────
  #
  # SGQ's slime, patrolling the open stretch of sand between the two totems
  # at half the hero's walking pace, squashing against the ground every
  # half-second. It shares the hero's `blink` mercy, so a totem graze and a
  # slime touch draw from the same ninety frames of grace, and it asks no
  # `touching?` at all — its world is the same box test the pineapples use.
  defactor :slime do
    variables swx: 0, sdir: 0, sgo: 0, sstep: 0, sbounce: 0, spx: 0, spy: 0, spx8: 0, spy8: 0

    every_frame do
      if sgo == 0 do
        sgo = 1
        swx = 112
      end

      if playing == 0 do
        sprite(21, x: 0, y: 200, tile: :sl1_tl)
        sprite(22, x: 0, y: 200, tile: :sl1_tr)
        sprite(23, x: 0, y: 200, tile: :sl1_bl)
        sprite(24, x: 0, y: 200, tile: :sl1_br)
      else
        sstep = sstep + 1

        if sstep == 2 do
          sstep = 0

          if sdir == 0 do
            swx = swx + 1
            if swx > 127, do: sdir = 1
          else
            swx = swx - 1
            if swx < 113, do: sdir = 0
          end
        end

        sbounce = sbounce + 1
        if sbounce == 32, do: sbounce = 0

        if blink == 0 do
          if swx > hxm8 and swx < hxp16 and yp16 > 115 do
            hearts = hearts - 1
            blink = 90
            noise(:boom)
          end
        end

        spx = swx - cx
        spy = 112
        spx8 = spx + 8
        spy8 = spy + 8

        if spx < 153 do
          if sbounce < 16 do
            sprite(21, x: spx, y: spy, tile: :sl1_tl)
            sprite(22, x: spx8, y: spy, tile: :sl1_tr)
            sprite(23, x: spx, y: spy8, tile: :sl1_bl)
            sprite(24, x: spx8, y: spy8, tile: :sl1_br)
          else
            sprite(21, x: spx, y: spy, tile: :sl2_tl)
            sprite(22, x: spx8, y: spy, tile: :sl2_tr)
            sprite(23, x: spx, y: spy8, tile: :sl2_bl)
            sprite(24, x: spx8, y: spy8, tile: :sl2_br)
          end
        else
          sprite(21, x: 0, y: 200, tile: :sl1_tl)
          sprite(22, x: 0, y: 200, tile: :sl1_tr)
          sprite(23, x: 0, y: 200, tile: :sl1_bl)
          sprite(24, x: 0, y: 200, tile: :sl1_br)
        end
      end
    end
  end

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
