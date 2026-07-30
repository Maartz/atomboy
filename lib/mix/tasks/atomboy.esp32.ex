defmodule Mix.Tasks.Atomboy.Esp32 do
  @shortdoc "Packs and flashes the application onto the ESP32 or the ESP32-C6"

  @moduledoc """
  Phase 2: the interpreter on the board.

      mix atomboy.esp32                # packs and flashes main.avm
      mix atomboy.esp32 --firmware     # flashes the whole AtomVM chain first
      mix atomboy.esp32 --pack-only    # packs with no board plugged in
      mix atomboy.esp32 --chip esp32c6 # forces the target (else read from port)
      mix atomboy.esp32 --port /dev/cu.usbmodemXXXX

  Then, to watch the serial output:

      screen <port> 115200             # to quit: Ctrl-A then K

  ## Two targets, two chains

  **Classic ESP32 (Xtensa)** — `usbserial-*` port. Interpreted AtomVM 0.7
  firmware (the November build), payload in ordinary BEAM bytecode. Standard
  layout: boot at 0x1D0000, main at 0x210000.

  **ESP32-C6 (RISC-V)** — `usbmodem*` port. **Native AOT** chain: the 0.8-dev
  VM built with `CONFIG_JIT_ENABLED` runs *only* native code, so every beam of
  the application and of exavmlib goes through `jit_precompile` (riscv32
  target) before packing. Failing to precompile a module means a crash on load
  on the board — the VM has no interpreter to fall back on.

  estdlib is **not** embedded in main.avm: it lives, already native, in
  `esp32boot-riscv32.avm` on the boot partition, and module resolution walks
  both packs. Duplicating it would inflate the payload by a megabyte.

  The C6 offsets are not hard-coded here: they are read from the build's
  `partitions-jit.csv` — the JIT layout (1.5 MB boot at 0x180000 to house the
  native boot, main at 0x300000) is not the standard one, and it is precisely
  this kind of silent divergence that cost an `Invalid startup avmpack` on the
  first flash.

  ## Where the binaries come from

  | Target | Build | Variable |
  |---|---|---|
  | ESP32: firmware | `esp-projects/AtomVM` (Nov 2025) | `ATOMVM_ESP32_BUILD` |
  | ESP32: PackBEAM, libs | `elixir-projects/AtomVM/build` | `ATOMVM_BUILD` |
  | C6: firmware | `AtomVM-jit/src/platforms/esp32/build` | `ATOMVM_JIT_ESP32_BUILD` |
  | C6: PackBEAM, jit_precompile, libs | `AtomVM-jit/build` | `ATOMVM_JIT_BUILD` |

  The riscv32 precompilation is cached in `_build`: only the beams newer than
  their native version are recompiled.
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

    Mix.shell().info("Packed: #{avm} (#{div(File.stat!(avm).size, 1024)} KB, target #{chip})")

    if options[:pack_only] do
      Mix.shell().info("No flash requested. main.avm offset: #{offsets(chip).main}.")
    else
      if options[:firmware], do: flash_firmware(chip, port)
      flash(chip, port, offsets(chip).main, avm, "main.avm")

      Mix.shell().info("""

      Flashed. To watch the output:

          screen #{port} 115200
      """)
    end
  end

  # ── Target ──────────────────────────────────────────────────────────────────

  defp resolve_target(options) do
    port = options[:port] || detect_port(options[:pack_only])

    chip =
      case {options[:chip], port} do
        {chip, _port} when chip in ["esp32", "esp32c6"] -> String.to_atom(chip)
        {nil, nil} -> :esp32c6
        {nil, port} -> chip_from_port(port)
        {other, _} -> Mix.raise("Unknown target: #{other} (expected: esp32 | esp32c6)")
      end

    {chip, port}
  end

  # The C6 exposes its native USB as `usbmodem`, while the classic boards go
  # through a serial bridge as `usbserial`.
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
          No serial port found. Is the board plugged in?

          To pack without flashing: mix atomboy.esp32 --pack-only
          """)
        end

      several ->
        Mix.raise("""
        Several serial ports: #{Enum.join(several, ", ")}

        Pick one with --port <path>. Some boards expose two ports — for the C6
        it is usually the one with the longest name (the native USB-JTAG, with
        the serial number).
        """)
    end
  end

  # ── Packing ─────────────────────────────────────────────────────────────────

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
    # Everything under Mix.* is build tooling: depends on Mix, absent from
    # AtomVM, no business on the board.
    |> Enum.reject(&String.starts_with?(Path.basename(&1), "Elixir.Mix."))
  end

  # ── AOT precompilation ──────────────────────────────────────────────────────

  defp precompile(jit_build, beams, arch) do
    out = Path.join(Mix.Project.build_path(), "native-#{arch}")
    File.mkdir_p!(out)
    jit_ebin = Path.join(jit_build, "libs/jit/src/beams")

    {stale, fresh} =
      beams
      |> Enum.map(&{&1, Path.join(out, Path.basename(&1))})
      |> Enum.split_with(fn {source, native} -> stale?(source, native) end)

    unless stale == [] do
      Mix.shell().info("Precompiling #{arch}: #{length(stale)} beams (#{length(fresh)} cached)")
    end

    Enum.each(stale, fn {source, native} ->
      {log, code} =
        System.cmd(
          "erl",
          ~w(-pa #{jit_ebin} -noshell -s jit_precompile -s init stop -- #{arch} #{out}/ #{source}),
          stderr_to_stdout: true
        )

      # jit_precompile can exit 0 without producing a file: the only proof of a
      # precompilation is the artefact.
      if code != 0 or not File.regular?(native) do
        Mix.raise("jit_precompile failed on #{Path.basename(source)}:\n#{log}")
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
      "partition table"
    )

    flash(:esp32, port, "0x10000", Path.join(esp32, "atomvm-esp32.bin"), "AtomVM VM")

    boot = Path.join(unix_build!(), "libs/esp32boot/esp32boot.avm")
    flash(:esp32, port, offsets(:esp32).boot, boot, "esp32boot.avm")
  end

  defp flash_firmware(:esp32c6, port) do
    esp32 = jit_esp32_build!()

    # On RISC-V chips the bootloader sits at 0x0 — not at 0x1000 as on the
    # original ESP32.
    flash(:esp32c6, port, "0x0", Path.join(esp32, "bootloader/bootloader.bin"), "bootloader")

    flash(
      :esp32c6,
      port,
      "0x8000",
      Path.join(esp32, "partition_table/partition-table.bin"),
      "partition table"
    )

    flash(:esp32c6, port, "0x10000", Path.join(esp32, "atomvm-esp32.bin"), "AtomVM VM (JIT)")

    boot = Path.join(jit_build!(), "libs/esp32boot/esp32boot-riscv32.avm")
    flash(:esp32c6, port, offsets(:esp32c6).boot, boot, "esp32boot-riscv32.avm")
  end

  defp flash(chip, port, offset, file, name) do
    unless File.regular?(file), do: Mix.raise("#{name} not found: #{file}")

    Mix.shell().info("→ #{name} @ #{offset}")

    {out, code} =
      System.cmd(
        "esptool",
        ~w(--chip #{chip} --port #{port} --baud 921600 write_flash #{offset} #{file}),
        stderr_to_stdout: true
      )

    cond do
      code == 0 ->
        :ok

      String.contains?(out, "Resource busy") ->
        Mix.raise("""
        Port #{port} is busy — most likely a screen session left open on it.
        Close it (Ctrl-A then K) and try again.
        """)

      true ->
        Mix.raise("esptool failed on #{name} (code #{code}):\n#{out}")
    end
  end

  # ── Offsets ─────────────────────────────────────────────────────────────────

  # Standard layout, stable since November.
  defp offsets(:esp32), do: %{boot: "0x1D0000", main: "0x210000"}

  # JIT layout: read from the build's CSV rather than written here — it has
  # already changed once between November and July, and nothing stops it from
  # moving again.
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
        Mix.raise("boot.avm/main.avm partitions not found in #{csv}")
    end
  end

  # ── Locating the builds ─────────────────────────────────────────────────────

  defp unix_build! do
    locate("ATOMVM_BUILD", "../AtomVM/build", "tools/packbeam/PackBEAM", """
    AtomVM 0.7 generic_unix build not found (see ATOMVM_BUILD).
    """)
  end

  defp esp32_build! do
    locate(
      "ATOMVM_ESP32_BUILD",
      "../../esp-projects/AtomVM/src/platforms/esp32/build",
      "atomvm-esp32.bin",
      """
      ESP32 firmware not found (see ATOMVM_ESP32_BUILD).
      """
    )
  end

  defp jit_build! do
    locate("ATOMVM_JIT_BUILD", "../AtomVM-jit/build", "tools/packbeam/PackBEAM", """
    AtomVM main (JIT) generic_unix build not found (see ATOMVM_JIT_BUILD).

    It is built from the AtomVM-jit worktree:
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
      ESP32-C6 firmware not found (see ATOMVM_JIT_ESP32_BUILD).

      It is built from AtomVM-jit/src/platforms/esp32 with the ESP-IDF:
          idf.py set-target esp32c6
          # CONFIG_JIT_ENABLED=y, CONFIG_COMPILER_OPTIMIZATION_PERF=y
          idf.py build
      """
    )
  end

  defp locate(env_var, default_relative, proof, error) do
    build = System.get_env(env_var) || Path.expand(default_relative, File.cwd!())

    unless File.regular?(Path.join(build, proof)) do
      Mix.raise(String.trim(error) <> "\n\nLooked in: #{build}")
    end

    build
  end
end
