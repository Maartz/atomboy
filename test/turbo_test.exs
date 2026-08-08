defmodule Atomboy.Play.TurboTest do
  use ExUnit.Case, async: true

  alias Atomboy.Play.Turbo

  # The frame period both loops pace themselves by.
  @frame_us 16_742

  describe "the deadline" do
    test "outside turbo a frame is always owed its whole period" do
      for speed <- [:uncapped, 2, 4, 8] do
        assert Turbo.frame_us(false, speed) == @frame_us
      end
    end

    test "uncapped turbo suspends the deadline" do
      assert Turbo.frame_us(true, :uncapped) == :suspended
    end

    test "a capped turbo divides the period by the multiplier" do
      assert Turbo.frame_us(true, 2) == div(@frame_us, 2)
      assert Turbo.frame_us(true, 4) == div(@frame_us, 4)
      assert Turbo.frame_us(true, 8) == div(@frame_us, 8)
    end

    test "the periods shrink as the speed grows" do
      periods = Enum.map([2, 4, 8], &Turbo.frame_us(true, &1))

      assert periods == Enum.sort(periods, :desc)
      assert Enum.all?(periods, &(&1 < @frame_us))
    end
  end

  describe "what reaches the screen" do
    test "every frame, outside turbo" do
      assert Enum.all?(0..9, &Turbo.render?(&1, false, :uncapped))
      assert Enum.all?(0..9, &Turbo.render?(&1, false, 8))
    end

    test "one frame in four when the deadline is suspended" do
      assert drawn(0..15, true, :uncapped) == [0, 4, 8, 12]
    end

    test "one frame per speed step when capped — the screen keeps its rate" do
      assert drawn(0..15, true, 2) == [0, 2, 4, 6, 8, 10, 12, 14]
      assert drawn(0..15, true, 4) == [0, 4, 8, 12]
      assert drawn(0..15, true, 8) == [0, 8]
    end
  end

  describe "the speed asked for" do
    test "the three multipliers, and zero for the old suspended deadline" do
      assert Turbo.speed(2) == {:ok, 2}
      assert Turbo.speed(4) == {:ok, 4}
      assert Turbo.speed(8) == {:ok, 8}
      assert Turbo.speed(0) == {:ok, :uncapped}
      assert Turbo.speed(:uncapped) == {:ok, :uncapped}
    end

    test "anything else is refused rather than rounded" do
      assert Turbo.speed(3) == :error
      assert Turbo.speed(1) == :error
      assert Turbo.speed(16) == :error
      assert Turbo.speed(255) == :error
      assert Turbo.speed(:fast) == :error
    end
  end

  describe "the two grammars" do
    test "the legacy keystroke toggles: on, then off" do
      assert follow([:key]) == true
      assert follow([:key, :key]) == false
      assert follow([:key, :key, :key]) == true
    end

    test "press engages and release lets go — held, not latched" do
      assert follow([:press]) == true
      assert follow([:press, :release]) == false
    end

    test "a held key repeating its press changes nothing" do
      assert follow([:press, :press, :press]) == true
      assert follow([:press, :press, :release]) == false
    end

    test "a release nobody asked for leaves turbo where it is" do
      assert follow([:release]) == false
      assert follow([:release, :release]) == false
    end

    test "the grammars mix: a latched turbo is let go by a release" do
      assert follow([:key, :release]) == false
      assert follow([:press, :key]) == false
      assert follow([:key, :press]) == true
    end
  end

  describe "the link cable" do
    test "refuses turbo in both grammars" do
      assert fold([:key], true) == {false, [:refused]}
      assert fold([:press], true) == {false, [:refused]}
    end

    test "refuses it as often as it is asked for" do
      assert fold([:key, :press], true) == {false, [:refused, :refused]}
    end

    test "never refuses letting go" do
      assert fold([:release], true) == {false, []}
    end
  end

  defp drawn(frames, turbo?, speed),
    do: Enum.filter(frames, &Turbo.render?(&1, turbo?, speed))

  # The loops read `asked/3` and then throw the switch; the fold does the
  # same, and keeps the refusals the player would have seen as a note.
  defp fold(events, linked? \\ false) do
    Enum.reduce(events, {false, []}, fn tag, {turbo?, refusals} ->
      case Turbo.asked(tag, turbo?, linked?) do
        :on -> {true, refusals}
        :off -> {false, refusals}
        :none -> {turbo?, refusals}
        :refused -> {turbo?, [:refused | refusals]}
      end
    end)
  end

  defp follow(events), do: events |> fold() |> elem(0)
end
