defmodule Mix.Atomboy.Packbeam do
  @moduledoc """
  Calls the `PackBEAM` of an AtomVM build, whichever generation it is.

  The tool changed its interface between AtomVM 0.7 (November 2025) and current
  main (0.8): the old one takes `PackBEAM <output> <inputs>+` and starts on the
  first module in the archive; the new one works through sub-commands,
  `packbeam create --start <module> <output> <inputs>+`.

  We have to speak both: the firmware flashed onto the ESP32 dates from
  November and its libraries come from the matching build, while the JIT
  experiments happen on main. The generation is detected by asking the tool
  itself — the `help` output of the newer versions announces its sub-commands.
  """

  @doc """
  Builds `output` out of `inputs`, starting on `start_module`.

  On the old CLI, the start module is placed at the head of the archive — that
  was the convention. On the new one, it is passed to `--start`.
  """
  @spec create(Path.t(), Path.t(), [Path.t()], module(), keyword()) :: :ok
  def create(build, output, inputs, start_module, options \\ []) do
    packbeam = Path.join(build, "tools/packbeam/PackBEAM")

    unless File.regular?(packbeam) do
      Mix.raise("PackBEAM not found: #{packbeam}")
    end

    File.rm(output)

    # The name the VM knows: "Elixir.Atomboy.AtomVM.Main", not the abbreviated
    # form inspect/1 gives.
    module_name = Atom.to_string(start_module)

    # `--prune` (keep only the transitive closure of the start module) exists
    # only on the sub-command CLI; the old one packs everything, too bad for it.
    prune = if options[:prune], do: ["--prune"], else: []

    args =
      if subcommand_cli?(packbeam) do
        ["create" | prune] ++ ["--start", module_name, output | inputs]
      else
        [output | order_entry_first(inputs, module_name)]
      end

    case System.cmd(packbeam, args, stderr_to_stdout: true) do
      {_out, 0} ->
        # The old CLI exits 0 even when it understood nothing of its arguments:
        # the only proof of a successful pack is the file.
        unless File.regular?(output) do
          Mix.raise("PackBEAM exited 0 but did not produce #{output}")
        end

        :ok

      {out, code} ->
        Mix.raise("PackBEAM failed (code #{code}):\n#{out}")
    end
  end

  defp subcommand_cli?(packbeam) do
    {out, _code} = System.cmd(packbeam, ["help"], stderr_to_stdout: true)
    String.contains?(out, "sub-command")
  end

  defp order_entry_first(inputs, module_name) do
    beam = module_name <> ".beam"
    {entry, rest} = Enum.split_with(inputs, &(Path.basename(&1) == beam))
    entry ++ rest
  end
end
