defmodule Mix.Atomboy.Packbeam do
  @moduledoc """
  Appelle le `PackBEAM` d'un build AtomVM, quelle qu'en soit la génération.

  L'outil a changé d'interface entre AtomVM 0.7 (novembre 2025) et le main
  actuel (0.8) : l'ancien prend `PackBEAM <sortie> <entrées>+` et démarre sur le
  premier module de l'archive ; le nouveau fonctionne par sous-commandes,
  `packbeam create --start <module> <sortie> <entrées>+`.

  On doit parler aux deux : le firmware flashé sur l'ESP32 date de novembre et
  ses bibliothèques viennent du build assorti, tandis que les expériences JIT
  se font sur main. La génération est détectée en interrogeant l'outil
  lui-même — la sortie de `help` des nouvelles versions annonce ses
  sous-commandes.
  """

  @doc """
  Construit `output` à partir de `inputs`, démarrage sur `start_module`.

  Sur l'ancienne CLI, le module de démarrage est placé en tête d'archive —
  c'était la convention. Sur la nouvelle, il est passé à `--start`.
  """
  @spec create(Path.t(), Path.t(), [Path.t()], module(), keyword()) :: :ok
  def create(build, output, inputs, start_module, options \\ []) do
    packbeam = Path.join(build, "tools/packbeam/PackBEAM")

    unless File.regular?(packbeam) do
      Mix.raise("PackBEAM introuvable : #{packbeam}")
    end

    File.rm(output)

    # Le nom que le VM connaît : "Elixir.Atomboy.AtomVM.Main", pas la forme
    # abrégée d'inspect/1.
    module_name = Atom.to_string(start_module)

    # `--prune` (garder la seule fermeture transitive du module de départ)
    # n'existe que sur la CLI à sous-commandes ; l'ancienne empaquette tout,
    # tant pis pour elle.
    prune = if options[:prune], do: ["--prune"], else: []

    args =
      if subcommand_cli?(packbeam) do
        ["create" | prune] ++ ["--start", module_name, output | inputs]
      else
        [output | order_entry_first(inputs, module_name)]
      end

    case System.cmd(packbeam, args, stderr_to_stdout: true) do
      {_out, 0} ->
        # L'ancienne CLI sort en 0 même quand elle n'a rien compris à ses
        # arguments : la seule preuve d'un empaquetage est le fichier.
        unless File.regular?(output) do
          Mix.raise("PackBEAM est sorti en 0 mais n'a pas produit #{output}")
        end

        :ok

      {out, code} ->
        Mix.raise("PackBEAM a échoué (code #{code}) :\n#{out}")
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
