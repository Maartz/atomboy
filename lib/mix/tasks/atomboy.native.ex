defmodule Mix.Tasks.Atomboy.Native do
  @shortdoc "Construit une image RV32 et l'exécute sous qemu"

  @moduledoc """
  Le backend natif, vu de la ligne de commande.

      mix atomboy.native            # construit l'image de fumée et l'exécute
      mix atomboy.native --taille   # ne fait que construire, et détaille la taille

  ## Pourquoi une tâche, dès maintenant

  Le chiffre qui décidera de tout ce chantier est une taille de code : un
  interpréteur SM83 émis en RV32 tient-il dans les 32 Ko d'icache d'un ESP32-C6,
  face au ~1 Mo d'interpréteur natif d'AtomVM qui l'en empêche aujourd'hui ?
  Cette tâche est l'endroit où ce chiffre se lit, et il vaut mieux qu'elle existe
  dès la première image que le jour où il sera trop tard pour corriger le tir.
  """

  use Mix.Task

  alias Atomboy.Native.Image
  alias Atomboy.Native.Qemu

  @icache 32 * 1024

  @impl true
  def run(argv) do
    Mix.Task.run("compile")

    image = Image.smoke()
    rapport(image)

    unless "--taille" in argv do
      execute(image)
    end
  end

  defp rapport(image) do
    pourcent = Float.round(image.size * 100 / @icache, 2)

    Mix.shell().info("""
    Image : #{image.size} octets, chargée à 0x#{Integer.to_string(Image.base(), 16)}
    Icache du C6 : #{@icache} octets — l'image en occupe #{pourcent} %
    Étiquettes : #{image.labels |> Map.keys() |> Enum.sort() |> Enum.join(", ")}
    """)
  end

  defp execute(image) do
    unless Qemu.available?() do
      Mix.raise("qemu-system-riscv32 est introuvable — `brew install qemu`")
    end

    resultat = Qemu.run(image.code)

    case resultat.status do
      :ok ->
        Mix.shell().info("Sortie série : #{inspect(resultat.serial)}")

        Mix.shell().info(
          "qemu a rendu la main avec #{resultat.exit_status} en #{ms(resultat)} ms"
        )

      :timeout ->
        Mix.raise("l'invité n'a pas rendu la main après #{ms(resultat)} ms")
    end
  end

  defp ms(%{duration_us: us}), do: div(us, 1000)
end
