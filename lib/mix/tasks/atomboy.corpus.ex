defmodule Mix.Tasks.Atomboy.Corpus do
  @shortdoc "Récupère le corpus de vecteurs SingleStepTests/sm83"

  @moduledoc """
  Récupère le corpus SingleStepTests pour le SM83.

      mix atomboy.corpus

  502 fichiers, environ 160 Mo décompressés, un par opcode, ~1 000 vecteurs
  chacun. Clone superficiel — l'historique ne sert à rien ici.

  ## Pourquoi ce corpus plutôt que blargg en premier

  Les ROMs de test de blargg sont des tests d'intégration : elles répondent
  « `cpu_instrs` échoue », pas « `SBC A, (HL)` pose le demi-retenue à l'envers
  quand le carry entre à 1 ». Sur un décodeur en cours d'écriture, cette
  différence se paie en jours.

  SingleStepTests donne, pour chaque opcode, un millier d'états machine
  complets avant/après — registres, drapeaux, mémoire touchée, accès bus. Un
  échec désigne l'opcode et le bit. blargg reste indispensable, mais **après** :
  il couvre ce que les vecteurs unitaires ne voient pas (enchaînements, timers,
  interruptions).

  Le corpus atterrit dans `test/fixtures/sm83/`, ignoré par git : c'est une
  dépendance de test, pas du code du projet.
  """

  use Mix.Task

  @repo "https://github.com/SingleStepTests/sm83.git"
  @dir "test/fixtures/sm83"

  @roms_repo "https://github.com/retrio/gb-test-roms.git"
  @roms_dir "test/fixtures/gb-test-roms"

  @doc "Où vivent les ROMs de test de blargg."
  @spec roms_dir() :: Path.t()
  def roms_dir, do: @roms_dir

  @doc "Les ROMs individuelles de cpu_instrs, présentes sur le disque."
  @spec cpu_instrs_roms() :: [Path.t()]
  def cpu_instrs_roms do
    @roms_dir
    |> Path.join("cpu_instrs/individual/*.gb")
    |> Path.wildcard()
    |> Enum.sort()
  end

  @doc """
  Où vit le corpus.

  Résolu ici plutôt que dans le harnais de test : c'est de l'outillage de build,
  et ça garde `Atomboy.SingleStep` hors de l'application compilée — donc hors du
  packbeam flashé sur l'ESP32.
  """
  @spec dir() :: Path.t()
  def dir, do: @dir

  @doc """
  L'octet qui préfixe la table étendue. Légitimement implémenté, légitimement
  sans fichier de vecteurs.
  """
  @spec prefix_opcode() :: 0xCB
  def prefix_opcode, do: 0xCB

  @doc "Le corpus est-il présent ?"
  @spec available?() :: boolean()
  def available?, do: File.dir?(Path.join(@dir, "v1"))

  @doc """
  Les opcodes couverts par le corpus, sous forme `{prefixe, opcode}`.

  244 des 256 encodages de la table de base ont un fichier. Les douze absents se
  répartissent en deux catégories qu'il ne faut pas confondre :

    * `0xCB` — c'est le **préfixe** de la table étendue, pas une instruction. Il
      sera bien implémenté, sous forme d'un second fetch. Voir `prefix_opcode/0`.
    * Les onze encodages invalides `0xD3`, `0xDB`, `0xDD`, `0xE3`, `0xE4`,
      `0xEB`, `0xEC`, `0xED`, `0xF4`, `0xFC`, `0xFD` — ils n'existent pas sur le
      SM83 et bloquent le CPU. Une clause qui les couvre vient d'une table Z80.

  La liste est lue sur le disque plutôt que codée en dur : une donnée vérifiable
  plutôt qu'une transcription à la main.
  """
  @spec opcodes() :: MapSet.t({nil | :cb, 0..0xFF})
  def opcodes do
    @dir
    |> Path.join("v1/*.json")
    |> Path.wildcard()
    |> MapSet.new(fn path ->
      case Path.basename(path, ".json") do
        "cb " <> hex -> {:cb, String.to_integer(hex, 16)}
        hex -> {nil, String.to_integer(hex, 16)}
      end
    end)
  end

  @impl true
  def run(_args) do
    fetch(dir(), @repo, "vecteurs SingleStepTests (~160 Mo)", "v1")
    fetch(@roms_dir, @roms_repo, "ROMs de test blargg & mooneye", "cpu_instrs")
    Mix.shell().info("Corpus prêt. `mix test` ; blargg : `mix test --include blargg`.")
  end

  defp fetch(dir, repo, label, proof) do
    if File.dir?(Path.join(dir, proof)) do
      Mix.shell().info("#{label} : déjà présent dans #{dir}.")
    else
      File.mkdir_p!(Path.dirname(dir))
      Mix.shell().info("Clonage de #{repo} vers #{dir} — #{label}...")

      case System.cmd("git", ["clone", "--depth", "1", repo, dir], into: IO.stream()) do
        {_, 0} -> :ok
        {_, code} -> Mix.raise("git clone a échoué (code #{code})")
      end
    end
  end
end
