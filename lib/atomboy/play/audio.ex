defmodule Atomboy.Play.Audio do
  @moduledoc """
  The sound output: a port to `ffplay`, fed raw PCM.

  The APU produces its s16le stereo samples frame by frame; ffplay reads
  them on its standard input and plays them — `-nodisp -v quiet` so that it
  stays invisible and silent on our screens. Production and consumption
  both run in real time: the pipe's buffer stays at equilibrium, and the
  latency is ffplay's own (~a tenth of a second).

  Without ffplay installed, `open/0` returns `nil` and the game plays in
  silence — `brew install ffmpeg` to hear it.
  """

  alias Atomboy.APU

  @rate 32_768
  # The lead kept over the player: ~63 ms — the margin that absorbs the
  # jitter of one slow frame without letting the buffer hit the bottom.
  @lead 2048
  # A lag beyond half a second (a pause, a stall) is not caught up in a
  # burst: we reset the clock instead.
  @max_burst div(@rate, 2)

  defstruct [:port, :t0, sent: 0]

  @type t :: %__MODULE__{}

  @doc "Opens the player, or `nil` without ffplay."
  @spec open() :: t() | nil
  def open do
    case System.find_executable("ffplay") do
      nil ->
        nil

      path ->
        port =
          Port.open(
            {:spawn_executable, path},
            [
              :binary,
              :use_stdio,
              :exit_status,
              args: ~w(-v quiet -nodisp -autoexit -f s16le -ar #{@rate} -ch_layout stereo -)
            ]
          )

        %__MODULE__{port: port, t0: System.monotonic_time(:microsecond)}
    end
  end

  @doc """
  The sound frame, slaved to the wall clock: produces exactly what the
  elapsed real time demands — whether the game loop runs at 58 or 60 fps,
  the stream aims at 32,768 samples/s and ffplay's buffer never starves.
  Without a player, discards the triggers; a player that has vanished
  silences the sound without stopping the game.
  """
  @spec stream(t() | nil, map(), APU.t()) :: {map(), APU.t(), t() | nil}
  def stream(nil, ram, apu), do: {Map.delete(ram, :apu_triggers), apu, nil}

  def stream(audio, ram, apu) do
    {audio, needed} = cadence(audio)
    {pcm, ram, apu} = APU.samples(ram, apu, needed)

    case push(audio.port, pcm) do
      :ok -> {ram, apu, %{audio | sent: audio.sent + needed}}
      :dead -> {ram, apu, nil}
    end
  end

  @doc """
  What the wall clock demands right now: `{audio, n}` — the advanced state
  and the number of samples owed. The anti-starvation core, shared between
  the ffplay stream and server mode (which pushes the PCM elsewhere).
  """
  @spec cadence(%{t0: integer(), sent: non_neg_integer()}) ::
          {%{t0: integer(), sent: non_neg_integer()}, non_neg_integer()}
  def cadence(audio) do
    now = System.monotonic_time(:microsecond)
    due = div((now - audio.t0) * @rate, 1_000_000) + @lead

    case due - audio.sent do
      n when n > @max_burst ->
        # Reset: pick t0 so that the debt falls back to the nominal lead.
        t0 = now - div((audio.sent + @lead) * 1_000_000, @rate)
        {%{audio | t0: t0}, @lead}

      n ->
        {audio, max(n, 0)}
    end
  end

  defp push(_port, <<>>), do: :ok

  defp push(port, pcm) do
    Port.command(port, pcm)
    :ok
  rescue
    ArgumentError -> :dead
  end

  @doc "Closes the pipe — ffplay exits on end of stream."
  @spec close(t() | nil) :: :ok
  def close(nil), do: :ok

  def close(%__MODULE__{port: port}) do
    Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end
end
