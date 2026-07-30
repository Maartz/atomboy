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

  ## Why this module has two faces

  `image/3` assembles a complete, runnable interpreter: that is what the
  equivalence tests and the bench task use. But the interpreter is not the only
  thing that wants a fetch, a slow path, an interrupt service and a jump table --
  `Atomboy.Native.Machine` wraps a console's cadence around exactly the same
  skeleton, and the *only* thing it needs to change is where an exhausted budget
  lands: on its end-of-scanline code rather than on this module's exit.

  So the skeleton is exposed piece by piece -- `prologue/0`, `routines/1`,
  `handlers/0`, `tables/0`, `exits/1`, `header/3` -- with that one edge as an
  argument, and `image/3` is written in terms of them like any other caller. The
  machine loop used to carry its own copy of some sixty instructions whose
  semantics are pinned by `Atomboy.CPU.Loop.fetch/17`; a second copy of a
  hardware contract is a second thing to get wrong, and it took a parameter to
  remove it.

  ## The protocol

  The image carries the initial state, the budget and the 64 KB of memory; it
  returns a 24-byte record followed by the final 64 KB, over the serial port.
  Nothing crosses during execution: everything is baked into the image and
  everything comes out at the end. A harness with no dialogue is a harness that
  cannot lose sync.

  `exits/1` takes the regions that follow the record as a list, and that is what
  keeps the protocol extensible without being rewritten: a caller appends what it
  has to send -- `Atomboy.Native.Machine` sends a frame and its timer phase --
  and a reader that knows only the record and the memory still finds them exactly
  where they were.
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

  # Where each field sits in the header the image carries. Bytes 13 to 15 were
  # padding until the timer's sub-counters moved in: an image that can be handed
  # a phase is an image whose runs chain.
  @header %{div: 13, tima: 14, word: 16}

  # `unsupported_state` disappeared with stage eight: there is no longer a state
  # the guest refuses to run.
  @statuses %{ok: 0, unknown_opcode: 1}

  @doc "The status codes the guest can report."
  @spec statuses() :: %{atom() => 0..255}
  def statuses, do: @statuses

  @doc "The size of the result record, before the regions that follow it."
  @spec record_size() :: pos_integer()
  def record_size, do: @record_size

  @doc "The byte that opens a result record."
  @spec magic() :: 0..255
  def magic, do: @magic

  @doc """
  Where each field sits in the image's header, in bytes.

  `:word` is the last one, and its meaning belongs to the caller: a cycle budget
  here, a frame count one level up.
  """
  @spec header_offsets() :: %{div: 13, tima: 14, word: 16}
  def header_offsets, do: @header

  @doc """
  Assembles an image running `budget` T-cycles from `state` over `memory`.

  `memory` is 64 KB: the complete address space, flat. That is
  `Atomboy.CPU.Loop`'s contract, not `CartLoop`'s -- no MBC, no MMIO, no
  banking. Precisely the contract the SM83 vectors already validate.
  """
  @spec image(binary(), State.t(), pos_integer()) :: Asm.assembled()
  def image(memory, %State{} = state, budget) when byte_size(memory) == @memory do
    Image.build(
      [
        driver(),
        routines(),
        exits([{:memory, [Asm.la(:t3, :memory_gb)], @memory}]),
        Bus.flat_seam(),
        handlers(),
        ALU.routines()
      ],
      data(memory, state, budget)
    )
  end

  # ══ Le pilote ════════════════════════════════════════════════════════════════

  defp driver do
    [
      prologue(),
      Bus.bounds(:flat),
      RV32.lw(Regs.budget(), :t2, @header.word),
      instret_baseline(),
      Asm.j(:fetch)
    ]
  end

  @doc """
  The driver's preamble: the registers a run needs, and the state out of the
  header.

  Leaves `t2` pointing at the header, so a caller reads the last word -- a cycle
  budget for `image/3`, a frame count for `Atomboy.Native.Machine` -- and
  whatever else it put there itself. Nothing is jumped to and nothing is
  measured yet: installing the seam's bounds and reading the retired-instruction
  baseline are the caller's, because where the baseline is read decides what the
  reported number includes.
  """
  @spec prologue() :: [Asm.item()]
  def prologue do
    [
      Asm.label(:driver),
      Asm.la(Regs.dispatch(), :table_base),
      Asm.la(Regs.mem(), :memory_gb),
      RV32.li(Regs.mask16(), 0xFFFF),
      RV32.li(Regs.cycles(), 0),
      Asm.la(:t2, :initial_state),
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
      RV32.lbu(Regs.control(), :t2, 12)
    ]
  end

  @doc """
  Samples the retired-instruction counter -- the baseline the record reports
  against.

  Under `qemu -icount shift=0` the CSR is exact; without it, it returns a
  fictitious value, and that is why the bench insists on the option.
  """
  @spec instret_baseline() :: [Asm.item()]
  def instret_baseline, do: [RV32.csrrs(:s9, @instret, :zero)]

  # ══ Le squelette ═════════════════════════════════════════════════════════════

  @doc """
  The dispatch skeleton: the fetch, the slow path, the interrupt service.

  Options:

    * `:budget_exit` -- the label an exhausted budget jumps to. `:materialise`
      by default, which is where `image/3` reports and stops; the machine loop
      passes its end-of-scanline label instead, and that single edge is the whole
      difference between an interpreter and a console.

  The `0xCB` prefix is not here but in `handlers/0`: it is reached from the jump
  table like any other entry, and it carries a handler's name.
  """
  @spec routines(keyword()) :: [Asm.item()]
  def routines(opts \\ []) do
    [
      fetch(Keyword.get(opts, :budget_exit, :materialise)),
      slow_fetch()
    ]
  end

  # ══ Le fetch ═════════════════════════════════════════════════════════════════

  defp fetch(budget_exit) do
    [
      Asm.label(:fetch),
      Asm.bgeu(Regs.cycles(), Regs.budget(), :to_budget_exit),
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
      Asm.label(:to_budget_exit),
      Asm.j(budget_exit),
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

  @doc """
  The two exits, the record, and the regions that follow it.

  A region is `{name, load, length}`: `load` is whatever puts its first address
  into `t3`, which is why a caller can send a slice of its own state and not only
  a labelled block. The order given is the order on the wire, and appending is
  the only way to extend it -- everything a reader already knows how to find must
  stay where it was.
  """
  @spec exits([{atom(), [Asm.item()], pos_integer()}]) :: [Asm.item()]
  def exits(regions) do
    [
      Asm.label(:materialise),
      RV32.li(:t2, @statuses.ok),
      Asm.j(:report),
      Asm.label(:unknown_opcode),
      RV32.li(:t2, @statuses.unknown_opcode),
      record(),
      Asm.label(:dump),
      for({name, load, length} <- regions, do: region(name, load, length)),
      Asm.j(:poweroff)
    ]
  end

  # `putc` only clobbers t0 and t1: t2 carries the status throughout, a1 the
  # opcode, and every state register survives.
  defp record do
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

  # One region out over the serial port. `putc` clobbers t0 and t1 only, so the
  # cursor and the count live in t3 and t4.
  defp region(name, load, length) do
    [
      load,
      RV32.li(:t4, length),
      Asm.label(:"dump_#{name}"),
      Asm.beqz(:t4, :"dump_#{name}_done"),
      RV32.lbu(:a0, :t3, 0),
      Asm.call(:putc),
      RV32.addi(:t3, :t3, 1),
      RV32.addi(:t4, :t4, -1),
      Asm.j(:"dump_#{name}"),
      Asm.label(:"dump_#{name}_done")
    ]
  end

  # ══ Les gestionnaires ════════════════════════════════════════════════════════

  @doc """
  Every opcode handler the backend can emit, each behind its own label.

  The bodies come from `Atomboy.Native.Emit.body/1`, so there is exactly one
  description of what an instruction does no matter which image it ends up in.
  """
  @spec handlers() :: [Asm.item()]
  def handlers do
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
      tables(),
      {:align, 4},
      Asm.label(:initial_state),
      header(state, budget),
      {:align, 4},
      Asm.label(:memory_gb),
      memory
    ]
  end

  @doc """
  The two jump tables, for the image's data section.

  They are contiguous and deliberately unaligned with respect to each other: the
  prefix reaches the second one through a displacement of exactly 1024.
  """
  @spec tables() :: [Asm.item()]
  def tables do
    [
      {:align, 4},
      Asm.label(:table_base),
      table_base(),
      Asm.label(:table_cb),
      table_cb()
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

  @doc """
  The image's header: the CPU state, the timer's phase, and one caller's word.

  `:timer` carries the divider's and TIMA's sub-counters as `{div, tima}` -- the
  fractions of a period neither register shows. They are zero for an interpreter,
  which has no timer; handing them over is what lets a console's runs chain frame
  to frame instead of restarting the phase on every image.
  """
  @spec header(State.t(), non_neg_integer(), keyword()) :: binary()
  def header(%State{} = state, word, opts \\ []) do
    control =
      state.ime + if(state.halted, do: 2, else: 0) + state.ime_pending * 4

    {div_sub, tima_sub} = Keyword.get(opts, :timer, {0, 0})

    <<state.a, state.f, state.b, state.c, state.d, state.e, state.h, state.l, state.sp::16-little,
      state.pc::16-little, control, div_sub, tima_sub::16-little, word::32-little>>
  end
end
