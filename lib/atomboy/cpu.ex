defmodule Atomboy.CPU do
  @moduledoc """
  The Game Boy DMG's SM83 CPU (Sharp LR35902).

  This is **not** a Z80: no IX/IY, no shadow registers, no DD/ED/FD prefixes,
  different flags, and opcodes that exist nowhere else (`LDH`, `LD (HL+)`,
  `SWAP`, `STOP`). Any Z80 table lifted as-is will be wrong.

  ## State

  The whole processor state fits in one `Atomboy.CPU.State` — registers, flags
  and interrupt state. Memory is threaded alongside, as a second term: its shape
  depends on the backend (see `Atomboy.Memory`).

  ## The known cost, and where it goes

  `exec/3` returns `{state, mem, t_cycles}` — one tuple allocation per
  instruction, plus a copy of the struct whenever a register changes. That is
  accepted for phase 1, where correctness is the only criterion and where the
  SingleStepTests harness needs to observe the state after every instruction.

  Removing that cost is already mapped out: instead of returning, `exec/3` will
  tail-call the next fetch and materialise the result only when the cycle budget
  runs out — once per scanline instead of once per instruction. The switch
  happens inside the generator, not across 500 clauses: that is the whole point
  of `Atomboy.CPU.Gen`.

  ## Cycles

  Counted in **T-cycles** (4,194,304 per second), not M-cycles. The PPU thinks
  in T-cycles — 456 per scanline — and that is the granularity the frame loop
  will synchronise on. The SingleStepTests vectors, for their part, list one bus
  access per M-cycle: the conversion is `length(cycles) * 4`.
  """

  import Bitwise

  alias Atomboy.CPU.Gen
  alias Atomboy.CPU.Insn
  alias Atomboy.CPU.State
  alias Atomboy.CPU.Table

  require Gen

  @typedoc "Opcode prefix: `nil` for the base table, `:cb` for the extended one."
  @type prefix :: nil | :cb

  # Resolved at compile time: no dynamic dispatch on the hot path. Phase 3
  # switches to the NIF backend through configuration, without touching the CPU.
  @mem Application.compile_env(:atomboy, :memory, Atomboy.Memory.Flat)

  @doc "The `Atomboy.Memory` module compiled into this CPU."
  @spec memory_backend() :: module()
  def memory_backend, do: @mem

  Module.register_attribute(__MODULE__, :implemented, accumulate: true)

  @doc """
  Runs one instruction: fetch at `pc`, decode, execute.

  Returns `{state, mem, t_cycles}`. **No hardware**: no interrupt servicing, no
  wake from HALT — that is the contract of the SingleStepTests vectors, which
  model the instruction and nothing else. The complete step, interrupt
  controller included, is `tick/2`.
  """
  @spec step(State.t(), Atomboy.Memory.t()) ::
          {State.t(), Atomboy.Memory.t(), pos_integer()}
  def step(%State{pc: pc} = st, mem) do
    # An EI armed earlier is promoted on entering the next step — the same point
    # as the fast loop's fetch, so that the two backends stay indistinguishable.
    st = if st.ime_pending == 1, do: %{st | ime: 1, ime_pending: 0}, else: st

    opcode = @mem.read8(mem, pc)
    # PC is advanced before execution, so the generated clauses only have to
    # deal with it when they jump — the minority case.
    exec(opcode, %{st | pc: pc + 1 &&& 0xFFFF}, mem)
  end

  # The five sources, in the hardware's priority order: vblank, STAT, timer,
  # serial, joypad. Vectors 0x40, 0x48, 0x50, 0x58, 0x60.
  @irq_if 0xFF0F
  @irq_ie 0xFFFF

  @doc """
  One complete machine step: EI promotion, HALT sleep, interrupt servicing, then
  the instruction.

  This is the exact mirror of the fast loops' fetch — same order, same cycles —
  and it is what the cross-equivalence test drives. A step yields one of:

    * a sleep cycle (4 T) — HALT with no interrupt pending;
    * a service (20 T) — IME set and a source pending: IME drops, the IF bit
      clears, PC goes onto the stack, the vector takes over;
    * an instruction, through `step/2`.

  IF and IE are read **from memory** (0xFF0F / 0xFFFF), not from the struct's
  `ie` field — memory is where programs write them.
  """
  @spec tick(State.t(), Atomboy.Memory.t()) ::
          {State.t(), Atomboy.Memory.t(), pos_integer()}
  def tick(%State{} = st, mem) do
    st = if st.ime_pending == 1, do: %{st | ime: 1, ime_pending: 0}, else: st
    irq = @mem.read8(mem, @irq_if) &&& @mem.read8(mem, @irq_ie) &&& 0x1F

    cond do
      st.halted and irq == 0 ->
        {st, mem, 4}

      st.halted ->
        # Waking up is free; any servicing happens on the next step, exactly as
        # in the loops.
        tick(%{st | halted: false}, mem)

      st.ime == 1 and irq != 0 ->
        service(st, mem, irq)

      true ->
        step(st, mem)
    end
  end

  defp service(%State{sp: sp, pc: pc} = st, mem, irq) do
    # The lowest pending bit wins.
    bit = irq &&& -irq
    index = index_of(bit)
    new_sp = sp - 2 &&& 0xFFFF
    mem = @mem.write16(mem, new_sp, pc)
    mem = @mem.write8(mem, @irq_if, @mem.read8(mem, @irq_if) &&& bxor(bit, 0xFF))
    {%{st | ime: 0, sp: new_sp, pc: 0x40 + index * 8}, mem, 20}
  end

  defp index_of(0x01), do: 0
  defp index_of(0x02), do: 1
  defp index_of(0x04), do: 2
  defp index_of(0x08), do: 3
  defp index_of(0x10), do: 4

  # ── The dispatch ────────────────────────────────────────────────────────────
  #
  # Nothing to read here: the instructions are described in `Atomboy.CPU.Table`
  # and translated into code by `Atomboy.CPU.Gen`. The dispatch is a two-level
  # tree, not flat clauses — see Gen's comment on the AtomVM JIT's linear
  # select_val. 0xCB is just another entry there, one that fetches the second
  # byte and dispatches again.

  for %Insn{prefix: nil} = insn <- Table.base(), do: @implemented({nil, insn.opcode})
  @implemented {nil, 0xCB}
  for %Insn{prefix: :cb} = insn <- Table.extended(), do: @implemented({:cb, insn.opcode})

  @doc false
  def exec(unquote_splicing(Gen.head_args(:struct))) do
    unquote(
      Gen.struct_dispatch(
        Table.base(),
        [Gen.struct_cb_entry()],
        Gen.unimplemented(:unimplemented_base)
      )
    )
  end

  defp exec_cb(unquote_splicing(Gen.head_args(:struct))) do
    unquote(Gen.struct_dispatch(Table.extended(), [], Gen.unimplemented(:unimplemented_cb)))
  end

  @doc """
  The implemented opcodes, as `{prefix, opcode}`.

  Accumulated at compile time by the clauses themselves: this list and the
  decoder cannot possibly drift apart. It is what the SM83 harness enumerates to
  know which corpus files to replay, and it is phase 1's measure of progress.
  """
  @spec implemented() :: [{prefix(), 0..0xFF}]
  def implemented, do: Enum.sort(@implemented)

  defp unimplemented_base(opcode) do
    raise Atomboy.CPU.Unimplemented, opcode: opcode, prefix: nil
  end

  defp unimplemented_cb(opcode) do
    raise Atomboy.CPU.Unimplemented, opcode: opcode, prefix: :cb
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  @compile {:inline,
            mem_read: 2,
            mem_read_at: 2,
            mem_read16_at: 2,
            mem_read_pc: 2,
            mem_read_pc16: 2,
            mem_write: 3,
            mem_write_at: 3,
            mem_write16_at: 3}

  defp mem_read(mem, %State{h: h, l: l}), do: @mem.read8(mem, bsl(h, 8) ||| l)

  # Access at a computed address — the indirects (BC), (DE), (HL±), (a16), the
  # stack.
  defp mem_read_at(mem, addr), do: @mem.read8(mem, addr)
  defp mem_read16_at(mem, addr), do: @mem.read16(mem, addr)
  defp mem_write_at(mem, addr, value), do: @mem.write8(mem, addr, value)
  defp mem_write16_at(mem, addr, value), do: @mem.write16(mem, addr, value)

  # The byte at PC — the immediate operands. `step/2` has already advanced PC
  # past the opcode, so PC points exactly at the immediate.
  defp mem_read_pc(mem, %State{pc: pc}), do: @mem.read8(mem, pc)

  # The word at PC, little-endian — the memory behaviour's bulk accessor,
  # precisely the kind of access the brief asked to group.
  defp mem_read_pc16(mem, %State{pc: pc}), do: @mem.read16(mem, pc)

  defp mem_write(mem, %State{h: h, l: l}, value), do: @mem.write8(mem, bsl(h, 8) ||| l, value)
end

defmodule Atomboy.CPU.Unimplemented do
  @moduledoc """
  An opcode the decoder does not cover yet.

  Kept distinct from a `FunctionClauseError`: on a corpus of 500 opcodes built up
  in increments, "not written yet" and "written but wrong" are two different
  situations, and the test harness has to be able to tell them apart.
  """

  defexception [:opcode, :prefix, :pc, :bank]

  @impl true
  def message(%{opcode: opcode, prefix: prefix} = e) do
    label = if prefix == :cb, do: "CB #{hex(opcode)}", else: hex(opcode)

    where =
      case {e.pc, e.bank} do
        {nil, _} -> ""
        {pc, nil} -> " at PC 0x#{hex4(pc)}"
        {pc, bank} -> " at PC 0x#{hex4(pc)}, ROM bank #{bank}"
      end

    "opcode #{label} not implemented#{where}"
  end

  defp hex(opcode), do: opcode |> Integer.to_string(16) |> String.pad_leading(2, "0")
  defp hex4(v), do: v |> Integer.to_string(16) |> String.pad_leading(4, "0")
end

defmodule Atomboy.CPU.Derailed do
  @moduledoc """
  The PC has wandered into VRAM — no game does that on purpose.

  Control derailed further upstream: a jump table indexed out of bounds, a
  smashed stack, `jp hl` on a tile pointer… The invalid opcode that would
  eventually surface from the wreckage comes too late to explain anything; the
  report here photographs the moment of entry instead: registers, bank, and the
  top of the stack — the return addresses in it name the culprit.
  """

  defexception [:pc, :sp, :bank, :regs, :stack]

  @impl true
  def message(%{pc: pc, sp: sp, bank: bank, regs: regs, stack: stack}) do
    {a, f, b, c, d, e, h, l} = regs

    frames =
      stack
      |> Enum.map(&("0x" <> hex4(&1)))
      |> Enum.join(" ")

    "the processor derailed into VRAM: PC 0x#{hex4(pc)}, ROM bank #{bank}\n" <>
      "    AF=#{hex(a)}#{hex(f)} BC=#{hex(b)}#{hex(c)} DE=#{hex(d)}#{hex(e)} " <>
      "HL=#{hex(h)}#{hex(l)} SP=0x#{hex4(sp)}\n" <>
      "    stack: #{frames}"
  end

  defp hex(v), do: v |> Integer.to_string(16) |> String.pad_leading(2, "0")
  defp hex4(v), do: v |> Integer.to_string(16) |> String.pad_leading(4, "0")
end
