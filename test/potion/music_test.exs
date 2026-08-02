defmodule Potion.MusicTest do
  use ExUnit.Case, async: true

  doctest Potion.Music

  alias Potion.Music

  # Three bytes a step and three bytes of terminator, so the byte count is what
  # says how many steps a line of notation became — and that is the whole of
  # what holds do: they lengthen a step instead of making one.
  defp steps(bytes), do: div(byte_size(bytes), 3) - 1

  describe "the notation" do
    test "one token is one step" do
      assert steps(Music.compile!("c4 e4 g4", :t)) == 3
    end

    test "a hold lengthens the step before it rather than repeating it" do
      held = Music.compile!("c4 . . .", :t, beat: 5)

      assert steps(held) == 1
      assert <<_lo, _hi, frames, _::binary>> = held
      assert frames == 20
    end

    # Retriggering a note restarts it, which the ear hears as a stutter rather
    # than a held note. So this is not a nicety of the notation: four steps of
    # `c4` and one step of four beats are different sounds.
    test "a repeated note is not the same as a held one" do
      assert steps(Music.compile!("c4 c4 c4 c4", :t)) == 4
      assert steps(Music.compile!("c4 . . .", :t)) == 1
    end

    test "a rest carries no trigger, which is what makes it silence" do
      <<_lo, hi, _frames, _::binary>> = Music.compile!("-", :t)
      assert hi == 0x00
    end

    test "a note carries the trigger bit and the console's own number" do
      <<lo, hi, _frames, _::binary>> = Music.compile!("a4", :t)

      assert lo + (hi - 0x80) * 256 == Music.notes()[:a4]
      assert Bitwise.band(hi, 0x80) == 0x80
    end

    test "it ends with a length of zero, which is what sends the tune round again" do
      bytes = Music.compile!("c4", :t)
      assert binary_part(bytes, byte_size(bytes) - 3, 3) == <<0x00, 0x00, 0x00>>
    end

    test "the beat is a count of frames, and the default is stated once" do
      <<_lo, _hi, frames, _::binary>> = Music.compile!("c4", :t)
      assert frames == Music.default_beat()

      <<_lo, _hi, quick, _::binary>> = Music.compile!("c4", :t, beat: 3)
      assert quick == 3
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
        Music.compile!(". c4", :t)
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
