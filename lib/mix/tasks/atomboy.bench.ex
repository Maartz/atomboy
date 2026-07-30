defmodule Mix.Tasks.Atomboy.Bench do
  @shortdoc "Measures CPU throughput in instructions per second"

  @moduledoc """
  How many Game Boy instructions per second, on this machine.

      mix atomboy.bench [instruction_count]

  ## What the number means, and what it does not

  The program being measured is made of register-to-register `LD r, r'`: no
  memory access beyond the opcode fetch. That is deliberate — the point is to
  isolate the cost of the **calling convention**, not that of the memory
  backend.

  Two consequences worth keeping in mind:

    * The number is an **optimistic ceiling**. Real instructions touch memory,
      juggle flags, jump.
    * Every instruction still pays for a read in the `Atomboy.Memory.Flat` map
      for its fetch. That cost is identical whatever the register convention,
      so it **compresses** the measured gap between two conventions: the real
      difference on register handling is larger than the displayed ratio.

  The target to keep in mind is **500,000 instructions/s**, the throughput a
  DMG sustains at 4.194304 MHz.
  """

  use Mix.Task

  # The whole address range is filled with a register-to-register opcode, so
  # that PC advances and wraps at 0xFFFF without any reset coming to pollute
  # the measurement loop.
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

    # A dry run, so the BEAM's JIT has warmed up before the measurement.
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
    # 4.194304 MHz: the T-cycle throughput a DMG actually sustains.
    realtime = cycles / seconds / 4_194_304

    Mix.shell().info("""

    #{format(count)} instructions in #{Float.round(seconds, 2)} s

      #{format(round(per_second))} instructions/s
      #{Float.round(per_second / 500_000, 2)}× the 500,000/s target
      #{Float.round(realtime * 100, 1)} % of a real DMG's speed
    """)
  end

  defp format(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end
end
