defmodule Atomboy.Blargg do
  @moduledoc """
  Fait tourner une ROM de test blargg et lit son verdict sur le lien série.

  Les ROMs de la génération `cpu_instrs` publient leurs résultats caractère
  par caractère sur le lien série — un octet dans 0xFF01, bit 7 de 0xFF02
  pour l'envoyer. `Atomboy.CPU.CartLoop` capture chaque envoi à l'écriture
  dans le tampon `:serial` de sa map ; ici on ne fait que scruter ce tampon
  entre deux tranches d'exécution, à la recherche de `Passed` ou `Failed`.

  La sémantique cartouche de CartLoop est indispensable : blargg pilote le MBC
  en écrivant sous 0x8000, et le modèle plat de `Loop` laisserait ces
  écritures masquer la ROM.

  L'état initial est celui que la boot ROM DMG laisse au jeu : PC 0x100,
  SP 0xFFFE, AF 0x01B0, BC 0x0013, DE 0x00D8, HL 0x014D. Le registre LY
  (0xFF44) est pré-écrit à 0x90 — la ligne du vblank — pour les attentes
  d'écran ; blargg est conçu pour ne pas bloquer si LY ne bouge pas, mais
  autant lui répondre quelque chose de sensé.
  """

  alias Atomboy.CPU.State

  # Une frame entre deux inspections du tampon série.
  @frame_cycles 70_224

  @type verdict :: {:passed, String.t()} | {:failed, String.t()} | {:timeout, String.t()}

  @doc """
  Exécute la ROM jusqu'au verdict, ou `max_cycles` au plus.
  """
  @spec run(Path.t(), pos_integer()) :: verdict()
  def run(rom_path, max_cycles \\ 500_000_000) do
    rom = load(rom_path)

    state = %State{
      a: 0x01,
      f: 0xB0,
      b: 0x00,
      c: 0x13,
      d: 0x00,
      e: 0xD8,
      h: 0x01,
      l: 0x4D,
      sp: 0xFFFE,
      pc: 0x0100
    }

    execute(state, rom, %{0xFF44 => 0x90}, max_cycles)
  end

  defp load(path) do
    rom = File.read!(path)

    if byte_size(rom) > 0x8000 do
      raise "ROM de #{byte_size(rom)} octets : le banking MBC n'existe pas encore, 32 Ko max"
    end

    # Le reste de l'espace lit 0xFF — le bus ouvert du matériel.
    rom <> :binary.copy(<<0xFF>>, 0x10000 - byte_size(rom))
  end

  defp execute(_state, _rom, ram, budget_left) when budget_left <= 0 do
    {:timeout, serial(ram)}
  end

  # Une frame de 154 scanlines par tour, via la brique commune — LY vit, le
  # vblank se lève, le timer bat : 02-interrupts mesure tout ça.
  defp execute(state, rom, ram, budget_left) do
    {state, ram} =
      Enum.reduce(0..153, {state, ram}, fn ly, {state, ram} ->
        Atomboy.Screen.step_line(state, rom, ram, ly)
      end)

    output = serial(ram)

    cond do
      String.contains?(output, "Passed") -> {:passed, output}
      String.contains?(output, "Failed") -> {:failed, output}
      true -> execute(state, rom, ram, budget_left - @frame_cycles)
    end
  end

  defp serial(ram) do
    ram |> Map.get(:serial, "") |> IO.iodata_to_binary()
  end
end
