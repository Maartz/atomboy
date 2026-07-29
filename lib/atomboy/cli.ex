defmodule Atomboy.CLI do
  @moduledoc """
  Le point d'entrée de l'exécutable distribué.

  Burrito enveloppe la release (l'app et le BEAM entier) dans un binaire
  unique ; au lancement, cette application démarre, lit les arguments et
  joue. Le `-noinput` qui neutralise le lecteur tty interne du BEAM est
  câblé dans `rel/vm.args.eex` — l'exécutable est correct par construction,
  sans lanceur ni variable d'environnement.

      atomboy zelda.gb
      atomboy pokemon.gbc --palette gris --no-son

  Les arguments arrivent par `:init.get_plain_arguments/0` — la voie qui ne
  dépend pas du module Burrito à l'exécution. Ne démarre qu'en prod : `mix
  test` ne lance pas de partie.
  """

  use Application

  # Synchrone à dessein : le lanceur Burrito démarre le BEAM avec
  # `-s elixir start_cli`, qui s'exécute APRÈS le boot — et interpréterait
  # la ROM passée en argument comme un script Elixir (vécu : il a lu du
  # Tetris comme du code source), puis halterait la VM. En jouant toute la
  # partie dans le start de l'application, on halte avant qu'il ne parle.
  @impl true
  def start(_type, _args) do
    args = :init.get_plain_arguments() |> Enum.map(&List.to_string/1)
    System.halt(main(args))
  end

  @doc "Joue selon les arguments. Rend le code de sortie du processus."
  @spec main([String.t()]) :: non_neg_integer()
  def main(args) do
    case parse(args) do
      {:ok, rom, opts} ->
        {fenetre, opts} = Keyword.pop(opts, :fenetre, false)
        runner = if fenetre, do: Atomboy.Window, else: Atomboy.Play

        case runner.run(rom, opts) do
          :ok ->
            0

          {:error, message} ->
            IO.puts(:stderr, message)
            1
        end

      {:error, message} ->
        IO.puts(:stderr, message)
        2
    end
  end

  @doc """
  La ligne de commande commune à l'exécutable et à `mix atomboy.play` :
  une ROM, et les options de jeu.
  """
  @spec parse([String.t()]) :: {:ok, Path.t(), keyword()} | {:error, String.t()}
  def parse(args) do
    {opts, argv} =
      OptionParser.parse!(args,
        strict: [
          hold: :integer,
          frames: :integer,
          dump: :string,
          son: :boolean,
          palette: :string,
          fenetre: :boolean,
          dmg: :boolean
        ]
      )

    with {:ok, opts} <- palette(opts),
         {:ok, rom} <- rom(argv) do
      {:ok, rom, opts}
    end
  rescue
    e in OptionParser.ParseError -> {:error, Exception.message(e)}
  end

  defp palette(opts) do
    case Keyword.get(opts, :palette) do
      nil -> {:ok, opts}
      "dmg" -> {:ok, Keyword.put(opts, :palette, :dmg)}
      "gris" -> {:ok, Keyword.put(opts, :palette, :gris)}
      autre -> {:error, "palette inconnue : #{autre} (dmg ou gris)"}
    end
  end

  defp rom([rom]) do
    if File.exists?(rom) do
      {:ok, rom}
    else
      {:error, "ROM introuvable : #{rom}"}
    end
  end

  defp rom(_argv) do
    {:error,
     "usage : atomboy <rom.gb> [--fenetre] [--dmg] [--hold N] [--frames N] " <>
       "[--dump f.pgm] [--no-son] [--palette dmg|gris]"}
  end
end
