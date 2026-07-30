defmodule Atomboy.Native.Interp do
  @moduledoc """
  The SM83 interpreter, assembled -- driver, fetch, jump table, handlers.

  ## Dispatch, finally in constant time

  `Atomboy.CPU.Gen` dispatches through a binary tree of integer comparisons.
  That is not a choice: AtomVM's JIT compiles a `select_val` as a linear scan,
  and the measured cost climbed by a factor of 10.6 between the table's first
  opcode and its hundred-and-eightieth. On bare RISC-V the constraint vanishes,
  and dispatch becomes what it always should have been: a shift, an add, a load,
  a jump. Nine instructions from the budget check to the handler, whatever the
  opcode.

  ## The fetch's order is observable

  Budget, then promoting an armed EI, then HALT, then interrupt service, then
  dispatch -- that is `Atomboy.CPU.Loop.fetch/17`'s order, and copying it is not
  politeness. Any permutation diverges from the oracle on programs arming an EI
  just before an interrupt, and the equivalence test is what will say so, weeks
  after the mistake.

  The three bits for IME, HALT and armed-EI share one register so the fast path
  clears all three with a single `bnez`: outside an interrupt handler, where IME
  is off, the cost is nothing. When IME is on -- a game's normal state -- every
  instruction pays a read of IF and IE, exactly as `Atomboy.CPU.Loop` pays it
  today. Caching `IF & IE` and invalidating it on writes is the obvious
  optimisation; it comes after the first honest number, not before.

  ## The protocol

  The image carries the initial state, the budget and the 64 KB of memory; it
  returns a 24-byte record followed by the final 64 KB, over the serial port.
  Nothing crosses during execution: everything is baked into the image and
  everything comes out at the end. A harness with no dialogue is a harness that
  cannot lose sync.
  """

  import Bitwise

  alias Atomboy.CPU.Insn
  alias Atomboy.CPU.State
  alias Atomboy.CPU.Table
  alias Atomboy.Native.ALU
  alias Atomboy.Native.Asm
  alias Atomboy.Native.Bus
  alias Atomboy.Native.Emit
  alias Atomboy.Native.Image
  alias Atomboy.Native.Regs
  alias Atomboy.Native.RV32

  @ime Regs.control_bits().ime
  @halted Regs.control_bits().halted
  @pending Regs.control_bits().pending

  @magic 0xA5
  @record_size 24
  @instret 0xC02
  @memory 0x10000

  # `unsupported_state` disappeared with stage eight: there is no longer a state
  # the guest refuses to run.
  @statuses %{ok: 0, unknown_opcode: 1}

  @doc "The status codes the guest can report."
  @spec statuses() :: %{atom() => 0..255}
  def statuses, do: @statuses

  @doc "The size of the result record, before the memory dump."
  @spec record_size() :: pos_integer()
  def record_size, do: @record_size

  @doc "The byte that opens a result record."
  @spec magic() :: 0..255
  def magic, do: @magic

  @doc """
  Assembles an image running `budget` T-cycles from `state` over `memory`.

  `memory` is 64 KB: the complete address space, flat. That is
  `Atomboy.CPU.Loop`'s contract, not `CartLoop`'s -- no MBC, no MMIO, no
  banking. Precisely the contract the SM83 vectors already validate.
  """
  @spec image(binary(), State.t(), pos_integer()) :: Asm.assembled()
  def image(memory, %State{} = state, budget) when byte_size(memory) == @memory do
    Image.build(
      [driver(), fetch(), slow_fetch(), exits(), handlers(), ALU.routines()],
      data(memory, state, budget)
    )
  end

  # ══ Le pilote ════════════════════════════════════════════════════════════════

  defp driver do
    [
      Asm.label(:driver),
      Asm.la(Regs.dispatch(), :table_base),
      Asm.la(Regs.mem(), :memory_gb),
      RV32.li(Regs.mask16(), 0xFFFF),
      RV32.li(Regs.cycles(), 0),
      Asm.la(:t2, :etat_initial),
      RV32.lbu(Regs.a(), :t2, 0),
      RV32.lbu(Regs.f(), :t2, 1),
      RV32.lbu(Regs.b(), :t2, 2),
      RV32.lbu(Regs.c(), :t2, 3),
      RV32.lbu(Regs.d(), :t2, 4),
      RV32.lbu(Regs.e(), :t2, 5),
      # H and L arrive split in the header and join here: the only place on the
      # native side where the pair is built.
      RV32.lbu(:t0, :t2, 6),
      RV32.lbu(:t1, :t2, 7),
      RV32.slli(:t0, :t0, 8),
      RV32.or_(Regs.hl(), :t0, :t1),
      RV32.lhu(Regs.sp(), :t2, 8),
      RV32.lhu(Regs.pc(), :t2, 10),
      RV32.lbu(Regs.control(), :t2, 12),
      RV32.lw(Regs.budget(), :t2, 16),
      # The baseline of the retired-instruction counter. Under
      # `qemu -icount shift=0` il est exact ; sans, il rend une valeur factice,
      # et c'est pourquoi le banc impose l'option.
      RV32.csrrs(:s9, @instret, :zero),
      Asm.j(:fetch)
    ]
  end

  # ══ Le fetch ═════════════════════════════════════════════════════════════════

  defp fetch do
    [
      Asm.label(:fetch),
      Asm.bgeu(Regs.cycles(), Regs.budget(), :to_materialise),
      Asm.bnez(Regs.control(), :to_slow),
      Asm.label(:fast),
      RV32.add(:t0, Regs.mem(), Regs.pc()),
      RV32.lbu(Regs.opcode(), :t0, 0),
      RV32.addi(Regs.pc(), Regs.pc(), 1),
      RV32.and_(Regs.pc(), Regs.pc(), Regs.mask16()),
      RV32.slli(:t0, Regs.opcode(), 2),
      RV32.add(:t0, Regs.dispatch(), :t0),
      RV32.lw(:t0, :t0, 0),
      RV32.jr(:t0),

      # The two trampolines sit right behind the `jr`, which never falls into
      # them. Their placement is not indifferent: a conditional branch only
      # reaches +/-4 KB, and the handlers will end up occupying far more than
      # that. Jumping close first, then far, puts range out of the question for
      # good.
      Asm.label(:to_materialise),
      Asm.j(:materialise),
      Asm.label(:to_slow),
      Asm.j(:slow_fetch)
    ]
  end

  # ══ Le chemin lent ═══════════════════════════════════════════════════════════
  #
  # L'ordre est celui de `Atomboy.CPU.Loop.fetch/17`, clause pour clause :
  # promoting an armed EI, then HALT, then interrupt service, then dispatch.
  # Copying it is not politeness -- a program arming an EI just before an
  # interrupt lands tells the permutations apart, and that is the kind of mistake
  # that surfaces weeks later.
  #
  # Each step re-enters `fetch` rather than falling through: a promoted EI must
  # be able to trigger a service in the same breath, and so must a wake from
  # HALT.
  defp slow_fetch do
    [
      Asm.label(:slow_fetch),

      # Armed EI: IME turns on, the arming falls away.
      RV32.andi(:t0, Regs.control(), @pending),
      Asm.beqz(:t0, :slow_halt),
      RV32.ori(Regs.control(), Regs.control(), @ime),
      RV32.andi(Regs.control(), Regs.control(), bnot(@pending)),
      Asm.j(:fetch),

      # HALT: the processor sleeps in 4 T steps while nothing is pending. Waking
      # is free and does not depend on IME -- a HALT wakes even with interrupts
      # masked; only the service needs IME.
      Asm.label(:slow_halt),
      RV32.andi(:t0, Regs.control(), @halted),
      Asm.beqz(:t0, :slow_irq),
      Asm.call(:pending_irq),
      Asm.bnez(:t1, :slow_wake),
      RV32.addi(Regs.cycles(), Regs.cycles(), 4),
      Asm.j(:fetch),
      Asm.label(:slow_wake),
      RV32.andi(Regs.control(), Regs.control(), bnot(@halted)),
      Asm.j(:fetch),

      # Only IME is left. With no pending source the instruction runs normally
      # -- hence a return into the fast path rather than a jump.
      Asm.label(:slow_irq),
      Asm.call(:pending_irq),
      Asm.beqz(:t1, :fast),
      service(),
      pending_irq()
    ]
  end

  # The service: PC goes onto the stack, IME turns off, the vector takes over.
  # 20 T, et l'on repasse par `fetch` — jamais par le dispatch.
  defp service do
    [
      # The lowest armed bit, isolated by two's complement.
      RV32.sub(:t4, :zero, :t1),
      RV32.and_(:t4, :t1, :t4),

      # IF is sampled **before** the pushes, as in the oracle: if the stack lands
      # on 0xFF0F, it is the earlier value that gets masked and written back.
      # The detail reads badly in `loop.ex:140-144` -- the `ram` in the third
      # write is the incoming one, not the piped one -- and it matters.
      RV32.lbu(:t6, :t0, 0),

      # The vector: 0x40 + 8 * the bit's index.
      RV32.li(:a0, 0x40),
      RV32.mv(:a1, :t4),
      Asm.label(:vector_loop),
      RV32.andi(:t3, :a1, 1),
      Asm.bnez(:t3, :vector_ready),
      RV32.srli(:a1, :a1, 1),
      RV32.addi(:a0, :a0, 8),
      Asm.j(:vector_loop),
      Asm.label(:vector_ready),
      Bus.move_stack(-2),
      Bus.write16(Regs.sp(), Regs.pc()),

      # The serviced bit falls out of IF.
      RV32.li(:t0, 0xFF0F),
      RV32.add(:t0, Regs.mem(), :t0),
      RV32.xori(:t1, :t4, 0xFF),
      RV32.and_(:t1, :t6, :t1),
      RV32.sb(:t1, :t0, 0),
      RV32.andi(Regs.control(), Regs.control(), bnot(@ime)),
      RV32.mv(Regs.pc(), :a0),
      RV32.addi(Regs.cycles(), Regs.cycles(), 20),
      Asm.j(:fetch)
    ]
  end

  # Returns in `t1` the armed and enabled sources, and leaves in `t0`
  # l'adresse de IF — dont le service se ressert.
  defp pending_irq do
    [
      Asm.label(:pending_irq),
      RV32.li(:t0, 0xFF0F),
      RV32.add(:t0, Regs.mem(), :t0),
      RV32.lbu(:t1, :t0, 0),
      # 0xFFFF - 0xFF0F: IE reads off the same pointer, displaced.
      RV32.lbu(:t2, :t0, 0xF0),
      RV32.and_(:t1, :t1, :t2),
      RV32.andi(:t1, :t1, 0x1F),
      RV32.ret()
    ]
  end

  # ══ Les sorties ══════════════════════════════════════════════════════════════

  defp exits do
    [
      Asm.label(:materialise),
      RV32.li(:t2, @statuses.ok),
      Asm.j(:report),
      Asm.label(:unknown_opcode),
      RV32.li(:t2, @statuses.unknown_opcode),
      report(),
      dump()
    ]
  end

  # `putc` only clobbers t0 and t1: t2 carries the status throughout, a1 the
  # opcode, and every state register survives.
  defp report do
    [
      Asm.label(:report),
      # Read before anything else: the report itself must not count.
      RV32.csrrs(:s10, @instret, :zero),
      RV32.sub(:s10, :s10, :s9),
      byte_out(RV32.li(:a0, @magic)),
      byte_out(RV32.mv(:a0, Regs.a())),
      byte_out(RV32.mv(:a0, Regs.f())),
      byte_out(RV32.mv(:a0, Regs.b())),
      byte_out(RV32.mv(:a0, Regs.c())),
      byte_out(RV32.mv(:a0, Regs.d())),
      byte_out(RV32.mv(:a0, Regs.e())),
      byte_out(RV32.srli(:a0, Regs.hl(), 8)),
      byte_out(RV32.andi(:a0, Regs.hl(), 0xFF)),
      byte_out(RV32.mv(:a0, Regs.sp())),
      byte_out(RV32.srli(:a0, Regs.sp(), 8)),
      byte_out(RV32.mv(:a0, Regs.pc())),
      byte_out(RV32.srli(:a0, Regs.pc(), 8)),
      byte_out(RV32.mv(:a0, Regs.control())),
      byte_out(RV32.mv(:a0, Regs.cycles())),
      byte_out(RV32.srli(:a0, Regs.cycles(), 8)),
      byte_out(RV32.srli(:a0, Regs.cycles(), 16)),
      byte_out(RV32.srli(:a0, Regs.cycles(), 24)),
      byte_out(RV32.mv(:a0, :t2)),
      byte_out(RV32.mv(:a0, Regs.opcode())),
      byte_out(RV32.mv(:a0, :s10)),
      byte_out(RV32.srli(:a0, :s10, 8)),
      byte_out(RV32.srli(:a0, :s10, 16)),
      byte_out(RV32.srli(:a0, :s10, 24))
    ]
  end

  # `sb` only lays down the low eight bits: nothing to mask before emitting.
  defp byte_out(load), do: [load, Asm.call(:putc)]

  defp dump do
    [
      Asm.label(:dump),
      RV32.mv(:t3, Regs.mem()),
      RV32.li(:t4, @memory),
      Asm.label(:dump_loop),
      Asm.beqz(:t4, :dump_done),
      RV32.lbu(:a0, :t3, 0),
      Asm.call(:putc),
      RV32.addi(:t3, :t3, 1),
      RV32.addi(:t4, :t4, -1),
      Asm.j(:dump_loop),
      Asm.label(:dump_done),
      Asm.j(:poweroff)
    ]
  end

  # ══ Les gestionnaires ════════════════════════════════════════════════════════

  defp handlers do
    base =
      for %Insn{prefix: nil} = insn <- Table.base(),
          (corps = Emit.body(insn)) != :unsupported do
        [Asm.label(label(insn.opcode)), corps]
      end

    etendus =
      for %Insn{prefix: :cb} = insn <- Table.extended(),
          (corps = Emit.body(insn)) != :unsupported do
        [Asm.label(label_cb(insn.opcode)), corps]
      end

    [prefix(), base, etendus]
  end

  # The 0xCB prefix is not an instruction: it reads another byte and jumps into
  # the second table. The two tables being contiguous, the second is reached
  # through a constant displacement of 1024 in the `lw` -- the base table is 256
  # four-byte entries, and 1024 fits a load's immediate.
  #
  # No cycles are counted here: for each extended instruction the table gives a
  # cost that already includes the prefix fetch.
  defp prefix do
    [
      Asm.label(:h_cb),
      RV32.add(:t0, Regs.mem(), Regs.pc()),
      RV32.lbu(:t0, :t0, 0),
      RV32.addi(Regs.pc(), Regs.pc(), 1),
      RV32.and_(Regs.pc(), Regs.pc(), Regs.mask16()),
      RV32.slli(:t0, :t0, 2),
      RV32.add(:t0, Regs.dispatch(), :t0),
      RV32.lw(:t0, :t0, 4 * 256),
      RV32.jr(:t0)
    ]
  end

  # ══ The data ═════════════════════════════════════════════════════════════════

  defp data(memory, state, budget) do
    [
      {:align, 4},
      Asm.label(:table_base),
      table_base(),
      # Contiguous, with no alignment in between: the prefix relies on a
      # displacement of exactly 1024.
      Asm.label(:table_cb),
      table_cb(),
      {:align, 4},
      Asm.label(:etat_initial),
      header(state, budget),
      {:align, 4},
      Asm.label(:memory_gb),
      memory
    ]
  end

  # All 256 entries always exist, even for an opcode the current stage cannot
  # emit: that is what lets dispatch be unconditional. A missing opcode lands on
  # a handler that reports it, never in code that was not meant for it.
  defp table_base do
    covered = covered(nil)

    for opcode <- 0..0xFF do
      cond do
        opcode == Emit.cb_prefix() and Emit.prefix_covered?() -> {:addr, :h_cb}
        MapSet.member?(covered, opcode) -> {:addr, label(opcode)}
        true -> {:addr, :unknown_opcode}
      end
    end
  end

  defp table_cb do
    covered = covered(:cb)

    for opcode <- 0..0xFF do
      if MapSet.member?(covered, opcode) do
        {:addr, label_cb(opcode)}
      else
        {:addr, :unknown_opcode}
      end
    end
  end

  defp covered(prefixe) do
    MapSet.new(for {^prefixe, opcode} <- Emit.coverage(), do: opcode)
  end

  defp label(opcode), do: :"h_#{Integer.to_string(opcode, 16)}"
  defp label_cb(opcode), do: :"cb_#{Integer.to_string(opcode, 16)}"

  defp header(%State{} = state, budget) do
    control =
      state.ime + if(state.halted, do: 2, else: 0) + state.ime_pending * 4

    <<state.a, state.f, state.b, state.c, state.d, state.e, state.h, state.l, state.sp::16-little,
      state.pc::16-little, control, 0, 0, 0, budget::32-little>>
  end
end
