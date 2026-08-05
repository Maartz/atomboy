# Moananas Island — walk the island, dodge the totems, gather the pineapples.
#
#     mix run games/moananas.exs
#
# writes `games/moananas.gb`. Play it with `bin/play games/moananas.gb`, or
# hot via `ELIXIR_ERL_OPTIONS="-noinput" mix atomboy.live games/moananas.exs`.
#
# The title is the concept art — the whole of it, deduplicated into the tile
# budget by `screen` — and Start fades to black before the island fades up.
# The game is seen from above, the way its tileset was drawn: a sand island
# in a ring of water, the camera chasing on both axes, totem idols that cost
# a heart to bump, a slime patrolling the south sand, pineapples scattered
# over the island, and a dock running off the south shore with the flag at
# its end. Three hearts; the flag is the game.
#
# It was a side-scroller twice, and it looked pasted together twice, because
# SGQ_Dungeon is a *top-down* tileset: the idol stands in a vasque, the
# chest is drawn at three-quarters, the ground is a floor. The perspective
# of the assets is the perspective of the game now, and everything stands in
# the world it was drawn for.
#
# Every tile is built by `art/island_art.py` — the pack's pixels mapped
# colour-for-shade, the water and shoreline drawn flat — and
# `art/title_art.py` imports the cover. The hero is the Eris Esra template,
# which walks in five directions; three are taken and Moananas's hair and
# glasses are painted onto each facing.
defmodule Moananas do
  use Potion

  tiles from: "art/moananas_sheet.png",
        names: [
          :sky,
          :sea_a,
          :sea_b,
          :shore_n,
          :shore_s,
          :shore_w,
          :shore_e,
          :shore_nw,
          :shore_ne,
          :shore_sw,
          :shore_se,
          :sand_a,
          :sand_b,
          :plank,
          :rock_tl,
          :rock_tr,
          :rock_bl,
          :rock_br,
          :palm_tl,
          :palm_tr,
          :palm_bl,
          :palm_br,
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
          :md1_tl,
          :md1_tr,
          :md1_bl,
          :md1_br,
          :md2_tl,
          :md2_tr,
          :md2_bl,
          :md2_br,
          :ms1_tl,
          :ms1_tr,
          :ms1_bl,
          :ms1_br,
          :ms2_tl,
          :ms2_tr,
          :ms2_bl,
          :ms2_br,
          :mu1_tl,
          :mu1_tr,
          :mu1_bl,
          :mu1_br,
          :mu2_tl,
          :mu2_tr,
          :mu2_bl,
          :mu2_br,
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
  # sharp as the cartridge affords: 127 tiles for the cover and 75 for the
  # island is 202 of the 212 there are. The folding only works because
  # `art/title_art.py` hands over *clean* paper — a three-pixel fleck is
  # within tolerance of blank, so before the despeckle every elected tile
  # stamped its fleck across the page.
  screen(:cover, from: "art/moananas_title.png", tolerance: 22)

  # ── The island ──────────────────────────────────────────────────────────────
  #
  # One room, 32 by 32: a 256-pixel world under a camera that chases on both
  # axes. Water everywhere, then the shore ring — ink waterline, one strip
  # of wet-sand dither — and inside it the sand, flat light with the pack's
  # shell-marks scattered through. The island is a rectangle from column 4
  # to 27 and row 4 to 27, which is what lets the walls be *numbers*: the
  # hero is fenced by comparisons, and no `touching?` is ever spent on the
  # water. The dock is the one gap — a two-tile boardwalk off the south
  # shore, walkable because the fence widens along its columns.
  #
  # Only the totems' feet and the flag are ever asked a question. Everything
  # else is scenery the hero walks in front of.

  water = for row <- 0..31, do: for(c <- 0..31, do: if(rem(c + row, 2) == 0, do: ?{, else: ?}))

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

  # The island: shore ring, sand interior, then everything standing on it.
  # The shell-marks go down before the objects, so anything standing on one
  # simply covers it.
  @island paint.(
            water,
            [
              {4, 4, "1" <> String.duplicate("u", 22) <> "2"}
            ] ++
              for(r <- 5..26, do: {4, r, "l" <> String.duplicate(".", 22) <> "e"}) ++
              [
                {4, 27, "3" <> String.duplicate("d", 22) <> "4"},
                # the shell-marks in the sand
                {8, 9, ";"},
                {14, 6, ","},
                {24, 11, ";"},
                {6, 13, ","},
                {13, 17, ";"},
                {25, 15, ","},
                {8, 17, ";"},
                {18, 22, ","},
                {23, 24, ";"},
                {12, 20, ","},
                {19, 12, ";"},
                {16, 25, ","},
                {6, 22, ";"},
                {26, 7, ","},
                {11, 8, ";"},
                {22, 14, ","},
                # the dock south, and the flag flying at its end
                {15, 27, "=="},
                {15, 28, "=="},
                {15, 29, "F="},
                {15, 30, "G="},
                # the totems, feet on their bottom rows
                {10, 12, "gh"},
                {10, 13, "IJ"},
                {10, 14, "mM"},
                {10, 15, "zZ"},
                {20, 16, "gh"},
                {20, 17, "IJ"},
                {20, 18, "mM"},
                {20, 19, "zZ"},
                # the boulder, the skull, the chest, the palms
                {7, 20, "ab"},
                {7, 21, "AB"},
                {22, 8, "wx"},
                {22, 9, "WX"},
                {15, 8, "<>"},
                {15, 9, "()"},
                {6, 6, "no"},
                {6, 7, "NO"},
                {17, 5, "no"},
                {17, 6, "NO"},
                {24, 20, "no"},
                {24, 21, "NO"},
                {9, 24, "no"},
                {9, 25, "NO"}
              ]
          )
          |> Enum.map_join("\n", &List.to_string/1)

  # `.` is the open sand and it maps to `:sky` on purpose: both are the same
  # flat light tile, and naming one tile twice would spend a budget slot on
  # a duplicate bitmap.
  @tiles %{
    ?\s => :sky,
    ?. => :sky,
    ?{ => :sea_a,
    ?} => :sea_b,
    ?u => :shore_n,
    ?d => :shore_s,
    ?l => :shore_w,
    ?e => :shore_e,
    ?1 => :shore_nw,
    ?2 => :shore_ne,
    ?3 => :shore_sw,
    ?4 => :shore_se,
    ?, => :sand_a,
    ?; => :sand_b,
    ?= => :plank,
    ?a => :rock_tl,
    ?b => :rock_tr,
    ?A => :rock_bl,
    ?B => :rock_br,
    ?n => :palm_tl,
    ?o => :palm_tr,
    ?N => :palm_bl,
    ?O => :palm_br,
    ?w => :skull_tl,
    ?x => :skull_tr,
    ?W => :skull_bl,
    ?X => :skull_br,
    ?< => :chest_tl,
    ?> => :chest_tr,
    ?( => :chest_bl,
    ?) => :chest_br,
    ?g => :totem_a,
    ?h => :totem_b,
    ?I => :totem_c,
    ?J => :totem_d,
    ?m => :totem_e,
    ?M => :totem_f,
    ?z => :moai_base,
    ?Z => :moai_br,
    ?F => :flag_top,
    ?G => :flag_base
  }

  room :beach, @island, tiles: @tiles

  # ── The music ───────────────────────────────────────────────────────────────
  #
  # Four bars of C major with a calypso lilt, built to the craft's grammar:
  # the lead sings in two-bar call and answer with a breath at the end of
  # each phrase, its one peak — the c6 — visited once, and the seam is a
  # cadence: the loop ends on d5 over the dominant, which wants bar one.
  # Pulse 2 is the classic echo, the same line two steps late on a thin
  # duty with a plucked envelope, so the ear hears a hall rather than two
  # instruments. The bass pumps root and fifth, one chord a bar — C, C, F,
  # G — and walks into each change on the last eighths.

  music :island,
        [
          lead:
            "c5 e5 g5 . g5 a5 g5 . | e5 . d5 c5 d5 . . . | e5 g5 c6 . a5 g5 a5 . | g5 . e5 c5 d5 . . .",
          harmony:
            "- - c5 e5 g5 . g5 a5 | g5 . e5 . d5 c5 d5 . | . . e5 g5 c6 . a5 g5 | a5 . g5 . e5 c5 d5 .",
          bass:
            "c2 . g2 . c2 . g2 . | c2 . g2 . c2 . d2 e2 | f2 . c3 . f2 . a2 . | g2 . d3 . g2 . b2 ."
        ],
        beat: 8,
        duty: [lead: :quarter, harmony: :eighth],
        envelope: [lead: :organ, harmony: :pluck],
        vibrato: :gentle,
        gap: 2

  # The fanfare climbs the tonic arpeggio, breathes, and plants the summit
  # c6 once at the end of a IV–V walk home.
  music :fanfare,
        [
          lead: "c5 e5 g5 . c6 . g5 . a5 b5 c6 . . . . .",
          harmony: "- - c5 e5 g5 . c6 . g5 . a5 b5 c6 . . .",
          bass: "c2 . g2 . e2 . g2 . f2 . g2 . c2 . . ."
        ],
        beat: 8,
        duty: [lead: :quarter, harmony: :eighth],
        envelope: [lead: :organ, harmony: :pluck],
        gap: 2

  # ── Moananas ────────────────────────────────────────────────────────────────

  defactor :moananas do
    variables veil: 0,
              leaving: 0,
              primed: 0,
              anim: 0,
              x: 120,
              y: 150,
              ox: 0,
              oy: 0,
              bad: 0,
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
              cy: 0,
              sx: 0,
              sy: 0,
              sx8: 0,
              sy8: 0,
              x15: 0,
              y15: 0,
              ymid: 0,
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
        cy = 0
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
        x = 120
        y = 150
        cx = 40
        cy = 60
        facing = 0
        blink = 0
        hearts = 3
        score = 0
        playing = 1
        primed = 0
      end

      every_frame do
        if veil > 0 do
          veil = veil - 1
          if veil == 20, do: fade(2)
          if veil == 10, do: fade(1)
          if veil == 0, do: fade(0)
        end

        # ── Walking. The island is a rectangle, so its walls are numbers:
        # the sand runs from 30 to 210 across and 28 to 196 down, and the
        # fence widens along the dock's columns so the boardwalk can be
        # walked to its end. Each axis moves and is caught separately —
        # sliding along a wall must not stop the other axis. ──
        moving = 0

        ox = x

        if pressed?(:right) do
          x = x + 1
          facing = 2
          moving = 1
        end

        if pressed?(:left) do
          x = x - 1
          facing = 3
          moving = 1
        end

        bad = 0
        if x < 30, do: bad = 1
        if x > 210, do: bad = 1

        if y > 196 do
          if x < 114, do: bad = 1
          if x > 126, do: bad = 1
        end

        if bad == 1, do: x = ox

        oy = y

        if pressed?(:down) do
          y = y + 1
          facing = 0
          moving = 1
        end

        if pressed?(:up) do
          y = y - 1
          facing = 1
          moving = 1
        end

        bad = 0
        if y < 28, do: bad = 1
        if y > 236, do: bad = 1

        if y > 196 do
          if x < 114, do: bad = 1
          if x > 126, do: bad = 1
        end

        if bad == 1, do: y = oy

        x15 = x + 15
        y15 = y + 15
        ymid = y + 8

        # ── The totems: passable, and they cost. The blink is the mercy.
        # The question is asked only of their feet — the vasque's two
        # tiles, at both of the hero's edges, at the height his own feet
        # are at. Four questions a frame. ──
        hidden = 0

        if blink > 0 do
          blink = blink - 1
          flick = rem(blink, 8)
          if flick < 4, do: hidden = 1
        end

        if blink == 0 do
          if touching?(:moai_base, x, y15) or touching?(:moai_base, x15, y15) or
               touching?(:moai_br, x, y15) or touching?(:moai_br, x15, y15) do
            hearts = hearts - 1
            blink = 90
            noise(:boom)
          end
        end

        # ── The flag at the end of the dock. ──
        if touching?(:flag_top, x, ymid) or touching?(:flag_top, x15, ymid) or
             touching?(:flag_base, x, y15) or touching?(:flag_base, x15, y15),
           do: become(:crowned)

        if hearts == 0, do: become(:sunk)

        # ── The window the pineapples and the slime read. ──
        hxm8 = x - 8
        hxp16 = x + 16
        ym16 = y - 16
        yp16 = y + 16

        # ── The camera, chasing on both axes: the hero owns the middle of
        # the screen, the camera owns the edges, and it stops at the
        # world's rim. ──
        sx = x - cx
        if sx > 84 and cx < 96, do: cx = cx + 1
        if sx < 68 and cx > 0, do: cx = cx - 1
        sy = y - cy
        if sy > 76 and cy < 112, do: cy = cy + 1
        if sy < 60 and cy > 0, do: cy = cy - 1
        scroll(cx, cy)
        sx = x - cx
        sy = y - cy
        sx8 = sx + 8
        sy8 = sy + 8

        # ── The HUD rides in sprites, so the world scrolls under it. ──
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

        # ── Moananas, four quarters and three facings: down, up, and the
        # side — which walks left as a flip and a swap of the columns, so
        # the fourth facing costs no tiles at all. Two frames each,
        # stand and stride, swapped every eighth step. ──
        anim = anim + 1
        if anim == 16, do: anim = 0

        if hidden == 1 do
          sprite(0, x: 0, y: 200, tile: :md1_tl)
          sprite(1, x: 0, y: 200, tile: :md1_tr)
          sprite(2, x: 0, y: 200, tile: :md1_bl)
          sprite(3, x: 0, y: 200, tile: :md1_br)
        else
          if facing == 0 do
            if moving == 0 or anim < 8 do
              sprite(0, x: sx, y: sy, tile: :md1_tl)
              sprite(1, x: sx8, y: sy, tile: :md1_tr)
              sprite(2, x: sx, y: sy8, tile: :md1_bl)
              sprite(3, x: sx8, y: sy8, tile: :md1_br)
            else
              sprite(0, x: sx, y: sy, tile: :md2_tl)
              sprite(1, x: sx8, y: sy, tile: :md2_tr)
              sprite(2, x: sx, y: sy8, tile: :md2_bl)
              sprite(3, x: sx8, y: sy8, tile: :md2_br)
            end
          end

          if facing == 1 do
            if moving == 0 or anim < 8 do
              sprite(0, x: sx, y: sy, tile: :mu1_tl)
              sprite(1, x: sx8, y: sy, tile: :mu1_tr)
              sprite(2, x: sx, y: sy8, tile: :mu1_bl)
              sprite(3, x: sx8, y: sy8, tile: :mu1_br)
            else
              sprite(0, x: sx, y: sy, tile: :mu2_tl)
              sprite(1, x: sx8, y: sy, tile: :mu2_tr)
              sprite(2, x: sx, y: sy8, tile: :mu2_bl)
              sprite(3, x: sx8, y: sy8, tile: :mu2_br)
            end
          end

          if facing == 2 do
            if moving == 0 or anim < 8 do
              sprite(0, x: sx, y: sy, tile: :ms1_tl)
              sprite(1, x: sx8, y: sy, tile: :ms1_tr)
              sprite(2, x: sx, y: sy8, tile: :ms1_bl)
              sprite(3, x: sx8, y: sy8, tile: :ms1_br)
            else
              sprite(0, x: sx, y: sy, tile: :ms2_tl)
              sprite(1, x: sx8, y: sy, tile: :ms2_tr)
              sprite(2, x: sx, y: sy8, tile: :ms2_bl)
              sprite(3, x: sx8, y: sy8, tile: :ms2_br)
            end
          end

          if facing == 3 do
            if moving == 0 or anim < 8 do
              sprite(0, x: sx, y: sy, tile: :ms1_tr, flip: :x)
              sprite(1, x: sx8, y: sy, tile: :ms1_tl, flip: :x)
              sprite(2, x: sx, y: sy8, tile: :ms1_br, flip: :x)
              sprite(3, x: sx8, y: sy8, tile: :ms1_bl, flip: :x)
            else
              sprite(0, x: sx, y: sy, tile: :ms2_tr, flip: :x)
              sprite(1, x: sx8, y: sy, tile: :ms2_tl, flip: :x)
              sprite(2, x: sx, y: sy8, tile: :ms2_br, flip: :x)
              sprite(3, x: sx8, y: sy8, tile: :ms2_bl, flip: :x)
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

  # ── The slime ───────────────────────────────────────────────────────────────
  #
  # SGQ's slime, patrolling the south sand at half the hero's walking pace,
  # squashing against the ground every half-second. It shares the hero's
  # `blink` mercy, so a totem bump and a slime touch draw from the same
  # ninety frames of grace, and it asks no `touching?` at all — its world
  # is the same box test the pineapples use.
  defactor :slime do
    variables swx: 0,
              sdir: 0,
              sgo: 0,
              sstep: 0,
              sbounce: 0,
              spx: 0,
              spy: 0,
              spx8: 0,
              spy8: 0

    every_frame do
      if sgo == 0 do
        sgo = 1
        swx = 96
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
            if swx > 136, do: sdir = 1
          else
            swx = swx - 1
            if swx < 97, do: sdir = 0
          end
        end

        sbounce = sbounce + 1
        if sbounce == 32, do: sbounce = 0

        if blink == 0 do
          if swx > hxm8 and swx < hxp16 and yp16 > 176 and ym16 < 176 do
            hearts = hearts - 1
            blink = 90
            noise(:boom)
          end
        end

        spx = swx - cx
        spy = 176 - cy
        spx8 = spx + 8
        spy8 = spy + 8

        if spx < 153 and spy < 137 do
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

  # ── The pineapples ──────────────────────────────────────────────────────────
  #
  # Six of them, spread over the island in two rows of three, the middle
  # ones nudged a half-tile so the spread reads scattered rather than
  # gridded. Each is a world position and a `taken` flag; the sprite is the
  # position minus the camera, parked once it leaves the glass. `slot` is
  # the hero's scratch cell: a pooled name cannot number a sprite.
  defactor :pineapple, count: 6 do
    variables wx: 0, wy: 0, taken: 0, seeded: 0, px: 0, py: 0, py8: 0

    every_frame do
      if seeded == 0 do
        seeded = 1
        wx = rem(me, 3)
        wx = wx * 64
        wx = wx + 48
        wy = div(me, 3)
        wy = wy * 96
        wy = wy + 64
        if rem(me, 2) == 1, do: wy = wy + 16
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
        py = wy - cy

        if taken == 0 and px < 153 and py < 137 do
          py8 = py + 8
          sprite(slot, x: px, y: py, tile: :pineapple_top)
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
