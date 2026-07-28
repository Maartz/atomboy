defmodule Mix.Tasks.Atomboy.Esp32 do
  @shortdoc "Empaquette et flashe l'application sur l'ESP32 ou l'ESP32-C6"

  @moduledoc """
  Phase 2 : l'interpréteur sur la carte.

      mix atomboy.esp32                # empaquette et flashe main.avm
      mix atomboy.esp32 --firmware     # flashe d'abord la chaîne AtomVM complète
      mix atomboy.esp32 --pack-only    # empaquette sans carte branchée
      mix atomboy.esp32 --chip esp32c6 # force la cible (sinon déduite du port)
      mix atomboy.esp32 --port /dev/cu.usbmodemXXXX

  Puis, pour voir la sortie série :

      screen <port> 115200             # quitter : Ctrl-A puis K

  ## Deux cibles, deux chaînes

  **ESP32 classique (Xtensa)** — port `usbserial-*`. Firmware AtomVM 0.7
  interprété (build de novembre), payload en bytecode BEAM ordinaire.
  Layout standard : boot à 0x1D0000, main à 0x210000.

  **ESP32-C6 (RISC-V)** — port `usbmodem*`. Chaîne **AOT native** : le VM
  0.8-dev construit avec `CONFIG_JIT_ENABLED` n'exécute *que* du code natif,
  donc chaque beam de l'application et d'exavmlib passe par `jit_precompile`
  (cible riscv32) avant l'empaquetage. Ne pas précompiler un module, c'est un
  crash au chargement sur la carte — le VM n'a pas d'interpréteur de repli.

  L'estdlib n'est **pas** embarquée dans main.avm : elle vit, déjà native,
  dans `esp32boot-riscv32.avm` sur la partition boot, et la résolution de
  modules traverse les deux packs. La dupliquer gonflerait le payload d'un Mo.

  Les offsets C6 ne sont pas codés ici : ils sont lus dans le
  `partitions-jit.csv` du build — le layout JIT (boot 1,5 Mo à 0x180000 pour
  loger le boot natif, main à 0x300000) n'est pas celui du layout standard, et
  c'est précisément ce genre de divergence silencieuse qui a coûté un
  `Invalid startup avmpack` lors du premier flash.

  ## D'où viennent les binaires

  | Cible | Build | Variable |
  |---|---|---|
  | ESP32 : firmware | `esp-projects/AtomVM` (nov. 2025) | `ATOMVM_ESP32_BUILD` |
  | ESP32 : PackBEAM, libs | `elixir-projects/AtomVM/build` | `ATOMVM_BUILD` |
  | C6 : firmware | `AtomVM-jit/src/platforms/esp32/build` | `ATOMVM_JIT_ESP32_BUILD` |
  | C6 : PackBEAM, jit_precompile, libs | `AtomVM-jit/build` | `ATOMVM_JIT_BUILD` |

  La précompilation riscv32 est mise en cache dans `_build` : seuls les beams
  plus récents que leur version native sont recompilés.
  """

  use Mix.Task

  @entry_module Atomboy.AtomVM.Main

  @impl true
  def run(argv) do
    Mix.Task.run("compile")

    {options, _rest} =
      OptionParser.parse!(argv,
        strict: [firmware: :boolean, pack_only: :boolean, chip: :string, port: :string]
      )

    {chip, port} = resolve_target(options)
    avm = pack(chip)

    Mix.shell().info("Empaqueté : #{avm} (#{div(File.stat!(avm).size, 1024)} Ko, cible #{chip})")

    if options[:pack_only] do
      Mix.shell().info("Pas de flash demandé. Offset main.avm : #{offsets(chip).main}.")
    else
      if options[:firmware], do: flash_firmware(chip, port)
      flash(chip, port, offsets(chip).main, avm, "main.avm")

      Mix.shell().info("""

      Flashé. Pour voir la sortie :

          screen #{port} 115200
      """)
    end
  end

  # ── Cible ───────────────────────────────────────────────────────────────────

  defp resolve_target(options) do
    port = options[:port] || detect_port(options[:pack_only])

    chip =
      case {options[:chip], port} do
        {chip, _port} when chip in ["esp32", "esp32c6"] -> String.to_atom(chip)
        {nil, nil} -> :esp32c6
        {nil, port} -> chip_from_port(port)
        {other, _} -> Mix.raise("Cible inconnue : #{other} (attendu : esp32 | esp32c6)")
      end

    {chip, port}
  end

  # Le C6 expose son USB natif en `usbmodem`, les cartes classiques passent par
  # un pont série en `usbserial`.
  defp chip_from_port(port) do
    if String.contains?(port, "usbmodem"), do: :esp32c6, else: :esp32
  end

  defp detect_port(pack_only?) do
    ports =
      Path.wildcard("/dev/cu.usbserial-*") ++
        Path.wildcard("/dev/cu.SLAB*") ++
        Path.wildcard("/dev/cu.wchusbserial*") ++ Path.wildcard("/dev/cu.usbmodem*")

    case ports do
      [port] ->
        port

      [] ->
        if pack_only? do
          nil
        else
          Mix.raise("""
          Aucun port série trouvé. La carte est-elle branchée ?

          Pour empaqueter sans flasher : mix atomboy.esp32 --pack-only
          """)
        end

      several ->
        Mix.raise("""
        Plusieurs ports série : #{Enum.join(several, ", ")}

        Choisis avec --port <chemin>. Certaines cartes exposent deux ports —
        pour le C6, c'est en général celui dont le nom est le plus long
        (l'USB-JTAG natif, avec le numéro de série).
        """)
    end
  end

  # ── Empaquetage ─────────────────────────────────────────────────────────────

  defp pack(:esp32) do
    build = unix_build!()
    output = Path.join(Mix.Project.build_path(), "atomboy-esp32.avm")

    inputs =
      app_beams() ++
        [
          Path.join(build, "libs/atomvmlib.avm"),
          Path.join(build, "libs/exavmlib/lib/exavmlib.avm")
        ]

    Mix.Atomboy.Packbeam.create(build, output, inputs, @entry_module)
    output
  end

  defp pack(:esp32c6) do
    build = jit_build!()
    output = Path.join(Mix.Project.build_path(), "atomboy-esp32c6.avm")

    exavmlib_beams =
      build
      |> Path.join("libs/exavmlib/lib/beams/*.beam")
      |> Path.wildcard()

    natives = precompile(build, app_beams() ++ exavmlib_beams, "riscv32")

    Mix.Atomboy.Packbeam.create(build, output, natives, @entry_module, prune: true)
    output
  end

  defp app_beams do
    Mix.Project.compile_path()
    |> Path.join("*.beam")
    |> Path.wildcard()
    # Tout ce qui vit sous Mix.* est de l'outillage de build : dépend de Mix,
    # absent d'AtomVM, rien à faire sur la carte.
    |> Enum.reject(&String.starts_with?(Path.basename(&1), "Elixir.Mix."))
  end

  # ── Précompilation AOT ──────────────────────────────────────────────────────

  defp precompile(jit_build, beams, arch) do
    out = Path.join(Mix.Project.build_path(), "native-#{arch}")
    File.mkdir_p!(out)
    jit_ebin = Path.join(jit_build, "libs/jit/src/beams")

    {stale, fresh} =
      beams
      |> Enum.map(&{&1, Path.join(out, Path.basename(&1))})
      |> Enum.split_with(fn {source, native} -> stale?(source, native) end)

    unless stale == [] do
      Mix.shell().info(
        "Précompilation #{arch} : #{length(stale)} beams (#{length(fresh)} en cache)"
      )
    end

    Enum.each(stale, fn {source, native} ->
      {log, code} =
        System.cmd(
          "erl",
          ~w(-pa #{jit_ebin} -noshell -s jit_precompile -s init stop -- #{arch} #{out}/ #{source}),
          stderr_to_stdout: true
        )

      # jit_precompile peut sortir en 0 sans produire de fichier : la seule
      # preuve d'une précompilation est l'artefact.
      if code != 0 or not File.regular?(native) do
        Mix.raise("jit_precompile a échoué sur #{Path.basename(source)} :\n#{log}")
      end
    end)

    Enum.map(beams, &Path.join(out, Path.basename(&1)))
  end

  defp stale?(source, native) do
    not File.exists?(native) or
      File.stat!(native).mtime < File.stat!(source).mtime
  end

  # ── Flash ───────────────────────────────────────────────────────────────────

  defp flash_firmware(:esp32, port) do
    esp32 = esp32_build!()

    flash(:esp32, port, "0x1000", Path.join(esp32, "bootloader/bootloader.bin"), "bootloader")

    flash(
      :esp32,
      port,
      "0x8000",
      Path.join(esp32, "partition_table/partition-table.bin"),
      "table de partitions"
    )

    flash(:esp32, port, "0x10000", Path.join(esp32, "atomvm-esp32.bin"), "VM AtomVM")

    boot = Path.join(unix_build!(), "libs/esp32boot/esp32boot.avm")
    flash(:esp32, port, offsets(:esp32).boot, boot, "esp32boot.avm")
  end

  defp flash_firmware(:esp32c6, port) do
    esp32 = jit_esp32_build!()

    # Sur les puces RISC-V, le bootloader est à 0x0 — pas à 0x1000 comme sur
    # l'ESP32 originel.
    flash(:esp32c6, port, "0x0", Path.join(esp32, "bootloader/bootloader.bin"), "bootloader")

    flash(
      :esp32c6,
      port,
      "0x8000",
      Path.join(esp32, "partition_table/partition-table.bin"),
      "table de partitions"
    )

    flash(:esp32c6, port, "0x10000", Path.join(esp32, "atomvm-esp32.bin"), "VM AtomVM (JIT)")

    boot = Path.join(jit_build!(), "libs/esp32boot/esp32boot-riscv32.avm")
    flash(:esp32c6, port, offsets(:esp32c6).boot, boot, "esp32boot-riscv32.avm")
  end

  defp flash(chip, port, offset, file, name) do
    unless File.regular?(file), do: Mix.raise("#{name} introuvable : #{file}")

    Mix.shell().info("→ #{name} @ #{offset}")

    {out, code} =
      System.cmd(
        "esptool",
        ~w(--chip #{chip} --port #{port} --baud 921600 write_flash #{offset} #{file}),
        stderr_to_stdout: true
      )

    if code != 0 do
      Mix.raise("esptool a échoué sur #{name} (code #{code}) :\n#{out}")
    end
  end

  # ── Offsets ─────────────────────────────────────────────────────────────────

  # Layout standard, stable depuis novembre.
  defp offsets(:esp32), do: %{boot: "0x1D0000", main: "0x210000"}

  # Layout JIT : lu depuis le CSV du build plutôt que codé ici — il a déjà
  # changé une fois entre novembre et juillet, et rien ne l'empêche de bouger
  # encore.
  defp offsets(:esp32c6) do
    csv = Path.join(jit_esp32_build!(), "../partitions-jit.csv")

    partitions =
      csv
      |> File.read!()
      |> String.split("\n")
      |> Enum.reject(&String.starts_with?(&1, "#"))
      |> Enum.map(&String.split(&1, ",", trim: true))
      |> Enum.filter(&match?([_, _, _, _, _ | _], &1))
      |> Map.new(fn [name, _type, _subtype, offset | _rest] ->
        {String.trim(name), String.trim(offset)}
      end)

    case partitions do
      %{"boot.avm" => boot, "main.avm" => main} ->
        %{boot: boot, main: main}

      _other ->
        Mix.raise("Partitions boot.avm/main.avm introuvables dans #{csv}")
    end
  end

  # ── Localisation des builds ─────────────────────────────────────────────────

  defp unix_build! do
    locate("ATOMVM_BUILD", "../AtomVM/build", "tools/packbeam/PackBEAM", """
    Build generic_unix d'AtomVM 0.7 introuvable (voir ATOMVM_BUILD).
    """)
  end

  defp esp32_build! do
    locate(
      "ATOMVM_ESP32_BUILD",
      "../../esp-projects/AtomVM/src/platforms/esp32/build",
      "atomvm-esp32.bin",
      """
      Firmware ESP32 introuvable (voir ATOMVM_ESP32_BUILD).
      """
    )
  end

  defp jit_build! do
    locate("ATOMVM_JIT_BUILD", "../AtomVM-jit/build", "tools/packbeam/PackBEAM", """
    Build generic_unix d'AtomVM main (JIT) introuvable (voir ATOMVM_JIT_BUILD).

    Il se construit depuis le worktree AtomVM-jit :
        cmake .. -DMBEDTLS_ROOT_DIR=/opt/homebrew/opt/mbedtls@3 -DAVM_DISABLE_JIT=OFF
        make -j8 AtomVM PackBEAM atomvmlib exavmlib esp32boot_riscv32
    """)
  end

  defp jit_esp32_build! do
    locate(
      "ATOMVM_JIT_ESP32_BUILD",
      "../AtomVM-jit/src/platforms/esp32/build",
      "atomvm-esp32.bin",
      """
      Firmware ESP32-C6 introuvable (voir ATOMVM_JIT_ESP32_BUILD).

      Il se construit depuis AtomVM-jit/src/platforms/esp32 avec l'ESP-IDF :
          idf.py set-target esp32c6
          # CONFIG_JIT_ENABLED=y, CONFIG_COMPILER_OPTIMIZATION_PERF=y
          idf.py build
      """
    )
  end

  defp locate(env_var, default_relative, proof, error) do
    build = System.get_env(env_var) || Path.expand(default_relative, File.cwd!())

    unless File.regular?(Path.join(build, proof)) do
      Mix.raise(String.trim(error) <> "\n\nCherché dans : #{build}")
    end

    build
  end
end
