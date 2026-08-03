# Moananas Island — collect the pineapples, dodge the moai.
#
#     mix run games/moananas.exs
#
# writes `games/moananas.gb`. Play it with `bin/play games/moananas.gb`, or
# hot via `ELIXIR_ERL_OPTIONS="-noinput" mix atomboy.live games/moananas.exs`.
#
# The title is the concept art itself — portrait and bubble logo imported
# through the Bayer dither — and Start fades to black before the beach fades
# up. On the beach: run with the d-pad, catch pineapples (30 wins), and the
# moai falling among them cost a heart each — three hearts and the island
# keeps them. The hero is the SGQ elf's walk cycle, four frames, mirrored to
# face where he runs; the sand is SGQ ground; the big mossy moai watches from
# the shore, dithered to four shades.
defmodule Moananas do
  use Potion

  # The sheet is composed by art/prepare_moananas.py: the hand-drawn island
  # furniture, one SGQ sand tile, then the elf's four 16x16 frames as
  # TL/TR/BL/BR quads.
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

  # Imported from the concept art and the asset shelf by the two importers:
  # dithered pictures, painted whole by the kernel.
  picture(:face, from: "art/moananas_face.png")
  picture(:logo, from: "art/moananas_logo.png")
  picture(:sentinel, from: "art/moananas_moai_deco.png")

  # ── The screens ─────────────────────────────────────────────────────────────

  border = String.duplicate("*", 20)

  air = fn -> "*" <> String.duplicate(".", 18) <> "*" end

  place = fn row, spots ->
    Enum.reduce(spots, row, fn {col, char}, row ->
      {head, tail} = String.split_at(row, col)
      head <> char <> String.slice(tail, 1..-1//1)
    end)
  end

  @title ([border] ++
            List.duplicate(air.(), 6) ++
            [place.(air.(), [{15, "c"}])] ++
            List.duplicate(air.(), 4) ++
            [place.(air.(), [{11, "p"}, {14, "m"}, {17, "P"}])] ++
            [place.(air.(), [{11, "b"}, {14, "M"}, {17, "T"}])] ++
            List.duplicate(air.(), 3) ++
            [border])
         |> Enum.join("\n")

  # The beach: sky with clouds, a palm on the left, two rows of SGQ sand, and
  # room on the right for the sentinel moai the on_enter paints.
  @beach ([border] ++
            [air.()] ++
            [place.(air.(), [{4, "c"}, {14, "c"}])] ++
            List.duplicate(air.(), 10) ++
            [place.(air.(), [{2, "P"}])] ++
            [place.(air.(), [{2, "T"}])] ++
            ["*" <> String.duplicate("f", 18) <> "*"] ++
            ["*" <> String.duplicate("f", 18) <> "*"] ++
            [border])
         |> Enum.join("\n")

  @tiles %{
    ?* => :border,
    ?. => :sand,
    ?f => :beach_sand,
    ?c => :cloud,
    ?p => :pineapple_top,
    ?b => :pineapple_body,
    ?m => :moai_head,
    ?M => :moai_base,
    ?P => :palm_crown,
    ?T => :palm_trunk
  }

  room :title_screen, @title, tiles: @tiles
  room :beach, @beach, tiles: @tiles

  # ── The music ───────────────────────────────────────────────────────────────

  # The island tune: major, bouncy, off-beat — and it never stops, title to
  # beach to game over; the island does not care how you are doing.
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
              x: 72,
              facing: 0,
              moving: 0,
              blink: 0,
              flick: 0,
              hidden: 0,
              hearts: 3,
              score: 0,
              tens: 0,
              units: 0,
              playing: 0,
              hxm8: 0,
              hxp16: 0,
              slot: 0

    state :title do
      on_enter do
        fade(3)
        veil = 30
        leaving = 0
        primed = 0
        playing = 0
        show(:title_screen)
        picture(:logo, 4, 1)
        picture(:face, 1, 6)
        text(5, 16, "PRESS START")
        play(:island)
      end

      every_frame do
        sprite(0, x: 80, y: 200, tile: :heart)
        sprite(1, x: 80, y: 200, tile: :heart)
        sprite(2, x: 80, y: 200, tile: :heart)
        sprite(3, x: 80, y: 200, tile: :heart)

        if veil > 0 do
          veil = veil - 1
          if veil == 20, do: fade(2)
          if veil == 10, do: fade(1)
          if veil == 0, do: fade(0)
        end

        # The fondu au noir: Start pulls the veil down before the beach.
        if leaving > 0 do
          leaving = leaving - 1
          if leaving == 16, do: fade(1)
          if leaving == 8, do: fade(2)
          if leaving == 1, do: fade(3)
          if leaving == 0, do: become(:shore)
        end

        if pressed?(:start) do
          if primed == 1 and leaving == 0 and veil == 0, do: leaving = 24
        else
          primed = 1
        end
      end
    end

    state :shore do
      on_enter do
        show(:beach)
        picture(:sentinel, 14, 10)
        veil = 30
        x = 72
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

        # ── Running. Two pixels a frame, walls at the border. ──
        moving = 0

        if pressed?(:right) do
          x = x + 2
          facing = 0
          moving = 1
        end

        if pressed?(:left) do
          x = x - 2
          facing = 1
          moving = 1
        end

        if x < 8, do: x = 8
        if x > 136, do: x = 136

        # The catch window the drops read: one byte each side of the body.
        hxm8 = x - 8
        hxp16 = x + 16

        # ── The scoreboard: two digits and three hearts, redrawn every
        # frame — cheaper than remembering what changed. ──
        tens = div(score, 10)
        units = rem(score, 10)
        background(1, 1, digit: tens)
        background(2, 1, digit: units)

        if hearts > 0, do: background(14, 1, tile: :heart), else: background(14, 1, tile: :sand)
        if hearts > 1, do: background(16, 1, tile: :heart), else: background(16, 1, tile: :sand)
        if hearts > 2, do: background(18, 1, tile: :heart), else: background(18, 1, tile: :sand)

        # ── The blink: hit, the hero flickers and cannot be hit again. ──
        hidden = 0

        if blink > 0 do
          blink = blink - 1
          flick = rem(blink, 8)
          if flick < 4, do: hidden = 1
        end

        # ── The verdicts. ──
        if hearts == 0, do: become(:sunk)
        if score > 29, do: become(:crowned)

        # ── The elf, four quarters, walk cycle on the ground. ──
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
              sprite(0, x: x, y: 104, tile: :m1_tl)
              sprite(1, x: x, y: 104, tile: :m1_tr)
              sprite(2, x: x, y: 112, tile: :m1_bl)
              sprite(3, x: x, y: 112, tile: :m1_br)
            else
              sprite(0, x: x, y: 104, tile: :m1_tr, flip: :x)
              sprite(1, x: x, y: 104, tile: :m1_tl, flip: :x)
              sprite(2, x: x, y: 112, tile: :m1_br, flip: :x)
              sprite(3, x: x, y: 112, tile: :m1_bl, flip: :x)
            end
          else
            if facing == 0 do
              sprite(0, x: x, y: 104, tile: :m3_tl)
              sprite(1, x: x, y: 104, tile: :m3_tr)
              sprite(2, x: x, y: 112, tile: :m3_bl)
              sprite(3, x: x, y: 112, tile: :m3_br)
            else
              sprite(0, x: x, y: 104, tile: :m3_tr, flip: :x)
              sprite(1, x: x, y: 104, tile: :m3_tl, flip: :x)
              sprite(2, x: x, y: 112, tile: :m3_br, flip: :x)
              sprite(3, x: x, y: 112, tile: :m3_bl, flip: :x)
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

  # ── The sky's opinion ───────────────────────────────────────────────────────
  #
  # Four falling things in one pool: the first two are pineapples, the other
  # two moai — `me` is the kind. Each falls, is caught or lands, and returns
  # to the top at a column the island picks at random. The fall quickens as
  # the score grows: the division earns its keep.
  # `slot` lives in the hero's cells on purpose: the pool rewrites its own
  # names into arrays indexed by `me`, and a sprite's entry number must be a
  # plain cell. Instances run one after another, so sharing one scratch cell
  # is safe.
  defactor :drop, count: 4 do
    variables dy: 200, dx: 40, dy8: 0, spd: 1, wait: 60

    every_frame do
      slot = me * 2
      slot = slot + 4

      if playing == 0 do
        wait = 30
        dy = 200
        sprite(slot, x: 0, y: 200, tile: :moai_head)
        slot = slot + 1
        sprite(slot, x: 0, y: 200, tile: :moai_head)
      else
        # Waiting in the wings: parked, counting down to the drop.
        if wait > 0 do
          wait = wait - 1

          if wait == 1 do
            dy = 16
            dx = random(128)
            dx = dx + 10
          end

          sprite(slot, x: 0, y: 200, tile: :moai_head)
          slot = slot + 1
          sprite(slot, x: 0, y: 200, tile: :moai_head)
        else
          spd = div(score, 8)
          spd = spd + 1
          if spd > 3, do: spd = 3
          dy = dy + spd

          # Caught, or landed? The hero's window was computed this frame.
          if dy > 90 and dy < 112 and dx > hxm8 and dx < hxp16 do
            if me < 2 do
              score = score + 1
              beep(:c6)
            else
              if blink == 0 do
                hearts = hearts - 1
                blink = 90
                noise(:boom)
              end
            end

            dy = 200
            wait = random(64)
            wait = wait + 20
          end

          if dy > 103 do
            dy = 200
            wait = random(64)
            wait = wait + 20
          end

          dy8 = dy + 8

          if me < 2 do
            sprite(slot, x: dx, y: dy, tile: :pineapple_top)
            slot = slot + 1
            sprite(slot, x: dx, y: dy8, tile: :pineapple_body)
          else
            sprite(slot, x: dx, y: dy, tile: :moai_head)
            slot = slot + 1
            sprite(slot, x: dx, y: dy8, tile: :moai_base)
          end
        end
      end
    end
  end
end

path = Path.join(__DIR__, "moananas.gb")
File.write!(path, Moananas.rom())
IO.puts("#{path} — #{byte_size(Moananas.rom())} bytes, aloha.")
