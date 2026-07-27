defmodule Mix.Tasks.Atomboy.Atomvm do
  @shortdoc "Vérifie que le code tourne sous AtomVM (build generic_unix)"

  @moduledoc """
  Le garde-fou AtomVM : empaquette l'application et l'exécute sur le build
  `generic_unix`.

      mix atomboy.atomvm

  ## Pourquoi ce n'est pas la boucle de dev

  Toute l'itération se fait sur OTP standard, où l'on a ExUnit, le tracing et un
  REPL. AtomVM n'implémente qu'un sous-ensemble des instructions BEAM et d'OTP —
  et ce sous-ensemble ne se découvre pas en lisant la doc, qui est en retard sur
  la source.

  Ce que ce check attrape ne se voit pas sur le Mac : une instruction BEAM
  absente de la table d'AtomVM, une fonction d'OTP manquante, une construction
  Elixir qui suppose une bibliothèque standard complète. C'est peu coûteux
  aujourd'hui et très coûteux à la phase 2, quand des semaines de code reposeront
  dessus. À lancer après chaque famille d'opcodes, pas après chaque compilation.

  ## Où est AtomVM

  Le build `generic_unix` est cherché dans `ATOMVM_BUILD`, sinon dans
  `../AtomVM/build` à côté du projet.

  ## Ce qui est empaqueté

  Les modules de l'application, moins les tâches Mix — elles dépendent de Mix,
  qui n'existe pas sous AtomVM, et n'ont rien à faire dans ce qui sera flashé.
  S'y ajoutent `atomvmlib.avm` et `exavmlib.avm`, les bibliothèques standard
  d'AtomVM pour Erlang et Elixir.
  """

  use Mix.Task

  @entry_point Atomboy.AtomVM.Smoke
  @success "smoke_ok"

  @impl true
  def run(_args) do
    Mix.Task.run("compile")

    with {:ok, build} <- locate_atomvm(),
         {:ok, avm} <- pack(build) do
      execute(build, avm)
    else
      {:error, message} -> Mix.raise(message)
    end
  end

  defp locate_atomvm do
    build = System.get_env("ATOMVM_BUILD") || Path.expand("../AtomVM/build", File.cwd!())

    cond do
      not File.regular?(Path.join(build, "src/AtomVM")) ->
        {:error,
         """
         Binaire AtomVM introuvable dans #{build}.

         Indique un autre emplacement avec ATOMVM_BUILD, ou construis le build
         generic_unix :

             cd /chemin/vers/AtomVM && mkdir -p build && cd build
             cmake .. && make -j8 AtomVM PackBEAM atomvmlib exavmlib

         Sur macOS, AtomVM exige MbedTLS 2.x ou 3.x — pas la 4.x que Homebrew
         installe par défaut. Il faut `brew install mbedtls@3` puis configurer
         avec -DMBEDTLS_ROOT_DIR=/opt/homebrew/opt/mbedtls@3.
         """}

      not File.regular?(Path.join(build, "libs/atomvmlib.avm")) ->
        {:error, "atomvmlib.avm absent de #{build} — lance `make atomvmlib exavmlib`."}

      true ->
        {:ok, build}
    end
  end

  defp pack(build) do
    output = Path.join(Mix.Project.build_path(), "atomboy.avm")
    File.rm(output)

    # Le point d'entrée doit venir en premier : AtomVM démarre sur le `start/0`
    # du premier module de l'archive.
    inputs =
      [beam(@entry_point)] ++
        (app_beams() -- [beam(@entry_point)]) ++
        [
          Path.join(build, "libs/atomvmlib.avm"),
          Path.join(build, "libs/exavmlib/lib/exavmlib.avm")
        ]

    case System.cmd(Path.join(build, "tools/packbeam/PackBEAM"), [output | inputs],
           stderr_to_stdout: true
         ) do
      {_output, 0} -> {:ok, output}
      {output, code} -> {:error, "PackBEAM a échoué (code #{code}) :\n#{output}"}
    end
  end

  defp app_beams do
    Mix.Project.compile_path()
    |> Path.join("*.beam")
    |> Path.wildcard()
    |> Enum.reject(&String.starts_with?(Path.basename(&1), "Elixir.Mix.Tasks."))
  end

  defp beam(module), do: Path.join(Mix.Project.compile_path(), "#{module}.beam")

  defp execute(build, avm) do
    {output, code} =
      System.cmd(Path.join(build, "src/AtomVM"), [avm], stderr_to_stdout: true)

    cond do
      code != 0 ->
        Mix.raise("AtomVM est sorti en erreur (code #{code}) :\n#{output}")

      String.contains?(output, @success) ->
        Mix.shell().info("AtomVM : le code se charge et s'exécute.\n\n#{String.trim(output)}")

      true ->
        # Sortie 0 mais pas de marqueur : le programme n'est pas allé au bout.
        # Un `undef` sur une fonction absente d'AtomVM ressemble exactement à ça.
        Mix.raise("""
        AtomVM n'a pas produit le marqueur de succès. Sortie brute :

        #{String.trim(output)}
        """)
    end
  end
end
