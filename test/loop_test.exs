defmodule Atomboy.CPU.LoopTest do
  @moduledoc """
  Cross-equivalence: the fast loop against the oracle.

  `Atomboy.CPU.Loop` is not validated by the SM83 vectors — it is validated by
  **inheritance**: the oracle passes the vectors, and this test checks that the
  loop produces exactly the oracle's state and memory on random programs. Any
  divergence between `Gen`'s two emitters — a forgotten flag, a miscounted cycle,
  an inverted operand — breaks here.

  Cycle counting is verified structurally: the budget given to `run/4` is the exact
  sum of the cycles of N oracle steps. If the loop counted differently, it would
  execute more or fewer instructions than the oracle, and the states would diverge.

  The seeds are fixed: a failure reproduces as-is, not "once in twenty runs in CI".
  """

  use ExUnit.Case, async: true

  alias Atomboy.CPU.Loop
  alias Atomboy.CPU.State
  alias Atomboy.Memory.Flat

  @steps 2_000
  @seeds 1..20

  for seed <- @seeds do
    test "random program, seed #{seed}" do
      :rand.seed(:exsss, {unquote(seed), 0, 0})

      rom = random_rom()
      state = random_state()

      # The programs self-modify — LD (HL), r sometimes writes onto PC's path —
      # and can manufacture opcodes that are not in the table. The oracle then
      # stops cleanly; the equivalence covers the healthy prefix, plus the fact
      # that the loop fails on the same opcode immediately afterwards.
      {oracle_state, oracle_mem, budget, halted_on} = oracle(rom, state, @steps)
      {loop_state, loop_ram, loop_cycles} = Loop.run(state, rom, %{}, budget)

      assert loop_cycles == budget
      assert loop_state == oracle_state

      if halted_on do
        error =
          assert_raise Atomboy.CPU.Unimplemented, fn ->
            Loop.run(state, rom, %{}, budget + 1)
          end

        assert error.opcode == halted_on
      end

      # The oracle's memory holds ROM + writes; the loop's ram holds the writes
      # alone. Equivalence in both directions: every byte of the address space has
      # to read the same on both sides.
      divergences =
        for addr <- 0..0xFFFF,
            oracle_byte = Flat.read8(oracle_mem, addr),
            loop_byte = Map.get(loop_ram, addr, :binary.at(rom, addr)),
            oracle_byte != loop_byte,
            do: {addr, oracle_byte, loop_byte}

      assert divergences == []
    end
  end

  # ── Generation ──────────────────────────────────────────────────────────────

  # One byte per address, drawn from the implemented opcodes. Since none of them is
  # a jump, PC walks the space linearly and wraps around — every draw is a valid
  # program from end to end.
  defp random_rom do
    opcodes = for {nil, op} <- Atomboy.CPU.implemented(), do: op

    0..0xFFFF
    |> Enum.map(fn _addr -> Enum.random(opcodes) end)
    |> :binary.list_to_bin()
  end

  defp random_state do
    %State{
      a: :rand.uniform(256) - 1,
      # F: the four high bits only, as on the hardware.
      f: (:rand.uniform(16) - 1) * 16,
      b: :rand.uniform(256) - 1,
      c: :rand.uniform(256) - 1,
      d: :rand.uniform(256) - 1,
      e: :rand.uniform(256) - 1,
      h: :rand.uniform(256) - 1,
      l: :rand.uniform(256) - 1,
      sp: :rand.uniform(0x10000) - 1,
      pc: :rand.uniform(0x10000) - 1
    }
  end

  # N oracle steps over a flat memory initialised from the ROM. Returns
  # `{state, memory, budget_in_cycles, offending_opcode | nil}` — the offending
  # opcode is the out-of-table one on which execution stopped before N steps.
  defp oracle(rom, state, steps) do
    mem =
      Flat.new(for {byte, addr} <- Enum.with_index(:binary.bin_to_list(rom)), do: {addr, byte})

    oracle_loop(state, mem, 0, steps)
  end

  defp oracle_loop(st, mem, cycles, 0), do: {st, mem, cycles, nil}

  # tick/2, not step/2: the fast loops service interrupts and sleep on HALT — the
  # random programs incidentally write into IF/IE and execute HALTs, and the
  # equivalence has to cover that hardware too. It has even become its main client.
  defp oracle_loop(st, mem, cycles, steps) do
    {st, mem, step_cycles} = Atomboy.CPU.tick(st, mem)
    oracle_loop(st, mem, cycles + step_cycles, steps - 1)
  rescue
    error in Atomboy.CPU.Unimplemented -> {st, mem, cycles, error.opcode}
  end
end
