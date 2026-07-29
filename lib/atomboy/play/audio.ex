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

  @rate 32_768
  # L'avance entretenue sur le lecteur : ~63 ms — la marge qui absorbe la
  # gigue d'une frame lente sans que le tampon ne touche le fond.
  @lead 2048
  # Un retard au-delà d'une demi-seconde (pause, blocage) ne se rattrape
  # pas en rafale : on recale l'horloge.
  @max_burst div(@rate, 2)

  defstruct [:port, :t0, sent: 0]

  @type t :: %__MODULE__{}

  @doc "Ouvre le lecteur, ou `nil` sans ffplay."
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
  La frame de son, asservie à l'horloge murale : produit exactement ce que
  le temps réel écoulé exige — que la boucle de jeu tourne à 58 ou 60 fps,
  le flux vise 32 768 échantillons/s et le tampon d'ffplay ne meurt jamais
  de faim. Sans lecteur, jette les déclenchements ; un lecteur disparu
  coupe le son sans arrêter la partie.
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
  Ce que l'horloge murale exige maintenant : `{audio, n}` — l'état avancé
  et le nombre d'échantillons dus. Le cœur anti-famine, partagé entre le
  flux ffplay et le mode serveur (qui pousse le PCM ailleurs).
  """
  @spec cadence(%{t0: integer(), sent: non_neg_integer()}) ::
          {%{t0: integer(), sent: non_neg_integer()}, non_neg_integer()}
  def cadence(audio) do
    now = System.monotonic_time(:microsecond)
    due = div((now - audio.t0) * @rate, 1_000_000) + @lead

    case due - audio.sent do
      n when n > @max_burst ->
        # Recaler : t0 tel que le dû retombe à l'avance nominale.
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

  @doc "Referme le tuyau — ffplay sort sur la fin de flux."
  @spec close(t() | nil) :: :ok
  def close(nil), do: :ok

  def close(%__MODULE__{port: port}) do
    Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end
end
