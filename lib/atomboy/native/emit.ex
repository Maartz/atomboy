defmodule Atomboy.Native.Emit do
  @moduledoc """
  The third backend: an `%Insn{}` becomes RISC-V instructions.

  `Atomboy.CPU.Gen` has two -- the struct oracle and the fast loop -- both
  producing Elixir AST. This one produces bytes. All three match the same
  `%Atomboy.CPU.Insn{}` patterns, read from the same table, and that is where
  the property that matters lives: an operand family is described once.

  ## Why this module is not a third family inside `gen.ex`

  `gen.ex` is already 1500 lines for two emitters returning AST. A third, whose
  bodies are three to five times longer and return binaries, would make it a
  file nobody re-reads. What guarantees no backend misses a family is not file
  adjacency anyway: it is that all three match the same clause heads, and that
  `coverage/0` dit lesquelles manquent encore ici.

  This module's clause order deliberately copies `gen.ex`'s. A difference in
  order is a difference in semantics when two patterns
  chevauchent.

  ## Ce qui est couvert aujourd'hui

  239 des 500 instructions, en quatre vagues : les transferts entre registres et
  8-bit arithmetic, then everything touching the bus -- the `(HL)` column, the
  paired indirections, the high page, absolute addressing -- then 16-bit, the
  stack and `RST`, and finally control flow with its conditional
  conditionalles.

  Ce qui manque : le bloc `CB` tout entier, et les instructions qui parlent aux
  interruptions — `EI`, `DI`, `HALT`, et `RETI`, qui est un `RET` posant IME et
  so waits for the guest to run a state where IME is armed. They fall into
  `:unsupported`, and dispatch sends them to `unknown_opcode` -- a partial
  interpreter must say which one, not return a wrong answer.
  """

  import Bitwise

  alias Atomboy.CPU.Insn
  alias Atomboy.CPU.Table
  alias Atomboy.Native.ALU
  alias Atomboy.Native.Asm
  alias Atomboy.Native.Bus
  alias Atomboy.Native.RV32
  alias Atomboy.Native.Regs

  # The table's mnemonic is not the primitive's name: `AND`, `OR` and `XOR` are
  # Elixir special forms, so `Atomboy.CPU.ALU` calls them `bit_and`, `bit_or`,
  # `bit_xor`. The mapping is the one in `Atomboy.CPU.Gen.alu_call/4`
  # (gen.ex:1490) -- a test checks the two do not
  # divergent pas.
  @routine %{
    add: :add,
    adc: :adc,
    sub: :sub,
    sbc: :sbc,
    and: :bit_and,
    xor: :bit_xor,
    or: :bit_or,
    cp: :cp
  }

  @alu Map.keys(@routine)
  @accumulator [:rlca, :rrca, :rla, :rra, :daa, :cpl, :scf, :ccf]

  @ime Regs.control_bits().ime
  @halted Regs.control_bits().halted
  @pending Regs.control_bits().pending

  # Les jumelles CB des rotations de l'accumulateur. Elles posent Z normalement
  # where `RLCA` and friends always clear it -- two encodings, two meanings for
  # Z, and a classic source of bugs.
  @rotations [:rlc, :rrc, :rl, :rr, :sla, :sra, :swap, :srl]

  @doc "The opcode that introduces the extended table."
  @spec cb_prefix() :: 0xCB
  def cb_prefix, do: 0xCB

  @doc "The ALU primitive a table mnemonic maps to."
  @spec routine(atom()) :: atom()
  def routine(mnemonic), do: Map.fetch!(@routine, mnemonic)

  @doc """
  An opcode handler's body, or `:unsupported`.

  Le corps se termine toujours par la comptabilisation des cycles et un saut
  to `fetch` -- the native equivalent of `Gen.loop_ret/3`'s tail call.
  """
  @spec body(Insn.t()) :: [Asm.item()] | :unsupported

  # NOP — l'instruction qui ne fait que passer du temps.
  def body(%Insn{mnemonic: :nop, cycles: cycles}), do: finish(cycles)

  # STOP -- one byte and nothing else: the actual halt waits on a clock
  # controller the emulator does not have, and the SingleStepTests corpus models
  # it this way. That is the table's choice (table.ex:104), so the oracle does
  # the same, so equivalence holds.
  def body(%Insn{mnemonic: :stop, cycles: cycles}), do: finish(cycles)

  # LD r, r' -- half the table, and the only family with no side effect at all.
  # `LD B, B` is emitted like the rest: eliding would be an optimisation, and
  # optimisations come after measurement.
  def body(%Insn{mnemonic: :ld, operands: [{:reg, dst}, {:reg, src}], cycles: cycles}) do
    Regs.read8({:reg, src}, :t0) ++ Regs.write8({:reg, dst}, :t0) ++ finish(cycles)
  end

  # LD r, d8 -- the first immediate operand, hence the first PC advance beyond
  # the opcode fetch.
  def body(%Insn{mnemonic: :ld, operands: [{:reg, dst}, {:imm, 8}], cycles: cycles}) do
    read_immediate(:t0) ++ Regs.write8({:reg, dst}, :t0) ++ finish(cycles)
  end

  # ALU A, r — les 56 cases du bloc x=2 hors colonne (HL). A et F voyagent dans
  # their dedicated registers, the routine reads and rewrites them in place;
  # only the operand needs loading.
  def body(%Insn{mnemonic: m, operands: [{:reg, :a}, {:reg, src}], cycles: cycles})
      when m in @alu do
    Regs.read8({:reg, src}, :a0) ++ [Asm.call(ALU.label(@routine[m]))] ++ finish(cycles)
  end

  def body(%Insn{mnemonic: m, operands: [{:reg, :a}, {:imm, 8}], cycles: cycles})
      when m in @alu do
    read_immediate(:a0) ++ [Asm.call(ALU.label(@routine[m]))] ++ finish(cycles)
  end

  # INC r and DEC r -- the only ALU operations writing somewhere other than
  # A, d'où l'aller-retour par a0.
  def body(%Insn{mnemonic: m, operands: [{:reg, cible}], cycles: cycles})
      when m in [:inc, :dec] do
    Regs.read8({:reg, cible}, :a0) ++
      [Asm.call(ALU.label(m))] ++
      Regs.write8({:reg, cible}, :a0) ++ finish(cycles)
  end

  # Column z=7: eight operations on the accumulator alone, no operand.
  def body(%Insn{mnemonic: m, operands: [], cycles: cycles}) when m in @accumulator do
    [Asm.call(ALU.label(m))] ++ finish(cycles)
  end

  # ── The memory operands ─────────────────────────────────────────────────────
  #
  # `(HL)` is the `r = 6` encoding: it runs through the same families as the
  # seven registers, hence clauses twinned with those above, bar the access.

  def body(%Insn{mnemonic: :ld, operands: [{:reg, dst}, :hl_ind], cycles: cycles}) do
    Bus.read(Regs.hl(), :t0) ++ Regs.write8({:reg, dst}, :t0) ++ finish(cycles)
  end

  def body(%Insn{mnemonic: :ld, operands: [:hl_ind, {:reg, src}], cycles: cycles}) do
    Regs.read8({:reg, src}, :t0) ++ Bus.write(Regs.hl(), :t0) ++ finish(cycles)
  end

  def body(%Insn{mnemonic: :ld, operands: [:hl_ind, {:imm, 8}], cycles: cycles}) do
    read_immediate(:t0) ++ Bus.write(Regs.hl(), :t0) ++ finish(cycles)
  end

  def body(%Insn{mnemonic: m, operands: [{:reg, :a}, :hl_ind], cycles: cycles})
      when m in @alu do
    Bus.read(Regs.hl(), :a0) ++ [Asm.call(ALU.label(@routine[m]))] ++ finish(cycles)
  end

  # INC (HL) and DEC (HL) -- read-modify-write, the only form in the table
  # touching the same address twice.
  def body(%Insn{mnemonic: m, operands: [:hl_ind], cycles: cycles}) when m in [:inc, :dec] do
    Bus.read(Regs.hl(), :a0) ++
      [Asm.call(ALU.label(m))] ++
      Bus.write(Regs.hl(), :a0) ++ finish(cycles)
  end

  # LD A, (BC/DE/HL+/HL-) and the symmetric stores. The HL adjustment follows
  # the access: the address is the one from before the increment.
  def body(%Insn{mnemonic: :ld, operands: [{:reg, :a}, {:ind, _} = source], cycles: cycles}) do
    Bus.address(source, :t0) ++
      Bus.read(:t0, Regs.a()) ++
      Bus.adjust(source) ++ finish(cycles)
  end

  def body(%Insn{mnemonic: :ld, operands: [{:ind, _} = cible, {:reg, :a}], cycles: cycles}) do
    Bus.address(cible, :t0) ++
      Bus.write(:t0, Regs.a()) ++
      Bus.adjust(cible) ++ finish(cycles)
  end

  # The high page -- the I/O registers, addressed with one byte.
  def body(%Insn{mnemonic: :ldh, operands: [{:reg, :a}, :a8_ind], cycles: cycles}) do
    read_immediate(:t0) ++
      Bus.high_page(:t0, :t0) ++
      Bus.read(:t0, Regs.a()) ++ finish(cycles)
  end

  def body(%Insn{mnemonic: :ldh, operands: [:a8_ind, {:reg, :a}], cycles: cycles}) do
    read_immediate(:t0) ++
      Bus.high_page(:t0, :t0) ++
      Bus.write(:t0, Regs.a()) ++ finish(cycles)
  end

  def body(%Insn{mnemonic: :ldh, operands: [{:reg, :a}, :c_ind], cycles: cycles}) do
    Bus.high_page(Regs.c(), :t0) ++ Bus.read(:t0, Regs.a()) ++ finish(cycles)
  end

  def body(%Insn{mnemonic: :ldh, operands: [:c_ind, {:reg, :a}], cycles: cycles}) do
    Bus.high_page(Regs.c(), :t0) ++ Bus.write(:t0, Regs.a()) ++ finish(cycles)
  end

  # Absolute addressing -- the only two-byte operand of this stage.
  def body(%Insn{mnemonic: :ld, operands: [{:reg, :a}, :a16_ind], cycles: cycles}) do
    read_immediate16(:t0) ++ Bus.read(:t0, Regs.a()) ++ finish(cycles)
  end

  def body(%Insn{mnemonic: :ld, operands: [:a16_ind, {:reg, :a}], cycles: cycles}) do
    read_immediate16(:t0) ++ Bus.write(:t0, Regs.a()) ++ finish(cycles)
  end

  # ── Seize bits et pile ──────────────────────────────────────────────────────

  def body(%Insn{mnemonic: :ld, operands: [{:pair, _} = paire, {:imm, 16}], cycles: cycles}) do
    read_immediate16(:t0) ++ Regs.write16(paire, :t0) ++ finish(cycles)
  end

  # LD SP, HL -- the instruction set's only pair-to-pair copy.
  def body(%Insn{mnemonic: :ld, operands: [{:pair, _} = dst, {:pair, _} = src], cycles: cycles}) do
    Regs.read16(src, :t0) ++ Regs.write16(dst, :t0) ++ finish(cycles)
  end

  # INC rr and DEC rr -- **no flag touched at all**, unlike their 8-bit
  # namesakes. The hardware wants it that way, which is why they never go
  # par l'ALU.
  def body(%Insn{mnemonic: m, operands: [{:pair, _} = paire], cycles: cycles})
      when m in [:inc, :dec] do
    Regs.read16(paire, :t0) ++
      [
        RV32.addi(:t0, :t0, if(m == :inc, do: 1, else: -1)),
        RV32.and_(:t0, :t0, Regs.mask16())
      ] ++ Regs.write16(paire, :t0) ++ finish(cycles)
  end

  # ADD HL, rr -- HL already lives in the register the routine expects.
  def body(%Insn{mnemonic: :add, operands: [{:pair, :hl}, {:pair, _} = src], cycles: cycles}) do
    Regs.read16(src, :a0) ++ [Asm.call(ALU.label(:add16))] ++ finish(cycles)
  end

  # ADD SP, r8 and LD HL, SP+r8 -- same arithmetic, two destinations.
  def body(%Insn{mnemonic: :add_sp, operands: [{:pair, dst}, {:imm, 8}], cycles: cycles}) do
    Regs.read16({:pair, :sp}, :a0) ++
      read_immediate(:a1) ++
      [Asm.call(ALU.label(:add_sp))] ++
      Regs.write16({:pair, dst}, :a0) ++ finish(cycles)
  end

  # LD (a16), SP -- the instruction set's only direct 16-bit store.
  def body(%Insn{mnemonic: :ld, operands: [:a16_ind, {:pair, :sp}], cycles: cycles}) do
    read_immediate16(:t0) ++ Bus.write16(:t0, Regs.sp()) ++ finish(cycles)
  end

  # PUSH -- SP moves back two, then the word is written at the new address.
  def body(%Insn{mnemonic: :push, operands: [{:pair, _} = paire], cycles: cycles}) do
    Regs.read16(paire, :t0) ++
      Bus.move_stack(-2) ++
      Bus.write16(Regs.sp(), :t0) ++ finish(cycles)
  end

  def body(%Insn{mnemonic: :pop, operands: [{:pair, _} = paire], cycles: cycles}) do
    Bus.read16(Regs.sp(), :t0) ++
      Bus.move_stack(2) ++
      Regs.write16(paire, :t0) ++ finish(cycles)
  end

  # RST -- a call whose target is baked into the opcode. PC has already moved
  # d'un cran au fetch, donc c'est bien l'adresse de retour qui part sur la pile.
  def body(%Insn{mnemonic: :rst, operands: [{:rst, cible}], cycles: cycles}) do
    Bus.move_stack(-2) ++
      Bus.write16(Regs.sp(), Regs.pc()) ++
      RV32.li(Regs.pc(), cible) ++ finish(cycles)
  end

  # ── Control flow ────────────────────────────────────────────────────────────
  #
  # All these families share one shape: read the operands -- which the processor
  # does either way -- then act on PC if the condition holds. The cycle cost
  # differs between the two branches, and it is the table that
  # le porte (`cycles` et `cycles_untaken`).

  # JR -- a signed one-byte offset, relative to the PC following the operand.
  # The sign is computed without a branch: subtract 256 when bit 7 is set. Same
  # gesture as in `Gen` (gen.ex:100), for the same reason.
  def body(%Insn{mnemonic: :jr, operands: [{:imm, 8}]} = insn) do
    conditional(insn, read_immediate(:t0), [
      RV32.srli(:t2, :t0, 7),
      RV32.slli(:t2, :t2, 8),
      RV32.sub(:t2, :t0, :t2),
      RV32.add(Regs.pc(), Regs.pc(), :t2),
      RV32.and_(Regs.pc(), Regs.pc(), Regs.mask16())
    ])
  end

  def body(%Insn{mnemonic: :jp, operands: [{:imm, 16}]} = insn) do
    conditional(insn, read_immediate16(:t0), [RV32.mv(Regs.pc(), :t0)])
  end

  # JP HL -- often written "JP (HL)", but there is no memory access: PC receives
  # the pair, that is all. One instruction, and the set's only computed jump.
  def body(%Insn{mnemonic: :jp, operands: [{:pair, :hl}], cycles: cycles}) do
    [RV32.mv(Regs.pc(), Regs.hl())] ++ finish(cycles)
  end

  # CALL -- the pushed address is the one following the two operand bytes, so PC
  # is already at its final value when it goes onto the stack.
  def body(%Insn{mnemonic: :call, operands: [{:imm, 16}]} = insn) do
    conditional(
      insn,
      read_immediate16(:t0),
      Bus.move_stack(-2) ++
        Bus.write16(Regs.sp(), Regs.pc()) ++
        [RV32.mv(Regs.pc(), :t0)]
    )
  end

  # RET, RET cc et RETI — la lecture de pile n'a lieu que si le retour se fait,
  # and RETI re-enables IME in the same breath. Immediately, unlike `EI`: the
  # instruction exists to leave an interrupt handler, and a one-instruction delay
  # there would be a trap.
  def body(%Insn{mnemonic: m} = insn) when m in [:ret, :reti] do
    resume =
      if m == :reti, do: [RV32.ori(Regs.control(), Regs.control(), @ime)], else: []

    conditional(
      insn,
      [],
      Bus.read16(Regs.sp(), :t0) ++
        Bus.move_stack(2) ++
        [RV32.mv(Regs.pc(), :t0)] ++ resume
    )
  end

  # ── Les interruptions ───────────────────────────────────────────────────────
  #
  # Trois instructions qui ne font que poser des bits dans le registre de
  # register. All the work is in `fetch`, where those bits are read -- that is
  # aussi ainsi que `Atomboy.CPU.Loop` est bâti.

  # DI turns IME off **and disarms a pending EI**: without that, an `EI`
  # followed by a `DI` would still enable interrupts one step later.
  def body(%Insn{mnemonic: :di, cycles: cycles}) do
    [RV32.andi(Regs.control(), Regs.control(), bnot(@ime ||| @pending))] ++ finish(cycles)
  end

  # EI n'autorise pas : il arme. La promotion se fait au pas suivant, dans le
  # `fetch` -- the same point as in both Elixir backends.
  def body(%Insn{mnemonic: :ei, cycles: cycles}) do
    [RV32.ori(Regs.control(), Regs.control(), @pending)] ++ finish(cycles)
  end

  def body(%Insn{mnemonic: :halt, cycles: cycles}) do
    [RV32.ori(Regs.control(), Regs.control(), @halted)] ++ finish(cycles)
  end

  # ── Le bloc CB ──────────────────────────────────────────────────────────────
  #
  # 256 opcodes, and the most regular part of the table: eight rotations over
  # eight targets, then BIT, RES and SET whose bit number is encoded in the
  # opcode. Three clauses suffice, because `(HL)` is here just one target among
  # eight -- the same abstraction as the hardware's `r = 6` encoding.

  def body(%Insn{prefix: :cb, mnemonic: m, operands: [cible], cycles: cycles})
      when m in @rotations do
    read_target(cible, :a0) ++
      [Asm.call(ALU.label(m))] ++
      write_target(cible, :a0) ++ finish(cycles)
  end

  # BIT n -- only weighs a bit: the target is not rewritten, which is why its
  # `(HL)` form costs 12 T where RES and SET cost 16.
  def body(%Insn{prefix: :cb, mnemonic: :bit, operands: [{:bit, n}, cible], cycles: cycles}) do
    read_target(cible, :a0) ++ [Asm.call(ALU.bit_label(n))] ++ finish(cycles)
  end

  # RES and SET -- a mask, and no flags. `Gen` inlines them for the same reason:
  # there is no subtlety to centralise.
  def body(%Insn{prefix: :cb, mnemonic: m, operands: [{:bit, n}, cible], cycles: cycles})
      when m in [:res, :set] do
    mask =
      case m do
        :res -> RV32.andi(:t0, :t0, bxor(1 <<< n, 0xFF))
        :set -> RV32.ori(:t0, :t0, 1 <<< n)
      end

    read_target(cible, :t0) ++ [mask] ++ write_target(cible, :t0) ++ finish(cycles)
  end

  def body(%Insn{}), do: :unsupported

  # A CB-block target: seven registers and `(HL)`, indifferently.
  defp read_target(:hl_ind, dest), do: Bus.read(Regs.hl(), dest)
  defp read_target({:reg, _} = reg, dest), do: Regs.read8(reg, dest)

  defp write_target(:hl_ind, src), do: Bus.write(Regs.hl(), src)
  defp write_target({:reg, _} = reg, src), do: Regs.write8(reg, src)

  # The shared skeleton: the prelude always runs, the action only if the
  # condition holds. The untaken branch jumps to `fetch` before the label, so the
  # two paths never meet.
  defp conditional(%Insn{condition: nil} = insn, prelude, action) do
    prelude ++ action ++ finish(insn.cycles)
  end

  defp conditional(%Insn{} = insn, prelude, action) do
    pris = :"taken_#{Integer.to_string(insn.opcode, 16)}"

    prelude ++
      branch_if(insn.condition, pris) ++
      finish(insn.cycles_untaken) ++
      [Asm.label(pris)] ++ action ++ finish(insn.cycles)
  end

  # Z est le bit 7, C le bit 4 ; `NZ` et `NC` branchent sur l'absence.
  @condition %{nz: {0x80, :absent}, z: {0x80, :present}, nc: {0x10, :absent}, c: {0x10, :present}}

  defp branch_if(condition, label) do
    {mask, sense} = Map.fetch!(@condition, condition)
    branch = if sense == :absent, do: &Asm.beqz/2, else: &Asm.bnez/2

    [RV32.andi(:t1, Regs.f(), mask), branch.(:t1, label)]
  end

  @doc """
  Loads the immediate byte following the opcode, and advances PC.

  `t1` holds the address for the duration of the read, so that `dest` can be
  n'importe quel autre registre de travail — `t0` comme `a0`.
  """
  @spec read_immediate(RV32.reg()) :: [Asm.item()]
  def read_immediate(dest) do
    [
      RV32.add(:t1, Regs.mem(), Regs.pc()),
      RV32.lbu(dest, :t1, 0),
      RV32.addi(Regs.pc(), Regs.pc(), 1),
      RV32.and_(Regs.pc(), Regs.pc(), Regs.mask16())
    ]
  end

  @doc """
  Loads the two-byte little-endian immediate following the opcode.

  Two one-byte reads rather than one two-byte read: the second byte sits at
  `PC + 1` **wrapped to 16 bits**, so an opcode at `0xFFFF` takes its high
  operand from address `0`. An `lhu` at `mem + PC` would read a byte outside the
  64 Ko.
  """
  @spec read_immediate16(RV32.reg()) :: [Asm.item()]
  def read_immediate16(dest) do
    read_immediate(dest) ++
      read_immediate(:t2) ++
      [
        RV32.slli(:t2, :t2, 8),
        RV32.or_(dest, dest, :t2)
      ]
  end

  @doc """
  The end of every handler: the cycles, then the next fetch.

  Every cost in the table is 24 T or less, so `addi`'s immediate takes them
  without a detour.
  """
  @spec finish(pos_integer()) :: [Asm.item()]
  def finish(cycles) do
    [RV32.addi(Regs.cycles(), Regs.cycles(), cycles), Asm.j(:fetch)]
  end

  @doc """
  The instructions this backend can emit, by `{prefix, opcode}`.

  Same shape as `Atomboy.CPU.implemented/0`, so tests can restrict a random
  program to what both sides cover.
  """
  @spec coverage() :: [{nil | :cb, 0..0xFF}]
  def coverage do
    # `0xCB` is not an instruction: it is a prefix, and so has no table entry.
    # It joins the dispatchable set as soon as the extended block is emitted
    # whole -- jumping into a table with holes would be worse
    # que ne pas sauter du tout.
    if prefix_covered?() do
      [{nil, cb_prefix()} | table_coverage()]
    else
      table_coverage()
    end
  end

  @doc """
  Only the table entries that are emitted -- without the prefix.

  That is the number to compare against the 500 described instructions, and
  keeping it apart from `coverage/0` avoids a dashboard reporting 496 out of 500
  after adding something that is not among the 500.
  """
  @spec table_coverage() :: [{nil | :cb, 0..0xFF}]
  def table_coverage do
    for insn <- Table.all(), body(insn) != :unsupported, do: {insn.prefix, insn.opcode}
  end

  @doc "Is the extended block emitted in full?"
  @spec prefix_covered?() :: boolean()
  def prefix_covered?, do: Enum.count(table_coverage(), &match?({:cb, _}, &1)) == 256

  @doc "The instructions still to do -- this work's dashboard."
  @spec missing() :: [{nil | :cb, 0..0xFF}]
  def missing do
    for insn <- Table.all(), body(insn) == :unsupported, do: {insn.prefix, insn.opcode}
  end
end
