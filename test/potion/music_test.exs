defmodule Potion.MusicTest do
  use ExUnit.Case, async: true

  doctest Potion.Music

  alias Potion.Music

  # Three bytes a step and three bytes of terminator, so the byte count is what
  # says how many steps a line of notation became — and that is the whole of
  # what holds do: they lengthen a step instead of making one.
  defp steps(bytes), do: div(byte_size(bytes), 3) - 1

  # A tune has two voices now and every assertion below is about one of them, so
  # the lead is taken here rather than at each call.
  defp lead!(notation, name, opts \\ []), do: Music.compile!(notation, name, opts).lead

  describe "the notation" do
    test "one token is one step" do
      assert steps(lead!("c4 e4 g4", :t)) == 3
    end

    test "a hold lengthens the step before it rather than repeating it" do
      held = lead!("c4 . . .", :t, beat: 5)

      assert steps(held) == 1
      assert <<_lo, _hi, frames, _::binary>> = held
      assert frames == 20
    end

    # Retriggering a note restarts it, which the ear hears as a stutter rather
    # than a held note. So this is not a nicety of the notation: four steps of
    # `c4` and one step of four beats are different sounds.
    test "a repeated note is not the same as a held one" do
      assert steps(lead!("c4 c4 c4 c4", :t)) == 4
      assert steps(lead!("c4 . . .", :t)) == 1
    end

    test "a rest carries no trigger, which is what makes it silence" do
      <<_lo, hi, _frames, _::binary>> = lead!("-", :t)
      assert hi == 0x00
    end

    test "a note carries the trigger bit and the console's own number" do
      <<lo, hi, _frames, _::binary>> = lead!("a4", :t)

      assert lo + (hi - 0x80) * 256 == Music.notes()[:a4]
      assert Bitwise.band(hi, 0x80) == 0x80
    end

    test "it ends with a length of zero, which is what sends the tune round again" do
      bytes = lead!("c4", :t)
      assert binary_part(bytes, byte_size(bytes) - 3, 3) == <<0x00, 0x00, 0x00>>
    end

    test "the beat is a count of frames, and the default is stated once" do
      <<_lo, _hi, frames, _::binary>> = lead!("c4", :t)
      assert frames == Music.default_beat()

      <<_lo, _hi, quick, _::binary>> = lead!("c4", :t, beat: 3)
      assert quick == 3
    end
  end

  describe "the second voice" do
    # The wave channel counts its period twice as slowly, so the same note is a
    # different number there. A bass compiled against the lead's table would be
    # an octave out and nothing would say so.
    test "the bass is written against the wave channel's own numbers" do
      %{lead: lead, bass: bass} = Music.compile!([lead: "a4", bass: "a4"], :t)

      <<lo, hi, _f, _::binary>> = lead
      <<blo, bhi, _bf, _::binary>> = bass

      assert lo + (hi - 0x80) * 256 == Music.notes()[:a4]
      assert blo + (bhi - 0x80) * 256 == Music.wave_notes()[:a4]
      refute lead == bass
    end

    # And it reaches an octave lower, which is the whole reason a bass goes
    # there: the pulse's number for c1 would be negative.
    test "the bass can name notes the lead cannot" do
      assert Music.wave_notes()[:c1]
      refute Music.notes()[:c1]

      assert %{bass: bass} = Music.compile!([bass: "c1"], :t)
      assert byte_size(bass) == 6
    end

    test "a tune written as one line is the lead alone" do
      assert %{lead: lead, bass: <<>>} = Music.compile!("c4", :t)
      assert byte_size(lead) == 6
    end

    test "a voice nobody has heard of is refused, with the two there are" do
      assert_raise Potion.CompileError, ~r/voice called :drums.*`lead:`.*`bass:`/s, fn ->
        Music.compile!([lead: "c4", drums: "c4"], :t)
      end
    end
  end

  describe "the shape of a note" do
    # The gap is cut at compile time: a note becomes a shorter note and a rest,
    # so the kernel plays what it always played and nothing new runs.
    test "a gap turns one note into a note and a silence" do
      assert steps(lead!("c4", :t, beat: 10)) == 1
      assert steps(lead!("c4", :t, beat: 10, gap: 3)) == 2

      <<_lo, _hi, sounding, 0x00, 0x00, silent, _::binary>> = lead!("c4", :t, beat: 10, gap: 3)

      assert sounding == 7
      assert silent == 3
    end

    # A rest is already silence; giving it a gap would only make it two.
    test "a rest is left alone" do
      assert steps(lead!("-", :t, beat: 10, gap: 3)) == 1
    end

    # The gap goes on the note, not on the beat. A note held four beats gives up
    # the same three frames a short one does -- which is what an instrument does,
    # and what makes a long note read as long rather than as four short ones.
    test "a held note gives up the same three frames a short one does" do
      <<_lo, _hi, sounding, 0x00, 0x00, silent, _::binary>> =
        lead!("c4 . . .", :t, beat: 10, gap: 3)

      assert sounding == 37
      assert silent == 3
    end

    test "a gap that would leave nothing of the shortest note is refused" do
      assert_raise Potion.CompileError, ~r/gap of 10 against a beat of 10.*0 to 9/s, fn ->
        Music.compile!("c4", :t, beat: 10, gap: 10)
      end
    end

    test "the duty is the fraction the square is high, and reaches the register" do
      assert Music.compile!("c4", :t, duty: :eighth).duty == 0x00
      assert Music.compile!("c4", :t, duty: :quarter).duty == 0x40
      assert Music.compile!("c4", :t).duty == 0x80
    end

    test "a duty nobody has heard of is refused, with the three" do
      assert_raise Potion.CompileError, ~r/duty of :fat.*:eighth, :half, :quarter/s, fn ->
        Music.compile!("c4", :t, duty: :fat)
      end
    end
  end

  describe "what it refuses" do
    test "a token that is not a note" do
      assert_raise Potion.CompileError, ~r/names "h4", which is not a note/, fn ->
        Music.compile!("c4 h4", :t)
      end
    end

    # It reads as a rest and is not one, so saying nothing would be the wrong
    # kind of forgiving.
    test "a hold with nothing to hold" do
      assert_raise Potion.CompileError, ~r/opens with `\.`/, fn ->
        lead!(". c4", :t)
      end
    end

    test "a step longer than a byte can count" do
      assert_raise Potion.CompileError, ~r/at most 255/, fn ->
        Music.compile!("c4" <> String.duplicate(" .", 30), :t, beat: 12)
      end
    end

    test "a beat that is not a count of frames" do
      assert_raise Potion.CompileError, ~r/1 to 255/, fn ->
        Music.compile!("c4", :t, beat: 0)
      end
    end
  end
end
