defmodule Atomboy.AtomVM.Main do
  @moduledoc """
  The embedded entry point: smoke test, then throughput measurement, on AtomVM.

  Runs identically on the `generic_unix` build (Mac) and on ESP32 — it is the
  same `.avm`. The Mac run serves as a control: if an ESP32 figure looks
  aberrant, compare it first against the same program on the same VM locally.

  ## Why this bench is not `mix atomboy.bench`

  The Mix bench fills the whole 64 KB of address space with `LD B, C`, which
  means a 65,536-entry map. The ESP32 firmware in use does not enable PSRAM:
  the heap lives in internal SRAM, and a map that size does not fit.

  Here, memory holds only the smoke test's little program; all the rest of the
  space reads 0, that is, `NOP`. The throughput measured is therefore that of a
  fetch + dispatch + NOP loop: a **ceiling**, not an average. The useful
  comparison is ESP32 against Mac *on this very program*, not against the Mix
  bench.

  ## Expected figure

  The brief estimates AtomVM/ESP32 at 20,000–100,000 Game Boy instructions per
  second, without measuring. That is precisely what this module is here to
  replace with a number.
  """

  alias Atomboy.CPU.State
  alias Atomboy.Memory.Flat

  # :atomvm exists only under AtomVM; on OTP this module never runs.
  @compile {:no_warn_undefined, :atomvm}

  # LD B,C ; LD (HL),B ; LD A,(HL) ; NOP — the same program as the smoke test
  # of the generic_unix guardrail.
  @program %{0x0000 => 0x41, 0x0001 => 0x70, 0x0002 => 0x7E, 0x0003 => 0x00}

  # The bench is bounded in time, not in steps: 5 s of measurement whatever the
  # speed of the target. The step-bounded version cost 158 s on ESP32 at
  # 631 instr/s — a figure that was precisely what nobody knew before
  # measuring, which is the whole irony of a bench whose duration depends on
  # its result.
  @budget_ms 5_000
  @chunk 1_000
  @max_steps 10_000_000

  def start do
    :erlang.display({:atomboy, :smoke})
    smoke()

    :erlang.display({:atomboy, :bench})
    bench()

    :erlang.display({:atomboy, :probe})
    Atomboy.AtomVM.Probe.bench()

    :erlang.display({:atomboy, :loop})
    loop_bench()

    :erlang.display({:atomboy, :done})

    # On ESP32, a start/0 that returns can reboot the board and drown the
    # result in the boot logs: so we stay alive. On generic_unix it is the
    # opposite — standard output is only flushed when the process terminates,
    # so we have to exit for anyone to see anything at all.
    case :atomvm.platform() do
      :esp32 -> idle()
      _ -> 0
    end
  end

  defp smoke do
    mem = Flat.new(@program)
    state = %State{c: 0x42, h: 0xC0, sp: 0xFFFE}

    {final, mem, cycles} = run(state, mem, 4, 0)

    checks = [
      {:b, final.b, 0x42},
      {:a, final.a, 0x42},
      {:pc, final.pc, 0x0004},
      {:mem_c000, Flat.read8(mem, 0xC000), 0x42},
      {:cycles, cycles, 24}
    ]

    case Enum.reject(checks, fn {_name, got, want} -> got == want end) do
      [] ->
        :erlang.display(:smoke_ok)

      bad ->
        :erlang.display(:smoke_failed)

        Enum.each(bad, fn {name, got, want} -> :erlang.display({name, :got, got, :want, want}) end)
    end
  end

  defp bench do
    mem = Flat.new(@program)
    state = %State{c: 0x42, h: 0xC0, sp: 0xFFFE}

    # Warm-up lap: steadies the measurement, and checks that the loop fits in
    # memory before setting off for five seconds.
    run(state, mem, @chunk, 0)

    {steps, elapsed} =
      measure({state, mem}, fn {state, mem} ->
        {state, mem, _cycles} = run(state, mem, @chunk, 0)
        {{state, mem}, @chunk}
      end)

    # All in integers: no dependency on AtomVM's float formatting.
    per_second = if elapsed > 0, do: div(steps * 1000, elapsed), else: :too_fast

    :erlang.display({:steps, steps})
    :erlang.display({:elapsed_ms, elapsed})
    :erlang.display({:instructions_per_second, per_second})
  end

  defp run(state, mem, 0, cycles), do: {state, mem, cycles}

  defp run(state, mem, steps, cycles) do
    {state, mem, step_cycles} = Atomboy.CPU.step(state, mem)
    run(state, mem, steps - 1, cycles + step_cycles)
  end

  @doc false
  # Measures in slices: each call to `slice` returns `{acc, units}`; we add up
  # the **active** time alone, and hand control back between two slices.
  #
  # The breath between slices is not decorative: on ESP32, a BEAM loop that
  # hogs the AtomVM task for five seconds starves FreeRTOS's IDLE task, and the
  # task watchdog barks in the console every five seconds. The `receive after`
  # blocks the task for a moment, IDLE breathes, and the time slept does not
  # enter the measurement. The frame loop of the real phase 3 will have to do
  # the same.
  def measure(acc, slice, units \\ 0, active_ms \\ 0) do
    t0 = :erlang.monotonic_time(:millisecond)
    {acc, slice_units} = slice.(acc)
    active_ms = active_ms + :erlang.monotonic_time(:millisecond) - t0
    units = units + slice_units

    if active_ms >= @budget_ms or units >= @max_steps do
      {units, active_ms}
    else
      breathe()
      measure(acc, slice, units, active_ms)
    end
  end

  # 20 ms and no less: on ESP32, AtomVM converts this delay into FreeRTOS ticks
  # by integer division (`timeout_ms / portTICK_PERIOD_MS`, a 10 ms tick with
  # CONFIG_FREERTOS_HZ=100). A delay below the tick amounts to zero — the task
  # does not block at all, IDLE stays starved and the watchdog barks exactly as
  # it does without a breath. Lived, not deduced.
  defp breathe do
    receive do
    after
      20 -> :ok
    end
  end

  # One DMG frame: 154 scanlines × 456 T-cycles.
  @frame_cycles 70_224
  # The T-cycle throughput a DMG sustains: 4.194304 MHz.
  @dmg_hz 4_194_304

  # A 16-byte block — 12 varied instructions, 64 T-cycles — repeated over the
  # whole address space. Its predecessor was a parade of NOPs: the best-placed
  # opcode in the dispatch, a bench that measured the complacency of its own
  # program (a ×10.6 spread observed depending on where the dominant opcode
  # sat, before the binary tree). This block fires across the whole table, CB
  # prefix included.
  @bench_block <<0x3E, 0x55, 0x06, 0x33, 0x80, 0x04, 0xB1, 0x2F, 0xCB, 0x37, 0xA8, 0x15, 0x1F,
                 0xE6, 0x0F, 0x7D>>

  defp bench_rom, do: :binary.copy(@bench_block, div(0x10000, byte_size(@bench_block)))

  # The fast loop, called the way the frame loop will call it: one frame's
  # budget per call, the state materialised in between, and CartLoop's
  # cartridge semantics — ROM fetch with no map lookup, the memory model of a
  # real game. The number it returns is the one that matters for the project —
  # the percentage of real time.
  defp loop_bench do
    rom = bench_rom()
    state = %State{c: 0x42, h: 0xC0, sp: 0xFFFE}

    {_state, _ram, _cycles} = Atomboy.CPU.CartLoop.run(state, rom, %{}, @frame_cycles)

    {frames, elapsed} =
      measure(state, fn state ->
        # The ram starts empty again on every frame: the bench measures the
        # CPU, not the growth of a map of writes that no PPU consumes yet.
        {state, _ram, _cycles} = Atomboy.CPU.CartLoop.run(state, rom, %{}, @frame_cycles)
        {state, 1}
      end)

    cycles = frames * @frame_cycles
    per_second = if elapsed > 0, do: div(cycles * 1000, elapsed), else: :too_fast

    :erlang.display({:loop_frames, frames})
    :erlang.display({:loop_elapsed_ms, elapsed})
    :erlang.display({:loop_cycles_per_second, per_second})

    if is_integer(per_second) do
      :erlang.display({:loop_realtime_percent, div(per_second * 100, @dmg_hz)})
    end
  end

  defp idle do
    receive do
    after
      60_000 ->
        :erlang.display({:atomboy, :idle})
        idle()
    end
  end
end
