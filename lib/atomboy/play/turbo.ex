defmodule Atomboy.Play.Turbo do
  @moduledoc """
  Fast forward, and how fast: turbo's speeds and its two grammars.

  Uncapped is the historical behaviour — the frame deadline is suspended
  and the machine runs as fast as the BEAM can, one frame in four reaching
  the screen. A capped level divides the deadline instead: at 4× a frame is
  owed every 4,185 µs rather than every 16,742, and every fourth frame is
  drawn, so the game runs four times faster while the screen keeps its
  ~60 Hz. The sound falls silent at every level: the sample rate is tied to
  the wall clock, and no player survives being handed four seconds of audio
  per second.

  Two grammars reach the same switch. A bare `{:key, :turbo}` toggles — a
  terminal that does not speak the kitty keyboard protocol never reports a
  release, so the only workable hold is a latch. Press and release (the
  shell's `+T`/`-T`, kitty's CSI-u events) engage turbo *while held*.
  `asked/3` reads either grammar against the current state and answers what
  the loop must do — including the refusal the link cable imposes: two
  consoles in turbo drift apart and the serial protocol tears.
  """

  # The loop's frame period — the same 59.7275 Hz the play and server
  # loops pace themselves by.
  @frame_us 16_742
  @speeds [2, 4, 8]

  @typedoc "A capped multiplier, or the suspended deadline of old."
  @type speed :: 2 | 4 | 8 | :uncapped

  @doc "The multipliers a capped turbo accepts."
  @spec speeds() :: [pos_integer()]
  def speeds, do: @speeds

  @doc """
  The speed named by a `--turbo N` flag or by the shell's op byte: 2, 4 or
  8, and `0` (or `:uncapped`) for the suspended deadline. Anything else is
  `:error` — an unlisted multiplier is a typo, not something to round.
  """
  @spec speed(term()) :: {:ok, speed()} | :error
  def speed(:uncapped), do: {:ok, :uncapped}
  def speed(0), do: {:ok, :uncapped}
  def speed(n) when n in @speeds, do: {:ok, n}
  def speed(_other), do: :error

  @doc """
  The microseconds one frame is owed. `:suspended` — uncapped turbo — is
  no deadline at all: the loop carries its own forward and never sleeps.
  """
  @spec frame_us(boolean(), speed()) :: pos_integer() | :suspended
  def frame_us(false, _speed), do: @frame_us
  def frame_us(true, :uncapped), do: :suspended
  def frame_us(true, speed) when speed in @speeds, do: div(@frame_us, speed)

  @doc """
  Whether frame `n` reaches the screen. Rendering is what turbo really
  costs, so a capped level draws one frame per multiplier — the display
  stays at its usual rate while the machine sprints.
  """
  @spec render?(non_neg_integer(), boolean(), speed()) :: boolean()
  def render?(_n, false, _speed), do: true
  def render?(n, true, :uncapped), do: rem(n, 4) == 0
  def render?(n, true, speed) when speed in @speeds, do: rem(n, speed) == 0

  @doc """
  What an event asks of turbo, given where turbo stands and whether the
  link cable is plugged: `:on`, `:off`, `:none` (nothing to do — a held key
  repeating its press) or `:refused`.
  """
  @spec asked(:key | :press | :release, boolean(), boolean()) :: :on | :off | :none | :refused
  def asked(tag, turbo?, linked? \\ false) do
    case wanted(tag, turbo?) do
      :on when linked? -> :refused
      answer -> answer
    end
  end

  defp wanted(:key, turbo?), do: if(turbo?, do: :off, else: :on)
  defp wanted(:press, turbo?), do: if(turbo?, do: :none, else: :on)
  defp wanted(:release, turbo?), do: if(turbo?, do: :off, else: :none)
end
