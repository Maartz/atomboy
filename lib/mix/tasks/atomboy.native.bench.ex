defmodule Mix.Tasks.Atomboy.Native.Bench do
  @shortdoc "Measures the native cost in RV32 instructions per SM83 instruction"

  @moduledoc """
  This project's number.

      mix atomboy.native.bench

  ## Why not seconds

  qemu is not cycle-accurate: timing a guest run measures the host machine. What
  is exact is the **count of retired instructions** -- under `-icount shift=0`,
  the emulated processor's `instret` counter counts them one by one. Verified by
  hand: a thousand-iteration loop of two instructions reports 2002.

  So "RV32 instructions per SM83 instruction" is a measurement, not an estimate.
  It is also the only quantity that carries from qemu to silicon: it depends
  neither on frequency, nor on cache, nor on the host.

  ## What the number does not say

  It does not say how many instructions per cycle the C6 actually retires. Cache
  misses, flash latency and branch mispredictions are not in qemu. The
  projection at the end of the report therefore states an explicit IPC
  assumption, and it is worth exactly what that assumption is worth -- which is
  to say it is waiting for silicon.
  """

  use Mix.Task

  alias Atomboy.CPU.Insn
  alias Atomboy.CPU.State
  alias Atomboy.CPU.Table
  alias Atomboy.Memory.Flat
  alias Atomboy.Native.Interp
  alias Atomboy.Native.Qemu
  alias Atomboy.Native.Run

  @icache 32 * 1024
  @dmg_clock 4_194_304
  @c6_clock 160_000_000

  # Two programs, and two ways of lying about the same measurement.
  #
  # `LD B, C` repeated accesses nothing: an optimistic ceiling, and exactly what
  # `mix atomboy.bench` measures, so the two figures compare.
  #
  # The mixed block is the one `Atomboy.AtomVM.Main` runs on the board --
  # immediates, ALU, a CB rotation, register access -- so the native figures and
  # the C6 figures describe the same program.
  @blocks [
    {"LD B, C", <<0x41>>},
    {"mixed block",
     <<0x3E, 0x55, 0x06, 0x33, 0x80, 0x04, 0xB1, 0x2F, 0xCB, 0x37, 0xA8, 0x15, 0x1F, 0xE6, 0x0F,
       0x7D>>}
  ]

  @impl true
  def run(_argv) do
    Mix.Task.run("compile")

    unless Qemu.available?() do
      Mix.raise("qemu-system-riscv32 est introuvable — `brew install qemu`")
    end

    size_report()
    Mix.shell().info("")
    Enum.each(@blocks, &measure/1)
  end

  # ══ The size ═════════════════════════════════════════════════════════════════

  defp size_report do
    image = Interp.image(:binary.copy(<<0>>, 0x10000), %State{}, 1)
    l = image.labels

    sections = [
      {"driver, fetch and report", l[:h_cb]},
      {"opcode handlers", l[:alu_add] - l[:h_cb]},
      {"ALU routines", l[:table_base] - l[:alu_add]},
      {"jump tables", 2 * 256 * 4}
    ]

    code = l[:table_base] + 2 * 256 * 4

    Mix.shell().info("Emitted code size")

    for {name, bytes} <- sections do
      Mix.shell().info("  #{String.pad_trailing(name, 26)} #{pad(bytes)} B")
    end

    Mix.shell().info("  #{String.pad_trailing("total", 26)} #{pad(code)} B")

    Mix.shell().info(
      "  that is #{Float.round(code * 100 / @icache, 1)} % of the C6's cache (#{@icache} bytes)"
    )
  end

  defp pad(n), do: String.pad_leading(Integer.to_string(n), 6)

  # ══ The measurement ══════════════════════════════════════════════════════════

  defp measure({name, block}) do
    %{instructions: per_block, cycles: block_cycles} = analyse(block)

    # A budget of whole blocks: the last instruction does not overrun, so the
    # SM83 instruction count is exact rather than estimated.
    turns = 5_000
    budget = block_cycles * turns
    instructions = per_block * turns

    memory = fill(block)
    verify!(name, block, memory, per_block, block_cycles)

    result = Run.run!(memory, %State{}, budget, icount: true)

    if result.status != :ok do
      Mix.raise("block #{name} stopped on #{result.status}")
    end

    if result.cycles != budget do
      Mix.raise("budget #{budget} asked for, #{result.cycles} consumed -- block does not loop")
    end

    # PC exactly on the last turn's boundary: otherwise the budget would stop
    # mid-block, the instruction count would be off, and the report wrong with
    # nothing to signal it.
    expected_pc = rem(turns * byte_size(block), 0x10000)

    if result.state.pc != expected_pc do
      Mix.raise(
        "PC ends at #{result.state.pc} instead of #{expected_pc} -- " <>
          "the budget does not land on a whole turn"
      )
    end

    per_instruction = result.instret / instructions
    per_cycle = result.instret / budget
    cycles_per_second = @c6_clock / per_cycle

    Mix.shell().info("""
    #{name} -- #{per_block} SM83 instruction(s), #{block_cycles} T per turn
      #{instructions} SM83 instructions, #{result.instret} RV32 instructions
      #{Float.round(per_instruction, 2)} RV32 instructions per SM83 instruction
      #{Float.round(per_cycle, 2)} per T cycle

      C6 projection at #{div(@c6_clock, 1_000_000)} MHz: #{round(cycles_per_second / 1000)} kcycles/s,
      that is #{Float.round(cycles_per_second * 100 / @dmg_clock, 1)} % of a DMG's real time --
      **assuming one instruction per cycle**, which qemu cannot validate, and
      **for the CPU alone**: no PPU, no APU, no cartridge banking.
    """)
  end

  # The block's tally, checked against the oracle: `instructions` steps must
  # consume exactly `cycles` T and bring PC back to its starting point. A bench
  # that miscounts returns a wrong report with nothing to signal it.
  defp verify!(name, block, memory, instructions, cycles) do
    flat =
      Flat.new(for {b, addr} <- Enum.with_index(:binary.bin_to_list(memory)), do: {addr, b})

    {state, _mem, consumed} =
      Enum.reduce(1..instructions, {%State{}, flat, 0}, fn _, {st, mem, total} ->
        {st, mem, pas} = Atomboy.CPU.tick(st, mem)
        {st, mem, total + pas}
      end)

    if consumed != cycles do
      Mix.raise("#{name}: the table says #{cycles} T per turn, the oracle consumes #{consumed}")
    end

    if state.pc != byte_size(block) do
      Mix.raise(
        "#{name}: after #{instructions} steps the oracle is at #{state.pc}, " <>
          "but the block is #{byte_size(block)} bytes -- the instruction count is wrong"
      )
    end

    :ok
  end

  # The block repeated until it fills the address space. Its length divides
  # 65536 so PC's wrap lands back on a block boundary.
  defp fill(block) do
    size = byte_size(block)

    unless rem(0x10000, size) == 0 do
      Mix.raise("a block of #{size} bytes does not tile 64 KB")
    end

    :binary.copy(block, div(0x10000, size))
  end

  # ══ The tally, from the table ════════════════════════════════════════════════

  # How many instructions and cycles a block holds. Derived from the table
  # rather than written by hand: a bench block counting wrong would give a wrong
  # report with nothing to say so.
  defp analyse(block), do: analyse(:binary.bin_to_list(block), %{instructions: 0, cycles: 0})

  defp analyse([], acc), do: acc

  defp analyse([0xCB, sub | rest], acc) do
    insn = find_insn(Table.extended(), sub)
    analyse(rest, %{acc | instructions: acc.instructions + 1, cycles: acc.cycles + insn.cycles})
  end

  defp analyse([opcode | rest], acc) do
    insn = find_insn(Table.base(), opcode)
    rest = Enum.drop(rest, operand_bytes(insn))
    analyse(rest, %{acc | instructions: acc.instructions + 1, cycles: acc.cycles + insn.cycles})
  end

  defp find_insn(table, opcode) do
    Enum.find(table, &(&1.opcode == opcode)) ||
      Mix.raise("the block holds opcode #{opcode}, absent from the table")
  end

  defp operand_bytes(%Insn{operands: operands}) do
    Enum.reduce(operands, 0, fn
      {:imm, 8}, n -> n + 1
      :a8_ind, n -> n + 1
      {:imm, 16}, n -> n + 2
      :a16_ind, n -> n + 2
      _, n -> n
    end)
  end
end
