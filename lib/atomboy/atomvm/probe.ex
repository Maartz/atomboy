defmodule Atomboy.AtomVM.Probe do
  @moduledoc """
  A measurement probe: the CPU loop **with no map at all on the hot path**.

  This module does not prefigure the architecture — it is an instrument, meant
  to be thrown away. It exists to answer a single question, in figures on
  native AtomVM: what is the loop worth once you remove what the JIT cannot
  accelerate?

  The reference measurement showed the problem: native AOT gains only ×1.21
  over interpreted, because every step goes through map BIFs — the fetch in
  `Atomboy.Memory.Flat`, the update of the `State` struct — which native
  compilation does not touch. Amdahl's law: as long as 85 % of the time is in
  the maps, no backend can do better than ×1.2.

  Here, both sources of BIFs disappear:

    * **The registers travel as function arguments.** In native code, the
      BEAM's x registers become machine registers. This is the original
      `exec/13` design, resurrected where it counts — the inner loop — and
      invisible from the outside.
    * **The ROM is a 64 KB binary**, fetched with `:binary.at/2`. No hashing,
      no allocation, and it is already the target model: a real Game Boy ROM is
      immutable by definition.

  Memory writes stay in a map threaded through as an argument: the measured
  program only writes once per pass over the address space, so the cost is
  invisible. When the day comes, this will be the brief's resource NIF.

  The program is the same as `Atomboy.AtomVM.Main`'s — LD B,C ; LD (HL),B ;
  LD A,(HL) ; NOP, then NOPs until PC wraps — so that the two figures are
  comparable term by term.
  """

  import Bitwise

  @slice 50_000

  @doc "Builds the ROM: Main's program, then NOPs up to 64 KB."
  @spec rom() :: binary()
  def rom do
    <<0x41, 0x70, 0x7E, 0x00>> <> :binary.copy(<<0x00>>, 0x10000 - 4)
  end

  @doc """
  Time-bounded measurement, like Main's bench.

  Cut into slices of #{@slice} steps via `Atomboy.AtomVM.Main.measure/2`, for
  the same watchdog reasons — each slice starts over from the initial state,
  which makes no difference on a program this periodic.
  """
  @spec bench() :: :ok
  def bench do
    rom = rom()

    # Short warm-up, like the reference bench.
    loop(rom, %{}, 1_000, 0, 0, 0, 0, 0x42, 0, 0, 0xC0, 0x00, 0xFFFE, 0x0000)

    {steps, elapsed} =
      Atomboy.AtomVM.Main.measure(nil, fn nil ->
        loop(rom, %{}, @slice, 0, 0, 0, 0, 0x42, 0, 0, 0xC0, 0x00, 0xFFFE, 0x0000)
        {nil, @slice}
      end)

    per_second = if elapsed > 0, do: div(steps * 1000, elapsed), else: :too_fast

    :erlang.display({:probe_steps, steps})
    :erlang.display({:probe_elapsed_ms, elapsed})
    :erlang.display({:probe_instructions_per_second, per_second})
    :ok
  end

  # The loop: binary fetch, dispatch, tail call — registers in arguments from
  # end to end, not a single structure built.
  defp loop(_rom, _ram, 0, cycles, _a, _f, _b, _c, _d, _e, _h, _l, _sp, _pc), do: cycles

  defp loop(rom, ram, steps, cycles, a, f, b, c, d, e, h, l, sp, pc) do
    case :binary.at(rom, pc) do
      # NOP
      0x00 ->
        loop(rom, ram, steps - 1, cycles + 4, a, f, b, c, d, e, h, l, sp, pc + 1 &&& 0xFFFF)

      # LD B, C
      0x41 ->
        loop(rom, ram, steps - 1, cycles + 4, a, f, c, c, d, e, h, l, sp, pc + 1 &&& 0xFFFF)

      # LD (HL), B
      0x70 ->
        ram = Map.put(ram, bsl(h, 8) ||| l, b)
        loop(rom, ram, steps - 1, cycles + 8, a, f, b, c, d, e, h, l, sp, pc + 1 &&& 0xFFFF)

      # LD A, (HL)
      0x7E ->
        addr = bsl(h, 8) ||| l
        value = Map.get(ram, addr, :binary.at(rom, addr))
        loop(rom, ram, steps - 1, cycles + 8, value, f, b, c, d, e, h, l, sp, pc + 1 &&& 0xFFFF)
    end
  end
end
