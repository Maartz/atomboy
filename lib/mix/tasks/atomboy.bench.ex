defmodule Mix.Tasks.Atomboy.Bench do
  @shortdoc "Mesure le débit du CPU en instructions par seconde"

  @moduledoc """
  Combien d'instructions Game Boy par seconde, sur cette machine.

      mix atomboy.bench [nombre_d_instructions]

  ## Ce que le chiffre veut dire, et ne veut pas dire

  Le programme mesuré est fait de `LD r, r'` registre à registre : aucun accès
  mémoire hors le fetch d'opcode. C'est délibéré — il s'agit d'isoler le coût de
  la **convention d'appel**, pas celui du backend mémoire.

  Deux conséquences à garder en tête :

    * Le chiffre est un **plafond optimiste**. Les vraies instructions touchent
      la mémoire, manipulent des drapeaux, sautent.
    * Chaque instruction paie quand même une lecture dans la map de
      `Atomboy.Memory.Flat` pour son fetch. Ce coût est identique quelle que
      soit la convention de registres, donc il **comprime** l'écart mesuré entre
      deux conventions : la différence réelle sur la manipulation de registres
      est plus grande que le rapport affiché.

  La cible à garder en tête est **500 000 instructions/s**, le débit soutenu
  d'une DMG à 4,194304 MHz.
  """

  use Mix.Task

  # Toute la plage d'adressage est remplie d'un opcode registre-à-registre, pour
  # que PC avance et reboucle à 0xFFFF sans qu'aucune remise à zéro ne vienne
  # polluer la boucle de mesure.
  @filler 0x41

  @default_count 3_000_000

  @impl true
  def run(argv) do
    Mix.Task.run("compile")

    count =
      case argv do
        [n | _] -> String.to_integer(n)
        [] -> @default_count
      end

    mem = Atomboy.Memory.Flat.new(for addr <- 0..0xFFFF, do: {addr, @filler})
    state = %Atomboy.CPU.State{c: 0x42, h: 0xC0, sp: 0xFFFE}

    # Un tour à blanc pour que le JIT de la BEAM ait chauffé avant la mesure.
    loop(state, mem, min(count, 100_000), 0)

    {microseconds, cycles} = :timer.tc(fn -> loop(state, mem, count, 0) end)

    report(count, microseconds, cycles)
  end

  defp loop(_state, _mem, 0, cycles), do: cycles

  defp loop(state, mem, remaining, cycles) do
    {state, mem, step_cycles} = Atomboy.CPU.step(state, mem)
    loop(state, mem, remaining - 1, cycles + step_cycles)
  end

  defp report(count, microseconds, cycles) do
    seconds = microseconds / 1_000_000
    per_second = count / seconds
    # 4,194304 MHz : le débit de T-cycles qu'une DMG soutient réellement.
    realtime = cycles / seconds / 4_194_304

    Mix.shell().info("""

    #{format(count)} instructions en #{Float.round(seconds, 2)} s

      #{format(round(per_second))} instructions/s
      #{Float.round(per_second / 500_000, 2)}× la cible de 500 000/s
      #{Float.round(realtime * 100, 1)} % de la vitesse d'une DMG réelle
    """)
  end

  defp format(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1 ")
    |> String.reverse()
  end
end
