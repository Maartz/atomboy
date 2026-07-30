defmodule Mix.Tasks.Atomboy.Native do
  @shortdoc "Builds the RV32 interpreter and runs it under qemu"

  @moduledoc """
  The native backend, from the command line.

      mix atomboy.native          # size, coverage, and one witness run
      mix atomboy.native --size   # build only, without launching qemu
      mix atomboy.native --smoke  # the smoke image, no interpreter

  ## The number to watch

  This work exists for a measured reason: on the ESP32-C6 the emulator caps at
  12% of real time because roughly a megabyte of AtomVM native interpreter
  fights a 32 KB instruction cache. A SM83 interpreter emitted directly has to
  fit inside it. The "code" line below is therefore the project's real
  dashboard, and it should stay legible at every stage rather than be discovered
  at the end.
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

    if "--smoke" in argv, do: smoke(argv), else: interpreter(argv)
  end

  defp interpreter(argv) do
    memory = :binary.copy(<<0x00>>, 0x10000)
    image = Interp.image(memory, %State{}, 1)

    code = image.labels[:table_base]
    covered = length(Emit.table_coverage())
    total = length(Table.all())
    alu = Asm.assemble(ALU.routines())

    Mix.shell().info("""
    Coverage : #{covered}/#{total} instructions emitted (#{percent(covered, total)} %)#{if Emit.prefix_covered?(), do: ", CB prefix wired", else: ""}
    Code     : #{code} bytes, #{percent(code, @icache)} % of the C6's instruction cache
    ALU      : #{alu.size} bytes for #{routines(alu)} routines, linked into the interpreter
    Image    : #{image.size} bytes, of which 64 KB is emulated memory
    """)

    unless "--size" in argv do
      require_qemu()
      witness(memory)
    end
  end

  # A program of NOPs: PC must have advanced exactly one step per four cycles.
  # It is the smallest sign of life proving that the fetch, the jump table and
  # the cycle accounting hold together.
  defp witness(memory) do
    budget = 4000

    case Run.run(memory, %State{}, budget) do
      {:ok, result} ->
        Mix.shell().info(
          "Witness : #{result.cycles} cycles, PC=#{result.state.pc}, " <>
            "status #{result.status}, in #{div(result.duration_us, 1000)} ms"
        )

      {:error, reason} ->
        Mix.raise("the guest returned nothing: #{inspect(reason)}")
    end
  end

  defp smoke(argv) do
    image = Image.smoke()
    Mix.shell().info("Smoke image: #{image.size} bytes")

    unless "--size" in argv do
      require_qemu()
      result = Qemu.run(image.code)

      case result.status do
        :ok -> Mix.shell().info("Serial output: #{inspect(result.serial)}")
        :timeout -> Mix.raise("the guest never handed control back")
      end
    end
  end

  defp require_qemu do
    unless Qemu.available?() do
      Mix.raise("qemu-system-riscv32 not found -- `brew install qemu`")
    end
  end

  defp percent(part, whole), do: Float.round(part * 100 / whole, 1)

  # One routine per label: the assembly resolved them all, so counting them here
  # avoids keeping a duplicate list.
  defp routines(%{labels: labels}) do
    labels |> Map.keys() |> Enum.count(&String.starts_with?(Atom.to_string(&1), "alu_"))
  end
end
