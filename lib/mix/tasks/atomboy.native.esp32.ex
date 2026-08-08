defmodule Mix.Tasks.Atomboy.Native.Esp32 do
  @shortdoc "Emits the native core as a blob for the ESP32-C6 host application"

  @moduledoc """
  The generated emulator, packaged for the chip.

      mix atomboy.native.esp32                  # games/hero.gb, 10 frames
      mix atomboy.native.esp32 games/pong.gb    # another cartridge
      mix atomboy.native.esp32 --frames 60
      mix atomboy.native.esp32 --no-audio          # pixels only

  Writes `esp32/native/main/blob.bin`: position-independent RV32I with the
  guest's 64 KB, the jump tables and the framebuffer inside it. The ESP-IDF
  application in `esp32/native/` embeds it and calls offset 0 --
  `Atomboy.Native.Machine.blob/4` documents what comes back.

  Then, from `esp32/native/`:

      . $IDF_PATH/export.sh
      idf.py -p /dev/cu.usbmodemXXXX flash monitor

  This is a different chain from `mix atomboy.esp32`, which flashes AtomVM and
  runs the BEAM emulator on the board. That one plateaued at 12% of real time
  and is what this exists to replace: the blob is the emulator itself, compiled
  to the chip's own instruction set.
  """

  use Mix.Task

  alias Atomboy.Native.Boot
  alias Atomboy.Native.Machine
  alias Atomboy.Screen

  @output "esp32/native/main/blob.bin"

  @impl true
  def run(argv) do
    Mix.Task.run("compile")

    {options, rest} =
      OptionParser.parse!(argv, strict: [frames: :integer, render: :boolean, audio: :boolean])

    path = List.first(rest) || "games/hero.gb"
    frames = options[:frames] || 10

    unless File.regular?(path), do: Mix.raise("no such cartridge: #{path}")

    rom = Screen.load(path)

    blob =
      Machine.blob(memory(rom), Screen.boot_state(rom, true), frames,
        render: Keyword.get(options, :render, true),
        audio: Keyword.get(options, :audio, true)
      )

    File.mkdir_p!(Path.dirname(@output))
    File.write!(@output, blob.code)

    Mix.shell().info("""
    #{@output}: #{blob.size} bytes -- #{Path.basename(path)}, #{frames} frames

    From esp32/native/:  idf.py -p <port> flash monitor
    """)
  end

  # The flat 64 KB the guest starts from, seeded exactly as the differential
  # tests seed it: the cartridge below 0x8000, open bus above, and the DMG's
  # post-boot I/O registers written out -- `Atomboy.Native.Boot` says which and
  # why. Getting this wrong does not crash anything, it draws a slightly
  # different picture, which is worse.
  defp memory(rom) do
    flat = rom <> :binary.copy(<<0xFF>>, 0x10000 - byte_size(rom))

    Enum.reduce(Boot.io_state(), flat, fn {address, value}, acc ->
      <<before::binary-size(address), _::8, rest::binary>> = acc
      before <> <<value>> <> rest
    end)
  end
end
