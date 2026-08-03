# Moananas Island — the title screen, and the door into it.
#
#     mix run games/moananas.exs
#
# writes `games/moananas.gb`. Play it with `bin/play games/moananas.gb`, or
# hot via `ELIXIR_ERL_OPTIONS="-noinput" mix atomboy.live games/moananas.exs`.
#
# The screen is the reference kind: the hero's portrait on the left — eight
# by ten tiles of him, painted whole by `picture` — the name on the right,
# the island's furniture scattered round (pineapples, a moai, palms, clouds)
# inside a woven border. It fades in from black at boot, and Start fades it
# back to black before the beach appears: a door, not a jump cut.
#
# The game itself — run the beach, collect pineapples, dodge falling moai,
# three hearts — comes next; the beach state is its foundation stone.
defmodule Moananas do
  use Potion

  tiles from: "art/moananas.png",
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
          :heart
        ]

  # Both imported from the concept art by `art/import_moananas.py`: cropped,
  # shrunk to their tile budget, and quantized to the four shades with Bayer
  # dithering -- the dither is what carries an illustration's shading into
  # four colours. The expression survives where a drawing made of geometry
  # never had one.
  picture(:face, from: "art/moananas_face.png")
  picture(:logo, from: "art/moananas_logo.png")

  # ── The screens ─────────────────────────────────────────────────────────────
  #
  # The title is exactly the glass, 20 by 18, framed in the woven border with
  # sand-speckle air inside; the furniture is placed by name, one character a
  # tile. The portrait goes on top of it afterwards, painted by `picture`.

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

  # The beach the fade opens onto: sky, a sand floor, the island's props.
  @beach ([border] ++
            List.duplicate(air.(), 12) ++
            [place.(air.(), [{4, "c"}, {14, "c"}])] ++
            [place.(air.(), [{2, "P"}, {16, "m"}])] ++
            [place.(air.(), [{2, "T"}, {16, "M"}])] ++
            [String.duplicate("s", 20)] ++
            [border])
         |> Enum.join("\n")

  @tiles %{
    ?* => :border,
    ?. => :sand,
    ?s => :sand,
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

  # The island tune: major, bouncy, off-beat — the lead skips through the
  # pentatonic in two-bar calls and answers, the echo skips two steps behind
  # it, and the bass plays the calypso figure, root leaning on the fifth
  # before the beat. One peak (a5), once.
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

  # ── The doorman ─────────────────────────────────────────────────────────────

  defactor :doorman do
    variables veil: 0, leaving: 0, primed: 0, anim: 0

    state :title do
      on_enter do
        fade(3)
        veil = 30
        leaving = 0
        primed = 0
        show(:title_screen)
        picture(:logo, 4, 1)
        picture(:face, 1, 6)
        text(5, 16, "PRESS START")
        play(:island)
      end

      every_frame do
        sprite(0, x: 80, y: 200, tile: :heart)

        # The veil lifts in three steps at boot…
        if veil > 0 do
          veil = veil - 1
          if veil == 20, do: fade(2)
          if veil == 10, do: fade(1)
          if veil == 0, do: fade(0)
        end

        # …and Start pulls it back down — the fondu au noir — before the
        # beach is shown. The door swings closed, then open.
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
        silence()
        show(:beach)
        veil = 30
        text(6, 8, "THE BEACH")
        text(7, 10, "IS NEXT")
      end

      every_frame do
        sprite(0, x: 80, y: 200, tile: :heart)

        if veil > 0 do
          veil = veil - 1
          if veil == 20, do: fade(2)
          if veil == 10, do: fade(1)
          if veil == 0, do: fade(0)
        end

        if pressed?(:start) do
          if primed == 1 and veil == 0, do: become(:title)
        else
          primed = 1
        end
      end
    end
  end
end

path = Path.join(__DIR__, "moananas.gb")
File.write!(path, Moananas.rom())
IO.puts("#{path} — #{byte_size(Moananas.rom())} bytes, aloha.")
