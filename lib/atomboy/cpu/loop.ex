defmodule Atomboy.CPU.Loop do
  @moduledoc """
  The fast loop: the same CPU as `Atomboy.CPU`, with no map on the hot path.

  Generated from the same `Atomboy.CPU.Table` as the oracle, with the same
  `Atomboy.CPU.ALU` primitives — only the calling convention changes:

    * the ten registers travel as **function arguments**, never inside a struct;
      in AOT native code they become machine registers;
    * every instruction ends in a **tail call** to the next fetch — no return
      value per step, no allocation;
    * the fetch reads a **ROM binary** (`:binary.at/2`), not a map;
    * the state is only materialised into an `Atomboy.CPU.State` once the **cycle
      budget** runs out — once per scanline in the frame loop, instead of once
      per instruction.

  Memory writes go into a map threaded through as an argument: rare compared to
  the fetch, and replaceable by the brief's NIF resource without touching a
  single clause — the generator is the only thing that knows about `ram_write/3`.

  ## Contract

  `run/4` executes whole instructions until the cycle counter **reaches or
  exceeds** the budget: the last instruction may overshoot, and the overshoot is
  visible in the returned count. The PPU will absorb that surplus by deducting it
  from the next budget.

  Interrupts: `ime` travels through the loop — RETI switches it back on, EI/DI
  will manipulate it. `ie` and `halted` pass through `run/4` unchanged as long as
  no instruction touches them.

  This module's correctness is not tested directly: it is inherited. The oracle
  passes the SM83 vectors; the cross-equivalence test checks that `run/4`
  produces, on random programs, exactly the state and memory of N oracle steps.
  """

  import Bitwise

  alias Atomboy.CPU.Gen
  alias Atomboy.CPU.State
  alias Atomboy.CPU.Table

  require Gen

  @typedoc "The ROM: the 64 KB address space, immutable."
  @type rom :: binary()

  @typedoc "The writes: address → byte, taking priority over the ROM on reads."
  @type ram :: %{optional(0..0xFFFF) => 0..0xFF}

  @doc """
  Runs from `state` for up to `budget` T-cycles. Returns
  `{state, ram, cycles_consumed}`.
  """
  @spec run(State.t(), rom(), ram(), pos_integer()) :: {State.t(), ram(), non_neg_integer()}
  def run(%State{} = st, rom, ram, budget) when byte_size(rom) == 0x10000 do
    {{a, f, b, c, d, e, h, l, sp, pc, ime, halted, ime_pending}, ram, cycles} =
      fetch(
        rom,
        ram,
        budget,
        0,
        st.a,
        st.f,
        st.b,
        st.c,
        st.d,
        st.e,
        st.h,
        st.l,
        st.sp,
        st.pc,
        st.ime,
        st.halted,
        st.ime_pending
      )

    {%{
       st
       | a: a,
         f: f,
         b: b,
         c: c,
         d: d,
         e: e,
         h: h,
         l: l,
         sp: sp,
         pc: pc,
         ime: ime,
         halted: halted,
         ime_pending: ime_pending
     }, ram, cycles}
  end

  # ── Fetch ───────────────────────────────────────────────────────────────────

  # Budget exhausted: materialisation, the loop's one and only construction.
  defp fetch(_rom, ram, budget, cycles, a, f, b, c, d, e, h, l, sp, pc, ime, halted, ime_pending)
       when cycles >= budget do
    {{a, f, b, c, d, e, h, l, sp, pc, ime, halted, ime_pending}, ram, cycles}
  end

  # Promoting an armed EI — the same point as in the oracle: entering the step.
  defp fetch(rom, ram, budget, cycles, a, f, b, c, d, e, h, l, sp, pc, _ime, halted, 1) do
    fetch(rom, ram, budget, cycles, a, f, b, c, d, e, h, l, sp, pc, 1, halted, 0)
  end

  # The fetch goes through the same rom+ram view as operand reads: the Game Boy
  # really does execute code out of RAM (the OAM-DMA routines run in HRAM), and
  # the equivalence test demanded it on its very first run — random programs
  # self-modify. The extra cost is one map lookup on the writes map; the day the
  # real MMU lands, the split by region (ROM fetch without the map, RAM fetch
  # with it) will happen in the generator.
  # HALT: the processor sleeps in 4 T steps as long as nothing is pending — the
  # same granularity as the oracle's tick, and the equivalence depends on it.
  # Waking up is free; any servicing happens on the next pass.
  defp fetch(rom, ram, budget, cycles, a, f, b, c, d, e, h, l, sp, pc, ime, true, pending) do
    if (mem_read(rom, ram, 0xFF0F) &&& mem_read(rom, ram, 0xFFFF) &&& 0x1F) == 0 do
      fetch(rom, ram, budget, cycles + 4, a, f, b, c, d, e, h, l, sp, pc, ime, true, pending)
    else
      fetch(rom, ram, budget, cycles, a, f, b, c, d, e, h, l, sp, pc, ime, false, pending)
    end
  end

  # IME set: a pending source diverts execution — IME drops, the IF bit clears,
  # PC goes onto the stack, the vector takes over. 20 T.
  defp fetch(rom, ram, budget, cycles, a, f, b, c, d, e, h, l, sp, pc, 1, halted, pending) do
    irq = mem_read(rom, ram, 0xFF0F) &&& mem_read(rom, ram, 0xFFFF) &&& 0x1F

    if irq == 0 do
      dispatch(rom, ram, budget, cycles, a, f, b, c, d, e, h, l, sp, pc, 1, halted, pending)
    else
      bit = irq &&& -irq
      vector = 0x40 + irq_index(bit) * 8
      new_sp = sp - 2 &&& 0xFFFF

      ram =
        ram
        |> ram_write(new_sp, pc &&& 0xFF)
        |> ram_write(new_sp + 1 &&& 0xFFFF, pc >>> 8)
        |> ram_write(0xFF0F, mem_read(rom, ram, 0xFF0F) &&& bxor(bit, 0xFF))

      fetch(
        rom,
        ram,
        budget,
        cycles + 20,
        a,
        f,
        b,
        c,
        d,
        e,
        h,
        l,
        new_sp,
        vector,
        0,
        halted,
        pending
      )
    end
  end

  defp fetch(rom, ram, budget, cycles, a, f, b, c, d, e, h, l, sp, pc, ime, halted, ime_pending) do
    dispatch(rom, ram, budget, cycles, a, f, b, c, d, e, h, l, sp, pc, ime, halted, ime_pending)
  end

  defp dispatch(
         rom,
         ram,
         budget,
         cycles,
         a,
         f,
         b,
         c,
         d,
         e,
         h,
         l,
         sp,
         pc,
         ime,
         halted,
         ime_pending
       ) do
    exec(
      mem_read(rom, ram, pc),
      rom,
      ram,
      budget,
      cycles,
      a,
      f,
      b,
      c,
      d,
      e,
      h,
      l,
      sp,
      pc + 1 &&& 0xFFFF,
      ime,
      halted,
      ime_pending
    )
  end

  defp irq_index(0x01), do: 0
  defp irq_index(0x02), do: 1
  defp irq_index(0x04), do: 2
  defp irq_index(0x08), do: 3
  defp irq_index(0x10), do: 4

  # ── The dispatch ────────────────────────────────────────────────────────────
  #
  # A two-level tree emitted by Gen — see its comment on the JIT's linear
  # select_val. 0xCB fetches the second byte and dispatches again into exec_cb,
  # the same tree over the extended table.

  defp exec(unquote_splicing(Gen.head_args(:loop))) do
    unquote(
      Gen.loop_dispatch(
        Table.base(),
        [Gen.loop_cb_entry()],
        Gen.unimplemented_at(:unimplemented_base)
      )
    )
  end

  defp exec_cb(unquote_splicing(Gen.head_args(:loop))) do
    unquote(Gen.loop_dispatch(Table.extended(), [], Gen.unimplemented_at(:unimplemented_cb)))
  end

  defp unimplemented_base(opcode, pc, _ram) do
    raise Atomboy.CPU.Unimplemented, opcode: opcode, prefix: nil, pc: pc - 1 &&& 0xFFFF
  end

  defp unimplemented_cb(opcode, pc, _ram) do
    raise Atomboy.CPU.Unimplemented, opcode: opcode, prefix: :cb, pc: pc - 2 &&& 0xFFFF
  end

  # ── Memory ──────────────────────────────────────────────────────────────────

  @compile {:inline, mem_read: 3, ram_write: 3}

  # Writes mask the ROM. `0` is a valid value: falling back to the ROM only
  # happens on genuine absence (`nil`).
  defp mem_read(rom, ram, addr) do
    case ram do
      %{^addr => value} -> value
      _ -> :binary.at(rom, addr)
    end
  end

  defp ram_write(ram, addr, value), do: Map.put(ram, addr, value)
end
