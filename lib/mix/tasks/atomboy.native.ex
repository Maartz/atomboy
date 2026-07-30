defmodule Mix.Tasks.Atomboy.Native do
  @shortdoc "Construit l'interpréteur RV32 et l'exécute sous qemu"

  @moduledoc """
  Le backend natif, vu de la ligne de commande.

      mix atomboy.native            # taille, couverture, et une exécution témoin
      mix atomboy.native --taille   # ne construit que, sans lancer qemu
      mix atomboy.native --fumee    # l'image de fumée, sans interpréteur

  ## Le chiffre à regarder

  Ce chantier existe pour une raison mesurée : sur ESP32-C6, l'émulateur
  plafonne à 12 % du temps réel parce que ~1 Mo d'interpréteur natif AtomVM se
  bat contre 32 Ko d'icache. Un interpréteur SM83 émis directement doit y tenir.
  La ligne « code » ci-dessous est donc le vrai tableau de bord du projet, et
  elle doit rester lisible à chaque étape plutôt qu'être découverte à la fin.
  """

  use Mix.Task

  alias Atomboy.CPU.State
  alias Atomboy.CPU.Table
  alias Atomboy.Native.ALU
  alias Atomboy.Native.Asm
  alias Atomboy.Native.Emit
  alias Atomboy.Native.Image
  alias Atomboy.Native.Interp
  alias Atomboy.Native.Qemu
  alias Atomboy.Native.Run

  @icache 32 * 1024

  @impl true
  def run(argv) do
    Mix.Task.run("compile")

    if "--fumee" in argv, do: fumee(argv), else: interprete(argv)
  end

  defp interprete(argv) do
    memoire = :binary.copy(<<0x00>>, 0x10000)
    image = Interp.image(memoire, %State{}, 1)

    code = image.labels[:table_base]
    couverts = length(Emit.couverture())
    total = length(Table.all())
    alu = Asm.assemble(ALU.routines())

    Mix.shell().info("""
    Couverture : #{couverts}/#{total} opcodes émis (#{pourcent(couverts, total)} %)
    Code       : #{code} octets, soit #{pourcent(code, @icache)} % de l'icache du C6
    ALU        : #{alu.size} octets pour #{routines(alu)} routines, liées à l'interpréteur
    Image      : #{image.size} octets, dont 64 Ko de mémoire émulée
    """)

    unless "--taille" in argv do
      exige_qemu()
      temoin(memoire)
    end
  end

  # Un programme de NOP : PC doit avoir avancé d'exactement un cran par tranche
  # de quatre cycles. C'est le plus petit signe de vie qui prouve que le fetch,
  # la table de saut et la comptabilité des cycles tiennent ensemble.
  defp temoin(memoire) do
    budget = 4000

    case Run.run(memoire, %State{}, budget) do
      {:ok, resultat} ->
        Mix.shell().info(
          "Témoin : #{resultat.cycles} cycles, PC=#{resultat.state.pc}, " <>
            "statut #{resultat.statut}, en #{div(resultat.duration_us, 1000)} ms"
        )

      {:error, raison} ->
        Mix.raise("l'invité n'a rien rendu : #{inspect(raison)}")
    end
  end

  defp fumee(argv) do
    image = Image.smoke()
    Mix.shell().info("Image de fumée : #{image.size} octets")

    unless "--taille" in argv do
      exige_qemu()
      resultat = Qemu.run(image.code)

      case resultat.status do
        :ok -> Mix.shell().info("Sortie série : #{inspect(resultat.serial)}")
        :timeout -> Mix.raise("l'invité n'a pas rendu la main")
      end
    end
  end

  defp exige_qemu do
    unless Qemu.available?() do
      Mix.raise("qemu-system-riscv32 est introuvable — `brew install qemu`")
    end
  end

  defp pourcent(part, tout), do: Float.round(part * 100 / tout, 1)

  # Une routine par étiquette : l'assemblage les a toutes résolues, donc les
  # compter ici évite de tenir une liste en double.
  defp routines(%{labels: labels}) do
    labels |> Map.keys() |> Enum.count(&String.starts_with?(Atom.to_string(&1), "alu_"))
  end
end
