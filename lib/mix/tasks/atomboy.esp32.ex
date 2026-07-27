defmodule Mix.Tasks.Atomboy.Esp32 do
  @shortdoc "Empaquette et flashe l'application sur l'ESP32"

  @moduledoc """
  Phase 2 : l'interpréteur sur la carte.

      mix atomboy.esp32                # empaquette, flashe main.avm, c'est tout
      mix atomboy.esp32 --firmware     # flashe d'abord le firmware AtomVM complet
      mix atomboy.esp32 --pack-only    # empaquette sans carte branchée

  Puis, pour voir la sortie série :

      screen <port> 115200             # quitter : Ctrl-A puis K

  ## Layout flash (standard, sans PSRAM)

      0x1000    bootloader
      0x8000    table de partitions
      0x10000   VM AtomVM (atomvm-esp32.bin)
      0x1D0000  esp32boot.avm — le boot Erlang, 256 Ko max
      0x210000  main.avm — nous

  Le boot **Elixir** d'AtomVM (`elixir_esp32boot.avm`, 422 Ko) ne tient pas
  dans la partition boot du layout standard ; c'est l'unique raison d'être du
  layout `partitions-elixir.csv` et de son main à 0x250000. On n'en a pas
  besoin : le boot Erlang chaîne vers main.avm, et tous les modules Elixir que
  l'application utilise — les siens et `exavmlib` — voyagent dans main.avm,
  où il y a 1 Mo.

  ## D'où viennent les binaires

  Le firmware vient du build ESP-IDF de `esp-projects/AtomVM` (novembre 2025) ;
  `esp32boot.avm` et les bibliothèques du build `generic_unix` de
  `elixir-projects/AtomVM`, même millésime. Les chemins se surchargent par
  `ATOMVM_ESP32_BUILD` et `ATOMVM_BUILD`.
  """

  use Mix.Task

  @main_avm_offset "0x210000"

  # nom du segment → {offset, chemin relatif au build ESP32}
  @firmware_segments [
    {"bootloader", "0x1000", "bootloader/bootloader.bin"},
    {"table de partitions", "0x8000", "partition_table/partition-table.bin"},
    {"VM AtomVM", "0x10000", "atomvm-esp32.bin"}
  ]

  @impl true
  def run(argv) do
    Mix.Task.run("compile")

    avm = pack()
    Mix.shell().info("Empaqueté : #{avm} (#{File.stat!(avm).size |> div(1024)} Ko)")

    cond do
      "--pack-only" in argv ->
        Mix.shell().info("Pas de flash demandé. Offset à utiliser : #{@main_avm_offset}.")

      true ->
        port = find_port!()
        if "--firmware" in argv, do: flash_firmware(port)
        flash(port, @main_avm_offset, avm, "main.avm")

        Mix.shell().info("""

        Flashé. Pour voir la sortie :

            screen #{port} 115200
        """)
    end
  end

  # ── Packbeam ────────────────────────────────────────────────────────────────

  defp pack do
    build = unix_build!()
    output = Path.join(Mix.Project.build_path(), "atomboy-esp32.avm")
    File.rm(output)

    # AtomVM démarre sur le start/0 du premier module de l'archive : l'entrée
    # embarquée d'abord, puis le reste de l'app, puis les bibliothèques.
    entry = Path.join(Mix.Project.compile_path(), "Elixir.Atomboy.AtomVM.Main.beam")

    inputs =
      [entry] ++
        (app_beams() -- [entry]) ++
        [
          Path.join(build, "libs/atomvmlib.avm"),
          Path.join(build, "libs/exavmlib/lib/exavmlib.avm")
        ]

    case System.cmd(Path.join(build, "tools/packbeam/PackBEAM"), [output | inputs],
           stderr_to_stdout: true
         ) do
      {_out, 0} -> output
      {out, code} -> Mix.raise("PackBEAM a échoué (code #{code}) :\n#{out}")
    end
  end

  defp app_beams do
    Mix.Project.compile_path()
    |> Path.join("*.beam")
    |> Path.wildcard()
    |> Enum.reject(&String.starts_with?(Path.basename(&1), "Elixir.Mix.Tasks."))
  end

  # ── Flash ───────────────────────────────────────────────────────────────────

  defp flash_firmware(port) do
    esp32 = esp32_build!()

    for {name, offset, relative} <- @firmware_segments do
      flash(port, offset, Path.join(esp32, relative), name)
    end

    # Le boot vient du build generic_unix : la variante Erlang, qui tient dans
    # les 256 Ko de la partition. Voir le moduledoc.
    boot = Path.join(unix_build!(), "libs/esp32boot/esp32boot.avm")
    flash(port, "0x1D0000", boot, "esp32boot.avm")
  end

  defp flash(port, offset, file, name) do
    unless File.regular?(file), do: Mix.raise("#{name} introuvable : #{file}")

    Mix.shell().info("→ #{name} @ #{offset}")

    {out, code} =
      System.cmd(
        "esptool",
        ~w(--chip esp32 --port #{port} --baud 921600 write_flash #{offset} #{file}),
        stderr_to_stdout: true
      )

    if code != 0 do
      Mix.raise("esptool a échoué sur #{name} (code #{code}) :\n#{out}")
    end
  end

  # ── Localisation ────────────────────────────────────────────────────────────

  defp find_port! do
    ports =
      Path.wildcard("/dev/cu.usbserial-*") ++
        Path.wildcard("/dev/cu.SLAB*") ++ Path.wildcard("/dev/cu.wchusbserial*")

    case ports do
      [port] ->
        port

      [] ->
        Mix.raise("""
        Aucun port série trouvé. La carte est-elle branchée ?

        Pour empaqueter sans flasher : mix atomboy.esp32 --pack-only
        """)

      several ->
        Mix.raise("""
        Plusieurs ports série : #{Enum.join(several, ", ")}

        Débranche ce qui n'est pas la carte, ou flashe à la main avec esptool.
        """)
    end
  end

  defp unix_build! do
    build = System.get_env("ATOMVM_BUILD") || Path.expand("../AtomVM/build", File.cwd!())

    unless File.regular?(Path.join(build, "tools/packbeam/PackBEAM")) do
      Mix.raise("Build generic_unix introuvable dans #{build} (voir ATOMVM_BUILD).")
    end

    build
  end

  defp esp32_build! do
    build =
      System.get_env("ATOMVM_ESP32_BUILD") ||
        Path.expand("../../esp-projects/AtomVM/src/platforms/esp32/build", File.cwd!())

    unless File.regular?(Path.join(build, "atomvm-esp32.bin")) do
      Mix.raise("""
      Firmware ESP32 introuvable dans #{build} (voir ATOMVM_ESP32_BUILD).

      Pour le reconstruire : cd src/platforms/esp32 && idf.py set-target esp32 && idf.py build
      """)
    end

    build
  end
end
