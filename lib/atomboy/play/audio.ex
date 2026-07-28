defmodule Atomboy.Play.Audio do
  @moduledoc """
  La sortie son : un port vers `ffplay`, nourri en PCM brut.

  L'APU produit ses échantillons stéréo s16le frame par frame ; ffplay les
  lit sur son entrée standard et les joue — `-nodisp -v quiet` pour qu'il
  reste invisible et muet sur nos écrans. Production et consommation vont
  toutes deux au temps réel : le tampon du tuyau reste à l'équilibre, la
  latence est celle d'ffplay (~un dixième de seconde).

  Sans ffplay installé, `open/0` rend `nil` et le jeu joue en silence —
  `brew install ffmpeg` pour l'entendre.
  """

  alias Atomboy.APU

  @doc "Ouvre le lecteur, ou `nil` sans ffplay."
  @spec open() :: port() | nil
  def open do
    case System.find_executable("ffplay") do
      nil ->
        nil

      path ->
        Port.open(
          {:spawn_executable, path},
          [
            :binary,
            :use_stdio,
            :exit_status,
            args:
              ~w(-v quiet -nodisp -autoexit -f s16le -ar #{APU.sample_rate()} -ch_layout stereo -)
          ]
        )
    end
  end

  @doc """
  Pousse une frame d'échantillons. `:dead` si le lecteur a disparu —
  le jeu continue alors en silence.
  """
  @spec push(port(), binary()) :: :ok | :dead
  def push(port, pcm) do
    Port.command(port, pcm)
    :ok
  rescue
    ArgumentError -> :dead
  end

  @doc "Referme le tuyau — ffplay sort sur la fin de flux."
  @spec close(port() | nil) :: :ok
  def close(nil), do: :ok

  def close(port) do
    Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end
end
