defmodule Atomboy.CLI do
  @moduledoc """
  The entry point of the shipped executable.

  Burrito wraps the release — the app and an entire BEAM — into a single
  binary; on launch this application starts, reads the arguments and
  plays. The `-noinput` that neutralises the BEAM's own tty reader is
  wired into `rel/vm.args.eex` — the executable is correct by
  construction, with no launcher and no environment variable.

      atomboy zelda.gb
      atomboy pokemon.gbc --palette gray --no-sound

  Arguments arrive through `:init.get_plain_arguments/0` — the path that
  does not depend on the Burrito module at runtime. Only starts in prod:
  `mix test` never launches a game.
  """

  use Application

  # Synchronous on purpose: the Burrito launcher boots the BEAM with
  # `-s elixir start_cli`, which runs AFTER boot — and would read the ROM
  # passed as an argument as an Elixir script (lived through: it read
  # Tetris as source code), then halt the VM. By playing the whole game
  # inside the application's start, we halt before it gets to speak.
  @impl true
  def start(_type, _args) do
    # Preload the error formatting modules: the BEAM loads them on demand,
    # and if the extraction cache vanishes mid-game a crash would become
    # unreadable ("DEFAULT FORMATTER CRASHED", lived through) — the real
    # report eaten by the death of the formatter.
    Enum.each([:io_lib_pretty, :io_lib_format, :erl_pp], &:code.ensure_loaded/1)

    args = :init.get_plain_arguments() |> Enum.map(&List.to_string/1)
    System.halt(main(args))
  end

  @doc "Plays according to the arguments. Returns the process exit code."
  @spec main([String.t()]) :: non_neg_integer()
  def main(args) do
    case parse(args) do
      {:ok, rom, opts} ->
        {window, opts} = Keyword.pop(opts, :window, false)
        {server, opts} = Keyword.pop(opts, :server, false)

        runner =
          cond do
            server -> Atomboy.Server
            window -> Atomboy.Window
            true -> Atomboy.Play
          end

        try do
          case runner.run(rom, opts) do
            :ok ->
              0

            {:error, message} ->
              IO.puts(:stderr, message)
              1
          end
        rescue
          e ->
            # The crash report depends on nobody: formatted by our own
            # hand, written to a file AND to stderr — never entrusted to
            # the application controller, whose formatter can die.
            report = Exception.format(:error, e, __STACKTRACE__)
            File.write("atomboy-crash.log", report)

            IO.puts(
              :stderr,
              "\natomboy crashed — report in atomboy-crash.log:\n\n" <> report
            )

            70
        end

      {:error, message} ->
        IO.puts(:stderr, message)
        2
    end
  end

  @doc """
  The command line shared by the executable and `mix atomboy.play`: one
  ROM, and the play options.
  """
  # Legacy aliases: the flags shipped in v0.3.0 were French. They stay
  # accepted, silently mapped, so published docs and muscle memory keep
  # working — but they are aliases, not the vocabulary.
  @alias_legacy %{
    "--fenetre" => "--window",
    "--serveur" => "--server",
    "--ecoute" => "--listen",
    "--lien" => "--link",
    "--sauvegarde" => "--save",
    "--son" => "--sound",
    "--no-son" => "--no-sound",
    "--dump-toutes" => "--dump-every"
  }

  @spec parse([String.t()]) :: {:ok, Path.t(), keyword()} | {:error, String.t()}
  def parse(args) do
    args = Enum.map(args, &Map.get(@alias_legacy, &1, &1))

    {opts, argv} =
      OptionParser.parse!(with_default_port(args),
        strict: [
          hold: :integer,
          frames: :integer,
          dump: :string,
          dump_every: :integer,
          sound: :boolean,
          palette: :string,
          window: :boolean,
          server: :boolean,
          dmg: :boolean,
          listen: :integer,
          link: :string,
          save: :string,
          codes: :string
        ]
      )

    with {:ok, opts} <- palette(opts),
         {:ok, rom} <- rom(argv) do
      {:ok, rom, opts}
    end
  rescue
    e in OptionParser.ParseError -> {:error, Exception.message(e)}
  end

  # A bare "--listen": the default port slips in — the docs promise it.
  defp with_default_port(["--listen" | rest]) do
    case rest do
      [next | _] ->
        case Integer.parse(next) do
          {_, ""} -> ["--listen" | with_default_port(rest)]
          _ -> ["--listen", "#{Atomboy.Link.default_port()}" | with_default_port(rest)]
        end

      [] ->
        ["--listen", "#{Atomboy.Link.default_port()}"]
    end
  end

  defp with_default_port([arg | rest]), do: [arg | with_default_port(rest)]
  defp with_default_port([]), do: []

  defp palette(opts) do
    case Keyword.get(opts, :palette) do
      nil -> {:ok, opts}
      "dmg" -> {:ok, Keyword.put(opts, :palette, :dmg)}
      "gray" -> {:ok, Keyword.put(opts, :palette, :gray)}
      # Legacy value, like the flag aliases above: "gris" shipped first.
      "gris" -> {:ok, Keyword.put(opts, :palette, :gray)}
      other -> {:error, "unknown palette: #{other} (dmg or gray)"}
    end
  end

  defp rom([rom]) do
    if File.exists?(rom) do
      {:ok, rom}
    else
      {:error, "ROM not found: #{rom}"}
    end
  end

  defp rom(_argv) do
    {:error,
     "usage: atomboy <rom.gb> [--window] [--dmg] [--listen [port]] " <>
       "[--link host:port] [--save name] [--hold N] [--frames N] " <>
       "[--dump f.pgm] [--no-sound] [--palette dmg|gray] [--codes 01VVLLHH,…]"}
  end
end
