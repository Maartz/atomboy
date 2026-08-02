defmodule Potion.Music do
  @moduledoc """
  A tune, written as a line of text and laid into the cartridge as bytes.

      music :theme, "c4 . e4 . g4 . c5 . . . - -"

  Three kinds of token and nothing else:

      c4  fs5  as3    a note — letter, optional `s` for the sharp, octave
      .               hold: the note before it goes on sounding
      -               a rest: the channel is silenced

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

  That is also why music sits on channel 1 while `beep` sits on channel 2. A
  tune wants a note that sustains — the envelope is set to a fixed volume and
  never decays — and a sound effect wants one that dies on its own. They are
  opposite settings of the same register, so they get a channel each and can
  sound together.
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

  @doc "How many frames a beat lasts when a tune does not say."
  @spec default_beat() :: pos_integer()
  def default_beat, do: @default_beat

  @doc """
  A line of notation into the bytes a cartridge carries.

      iex> Potion.Music.compile!("c4 -", :theme, beat: 4)
      <<0x0B, 0x86, 4, 0x00, 0x00, 4, 0x00, 0x00, 0x00>>

  0x0B and the low three bits of 0x86 make 1547, which is `2048 - 131072/261.6`
  — middle C. The 0x80 on top is the trigger.

  The last three bytes are the terminator: the player reads a length of zero and
  goes back to the beginning.
  """
  @spec compile!(String.t(), atom(), keyword()) :: binary()
  def compile!(notation, name, opts \\ []) do
    beat = Keyword.get(opts, :beat, @default_beat)

    unless is_integer(beat) and beat in 1..255 do
      raise Potion.CompileError, """
      the tune #{inspect(name)} asks for a beat of #{inspect(beat)}.

      A beat is a count of frames and the console counts them in a byte, so it \
      runs from 1 to 255 — a fifth of a second is 12, and a whole second is 60.
      """
    end

    notation
    |> String.split()
    |> steps!(name, beat)
    |> Enum.map_join(fn {x, frames} -> step(x, frames) end)
    |> Kernel.<>(<<0x00, 0x00, 0x00>>)
  end

  # Tokens into runs. A hold lengthens the step before it rather than making a
  # new one, and a hold with nothing before it is a mistake worth naming: it
  # reads as a rest and is not one.
  defp steps!(tokens, name, beat) do
    tokens
    |> Enum.reduce([], fn token, steps ->
      case {token, steps} do
        {".", []} ->
          raise Potion.CompileError, """
          the tune #{inspect(name)} opens with `.`, which holds the note before it.

          There is nothing before it. A silence at the start is `-`.
          """

        {".", [{x, frames} | rest]} ->
          [{x, frames + beat} | rest]

        {"-", steps} ->
          [{:rest, beat} | steps]

        {note, steps} ->
          [{note!(note, name), beat} | steps]
      end
    end)
    |> Enum.reverse()
    |> Enum.map(&fits!(&1, name))
  end

  defp note!(token, name) do
    case Map.fetch(@notes, String.to_atom(token)) do
      {:ok, x} ->
        x

      :error ->
        raise Potion.CompileError, """
        the tune #{inspect(name)} names #{inspect(token)}, which is not a note.

        A note is a letter, an optional `s` for the sharp, and an octave: `c2` \
        up to `b7`, so `a4` is concert A and `fs5` the F sharp above the treble \
        staff. `-` is a rest and `.` holds the note before it.

        Below C2 the console cannot help: its register counts down to a period, \
        and under about 64 Hz the number it would need is negative.
        """
    end
  end

  # A step's length is one byte, and a zero is the terminator, so 255 is the
  # ceiling and 0 cannot happen. Twenty-one holds at the default beat.
  defp fits!({_x, frames}, name) when frames > 255 do
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
