defmodule Potion.Music do
  @moduledoc """
  A tune, written as a line of text and laid into the cartridge as bytes.

      music :theme, "c4 . e4 . g4 . c5 . . . - -"

      music :theme,
        [lead: "c4 . e4 . g4 .", harmony: "e3 . g3 . c4 .", bass: "c2 . . . g1 . . ."],
        beat: 10, duty: :eighth, gap: 3

  The tokens:

      c4  fs5  as3    a note — letter, optional `s` for the sharp, octave
      .               hold: the note before it goes on sounding
      -               a rest: the channel is silenced
      |               a bar line — ink for the reader, the parser walks past it
      [c4 e4 g4]      a group: its notes packed into one beat, equal slices

  A group is how a melody says pickup notes and triplets without speeding the
  whole tune up. The beat has to divide by the group's size, only the last
  member takes the `gap:` — a triplet is one gesture, slurred inside and
  breathing at the end — and a hold cannot appear inside one.

  And a tune's notation is *evaluated* when the module compiles, so motifs are
  ordinary Elixir:

      @motif "c4 e4 g4 ."
      music :song, [lead: @motif <> " " <> @motif]

  Each token is one beat, and a beat is `beat:` frames — twelve by default, so
  five beats a second. `beat: 6` is twice as fast, and there is no tempo beyond
  that: the console counts frames and so does this.

  ## What the bytes are

  Three per step, and a step is a run of tokens that sound the same:

      <lo>  <hi | trigger>  <frames>      a note
      0x00  0x00            <frames>      a rest
      <..>  <..>            0x00          the end, and the tune loops

  The frequency is worked out here by the console's own formula run backwards
  — `Potion.Compiler` uses the same table for `beep` — so a tune is a
  handful of bytes and no arithmetic at run time.

  ## Why a hold is a longer step and not a repeated one

  Retriggering a note restarts it, which is audible as a stutter rather than a
  held note. So `c4 . . .` is one step of four beats, not four steps of one, and
  the channel is left alone for the whole of it.

  ## Three voices, and the one that is shared

  `lead:` is channel 1, `harmony:` channel 2, `bass:` the wave channel. A tune
  wants notes that sustain — the envelope is a fixed volume that never decays —
  which is the opposite of what `beep` asks of a channel.

  And `beep` is on channel 2, so a sound effect takes the harmony's voice for as
  long as it lasts and the harmony comes back at its next step. That is not a
  clash to be fixed: it is what a Game Boy game sounds like, because the console
  has four channels and a game has more than four things to say. Nothing
  coordinates it — the next note simply writes over the effect.
  """

  @concert 440.0
  @octaves 2..7
  @semitones ~w(c cs d ds e f fs g gs a as b)a

  @notes (for octave <- @octaves,
              {name, index} <- Enum.with_index(@semitones),
              into: %{} do
            midi = (octave + 1) * 12 + index
            hertz = @concert * :math.pow(2, (midi - 69) / 12)
            {:"#{name}#{octave}", 2048 - round(131_072 / hertz)}
          end)
         |> Enum.reject(fn {_name, x} -> x < 0 end)
         |> Map.new()

  # Channel 3 counts its period differently: it steps a 32-sample table where a
  # pulse toggles a duty, so its frequency is 65536/(2048 - x) against the
  # pulse's 131072. Half the number for the same note -- and an octave further
  # down at the bottom, which is why the bass may say `c1` and the lead may not.
  @wave_notes (for octave <- 1..7,
                   {name, index} <- Enum.with_index(@semitones),
                   into: %{} do
                 midi = (octave + 1) * 12 + index
                 hertz = @concert * :math.pow(2, (midi - 69) / 12)
                 {:"#{name}#{octave}", 2048 - round(65_536 / hertz)}
               end)
              |> Enum.reject(fn {_name, x} -> x < 0 end)
              |> Map.new()

  @voices [:lead, :harmony, :bass]

  # The pulse's duty is what fraction of each period the wave is high, and it is
  # the difference between one square-wave instrument and another. Named by the
  # fraction rather than by a mood, because that is what the register holds.
  #
  #     :eighth   12.5%  thin and nasal — the classic Game Boy lead
  #     :quarter  25%    fuller, still bright
  #     :half     50%    the plainest square there is
  #
  # 75% exists and is not here: it is 25% turned inside out and sounds the same.
  @duties %{eighth: 0x00, quarter: 0x40, half: 0x80}

  # How a pulse note carries its volume over time. `:organ` holds full volume
  # until the next note -- what every tune before this option sounded like.
  # `:pluck` starts full and lets the hardware walk it down over about half a
  # second, so a note dies the way a struck string does. The nibble is the
  # starting volume, the low bits the pace; the envelope hardware does the rest
  # and no code runs per frame.
  @envelopes %{organ: 0xF0, pluck: 0xF2}

  @default_beat 12

  @doc """
  Every note that can be named, and the eleven-bit number the console wants.

      iex> Potion.Music.notes()[:a4]
      1750

  1750 is `2048 - 131072/440`. The register counts down to a period rather than
  up to a pitch, which is why an octave up is not twice the number.
  """
  @spec notes() :: %{atom() => 0..2047}
  def notes, do: @notes

  @doc """
  The same, for the wave channel the bass plays on.

      iex> Potion.Music.wave_notes()[:a4]
      1899

  Half the pulse's number for the same note, because the channel counts twice as
  slowly per step — and it reaches `c1`, which the pulse cannot.
  """
  @spec wave_notes() :: %{atom() => 0..2047}
  def wave_notes, do: @wave_notes

  @doc "How many frames a beat lasts when a tune does not say."
  @spec default_beat() :: pos_integer()
  def default_beat, do: @default_beat

  @doc """
  A line of notation into the bytes a cartridge carries.

      iex> Potion.Music.compile!("c4 -", :theme, beat: 4).lead
      <<0x0B, 0x86, 4, 0x00, 0x00, 4, 0x00, 0x00, 0x00>>

  0x0B and the low three bits of 0x86 make 1547, which is `2048 - 131072/261.6`
  — middle C. The 0x80 on top is the trigger.

  The last three bytes are the terminator: the player reads a length of zero and
  goes back to the beginning.
  """
  @spec compile!(String.t() | keyword(), atom(), keyword()) :: %{lead: binary(), bass: binary()}
  def compile!(notation, name, opts \\ [])

  def compile!(notation, name, opts) when is_binary(notation),
    do: compile!([lead: notation], name, opts)

  def compile!(voices, name, opts) when is_list(voices) do
    {beat, voices} = Keyword.pop(voices ++ opts, :beat, @default_beat)
    {gap, voices} = Keyword.pop(voices, :gap, 0)
    {duty, voices} = Keyword.pop(voices, :duty, :half)
    {wobble, voices} = Keyword.pop(voices, :vibrato, :none)
    {envelope, voices} = Keyword.pop(voices, :envelope, :organ)

    beat!(beat, name)
    gap!(gap, beat, name)

    case Keyword.keys(voices) -- @voices do
      [] ->
        :ok

      unknown ->
        raise Potion.CompileError, """
        the tune #{inspect(name)} has a voice called #{unknown |> hd() |> inspect()}.

        There are three: `lead:` on channel 1, `harmony:` on channel 2 and \
        `bass:` on the wave channel, which reaches an octave lower. A tune \
        written as one line of text is the lead alone.
        """
    end

    %{
      lead: voice!(Keyword.get(voices, :lead), name, @notes, beat, gap),
      harmony: voice!(Keyword.get(voices, :harmony), name, @notes, beat, gap),
      bass: voice!(Keyword.get(voices, :bass), name, @wave_notes, beat, gap),
      duty: duty!(duty, name),
      vibrato: vibrato!(wobble, name),
      envelope: envelope!(envelope, name)
    }
  end

  defp duty!(duty, name) do
    case Map.fetch(@duties, duty) do
      {:ok, bits} ->
        bits

      :error ->
        raise Potion.CompileError, """
        the tune #{inspect(name)} asks for a duty of #{inspect(duty)}.

        There are three: #{@duties |> Map.keys() |> Enum.sort() |> Enum.map_join(", ", &inspect/1)} \
        — the fraction of each period the square wave is high, and so which \
        instrument the lead sounds like. It does not reach the bass, which is not \
        a square.
        """
    end
  end

  # A wobble is named and not measured, and the reason is in `Potion.Runtime`:
  # the register holds a period, so the same deviation is a different interval at
  # every note. A number would mean something else on each one.
  defp vibrato!(wobble, _name) when wobble in [:none, :gentle, :deep], do: wobble

  defp vibrato!(wobble, name) do
    raise Potion.CompileError, """
    the tune #{inspect(name)} asks for a vibrato of #{inspect(wobble)}.

    There are three: `:none`, `:gentle` and `:deep`. It reaches the two pulse \
    voices and not the bass — down there the same deviation is inaudible, and one \
    deep enough to hear would be a siren on the lead.
    """
  end

  defp envelope!(envelope, name) do
    case Map.fetch(@envelopes, envelope) do
      {:ok, byte} ->
        byte

      :error ->
        raise Potion.CompileError, """
        the tune #{inspect(name)} asks for an envelope of #{inspect(envelope)}.

        There are two: `:organ` holds a note at full volume until the next one, \
        and `:pluck` lets it die away on its own, the way a struck string does. \
        It shapes the two pulse voices; the bass has no envelope hardware.
        """
    end
  end

  defp gap!(gap, beat, name) do
    unless is_integer(gap) and gap >= 0 and gap < beat do
      raise Potion.CompileError, """
      the tune #{inspect(name)} asks for a gap of #{inspect(gap)} against a beat of #{beat}.

      A gap is how many frames of silence end every note, and it has to leave \
      something of the shortest one — so it runs from 0 to #{beat - 1}. Two or \
      three is the difference between notes that run into each other and notes \
      that have a rhythm.
      """
    end
  end

  defp beat!(beat, name) do
    unless is_integer(beat) and beat in 1..255 do
      raise Potion.CompileError, """
      the tune #{inspect(name)} asks for a beat of #{inspect(beat)}.

      A beat is a count of frames and the console counts them in a byte, so it \
      runs from 1 to 255 — a fifth of a second is 12, and a whole second is 60.
      """
    end
  end

  defp voice!(nil, _name, _notes, _beat, _gap), do: <<>>

  defp voice!(notation, name, notes, beat, gap) do
    notation
    |> String.replace("[", " [ ")
    |> String.replace("]", " ] ")
    |> String.split()
    # A bar line is ink, not sound: it exists so the three voices can be
    # written in columns that line up, and the parser walks past it.
    |> Enum.reject(&(&1 == "|"))
    |> steps!(name, beat, notes)
    |> Enum.flat_map(&articulate(&1, gap, name))
    |> Enum.map_join(fn {x, frames} -> step(x, frames) end)
    |> Kernel.<>(<<0x00, 0x00, 0x00>>)
  end

  # The gap is cut here rather than played: a note of ten frames with a gap of
  # two becomes a note of eight and a rest of two, and the kernel plays what it
  # always played. Nothing new runs, and a tune costs twice the bytes it did.
  #
  # It goes on the *note* and not on the beat, so a held note gives up the same
  # two frames a short one does -- which is what an instrument does, and what
  # makes a long note read as long rather than as four short ones. Inside a
  # group only the last member takes it, which is why steps carry the flag.
  defp articulate({x, frames, _}, 0, _name), do: [{x, frames}]
  defp articulate({:rest, frames, _}, _gap, _name), do: [{:rest, frames}]
  defp articulate({x, frames, false}, _gap, _name), do: [{x, frames}]

  defp articulate({_x, frames, true}, gap, name) when frames - gap < 1 do
    raise Potion.CompileError, """
    the tune #{inspect(name)} has a gap of #{gap} on a note #{frames} frames long.

    Nothing of the note would be left. Grouped notes are slices of one beat, so \
    a gap that fits the beat can still swallow a slice -- shorten the gap or \
    widen the beat.
    """
  end

  defp articulate({x, frames, true}, gap, _name), do: [{x, frames - gap}, {:rest, gap}]

  # Tokens into steps of {sound, frames, articulate?}. A hold lengthens the
  # step before it rather than making a new one, and a hold with nothing before
  # it is a mistake worth naming: it reads as a rest and is not one.
  #
  # `[c4 e4 g4]` packs its members into one beat -- the pickup notes and
  # triplets a melody is phrased with, which a rigid grid cannot say without
  # speeding the whole tune up. The members become ordinary steps of beat/n
  # frames each, so the kernel plays them the way it plays everything; only the
  # last one takes the gap, because a triplet is one gesture -- slurred inside,
  # breathing at the end.
  defp steps!(tokens, name, beat, notes) do
    {steps, group} =
      Enum.reduce(tokens, {[], nil}, fn token, {steps, group} ->
        case {token, group} do
          {"[", nil} ->
            {steps, []}

          {"[", _members} ->
            raise Potion.CompileError, """
            the tune #{inspect(name)} opens a group inside a group.

            A group packs notes into one beat, and a beat has no smaller beat \
            inside it to pack into.
            """

          {"]", nil} ->
            raise Potion.CompileError,
                  "the tune #{inspect(name)} closes a group it never opened."

          {"]", []} ->
            raise Potion.CompileError, """
            the tune #{inspect(name)} has an empty group.

            `[ ]` would be a beat of nothing, which is what `-` already says.
            """

          {"]", members} ->
            {burst(Enum.reverse(members), beat, name) ++ steps, nil}

          {".", nil} ->
            case steps do
              [] ->
                raise Potion.CompileError, """
                the tune #{inspect(name)} opens with `.`, which holds the note before it.

                There is nothing before it. A silence at the start is `-`.
                """

              [{x, frames, articulate?} | rest] ->
                {[{x, frames + beat, articulate?} | rest], nil}
            end

          {".", _members} ->
            raise Potion.CompileError, """
            the tune #{inspect(name)} holds a note inside a group.

            A group's members are equal slices of one beat; to lengthen one, \
            name it again.
            """

          {"-", nil} ->
            {[{:rest, beat, false} | steps], nil}

          {"-", members} ->
            {steps, [:rest | members]}

          {note, nil} ->
            {[{note!(note, name, notes), beat, true} | steps], nil}

          {note, members} ->
            {steps, [note!(note, name, notes) | members]}
        end
      end)

    if group != nil do
      raise Potion.CompileError,
            "the tune #{inspect(name)} opens a group and never closes it."
    end

    steps |> Enum.reverse() |> Enum.map(&fits!(&1, name))
  end

  # One group into its slices. The beat has to divide evenly, and refusing the
  # remainder beats rounding it: a lost frame per group is a tune that drifts
  # against its own bass, slowly enough that nobody suspects the notation.
  defp burst(members, beat, name) do
    count = length(members)

    if rem(beat, count) != 0 do
      raise Potion.CompileError, """
      the tune #{inspect(name)} packs #{count} notes into a beat of #{beat} frames.

      #{beat} does not divide by #{count}, and a group's members are equal \
      slices. Beats that divide: #{beat_suggestions(count)}.
      """
    end

    slice = div(beat, count)
    last = count - 1

    members
    |> Enum.with_index()
    |> Enum.map(fn
      {:rest, _index} -> {:rest, slice, false}
      {x, ^last} -> {x, slice, true}
      {x, _index} -> {x, slice, false}
    end)
    |> Enum.reverse()
  end

  defp beat_suggestions(count) do
    1..20 |> Enum.map(&(&1 * count)) |> Enum.filter(&(&1 in 6..30)) |> Enum.join(", ")
  end

  defp note!(token, name, notes) do
    case Map.fetch(notes, String.to_atom(token)) do
      {:ok, x} ->
        x

      :error ->
        raise Potion.CompileError, """
        the tune #{inspect(name)} names #{inspect(token)}, which is not a note.

        A note is a letter, an optional `s` for the sharp, and an octave: `c2` \
        up to `b7`, so `a4` is concert A and `fs5` the F sharp above the treble \
        staff. `-` is a rest, `.` holds the note before it, `|` is a bar line \
        the parser walks past, and `[c4 e4 g4]` packs notes into one beat.

        Below C2 the console cannot help: its register counts down to a period, \
        and under about 64 Hz the number it would need is negative.
        """
    end
  end

  # A step's length is one byte, and a zero is the terminator, so 255 is the
  # ceiling and 0 cannot happen.
  defp fits!({_x, frames, _articulate?}, name) when frames > 255 do
    raise Potion.CompileError, """
    the tune #{inspect(name)} holds a note for #{frames} frames, and a step lasts \
    at most 255.

    That is four seconds. Break it into two by naming the note again — the ear \
    hears a retrigger, so a note this long is usually two anyway.
    """
  end

  defp fits!(step, _name), do: step

  defp step(:rest, frames), do: <<0x00, 0x00, frames>>

  defp step(x, frames) do
    import Bitwise
    <<band(x, 0xFF), bor(0x80, bsr(x, 8)), frames>>
  end
end
