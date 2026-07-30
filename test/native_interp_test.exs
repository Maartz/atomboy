defmodule Atomboy.NativeInterpTest do
  @moduledoc """
  The native interpreter against the oracle -- the same method as
  `loop_test.exs`.

  `Atomboy.CPU.Loop` is not validated by the SM83 vectors but by inheritance:
  the oracle passes the vectors, and cross-equivalence on random programs proves
  the fast loop is indistinguishable from it. The RV32 interpreter is a third
  backend and is validated exactly the same way, except that the gap to bridge
  is wider -- an instruction encoding, a register file, an assembler and a
  processor emulator separate the two states being compared.

  The seeds are fixed: a failure is reproducible as it stands.
  """

  use ExUnit.Case, async: true

  alias Atomboy.CPU.Insn
  alias Atomboy.CPU.State
  alias Atomboy.CPU.Table
  alias Atomboy.Memory.Flat
  alias Atomboy.Native.Emit
  alias Atomboy.Native.Interp
  alias Atomboy.Native.Run

  @moduletag :qemu
  # The harness pays one qemu launch and a 64 KB dump per run.
  @moduletag timeout: 120_000

  @steps 5_000
  @seeds 1..8

  describe "coverage" do
    test "the SM83 table is emitted in full" do
      covered = MapSet.new(Emit.coverage())

      assert {nil, 0x00} in covered, "NOP"
      assert {nil, 0x41} in covered, "LD B, C"
      assert {nil, 0x7F} in covered, "LD A, A"
      assert {nil, 0x80} in covered, "ADD A, B"
      assert {nil, 0xBF} in covered, "CP A"
      assert {nil, 0xC6} in covered, "ADD A, d8"
      assert {nil, 0x3C} in covered, "INC A"
      assert {nil, 0x05} in covered, "DEC B"
      assert {nil, 0x27} in covered, "DAA"
      assert {nil, 0x3F} in covered, "CCF"
      assert {nil, 0x3E} in covered, "LD A, d8"
      assert {nil, 0x46} in covered, "LD B, (HL)"
      assert {nil, 0x70} in covered, "LD (HL), B"
      assert {nil, 0x86} in covered, "ADD A, (HL)"
      assert {nil, 0x34} in covered, "INC (HL)"
      assert {nil, 0x36} in covered, "LD (HL), d8"
      assert {nil, 0x22} in covered, "LD (HL+), A"
      assert {nil, 0x1A} in covered, "LD A, (DE)"
      assert {nil, 0xE0} in covered, "LDH (a8), A"
      assert {nil, 0xF2} in covered, "LDH A, (C)"
      assert {nil, 0xEA} in covered, "LD (a16), A"

      assert {nil, 0x01} in covered, "LD BC, d16"
      assert {nil, 0x03} in covered, "INC BC"
      assert {nil, 0x09} in covered, "ADD HL, BC"
      assert {nil, 0xC5} in covered, "PUSH BC"
      assert {nil, 0xF1} in covered, "POP AF"
      assert {nil, 0xE8} in covered, "ADD SP, r8"
      assert {nil, 0xF8} in covered, "LD HL, SP+r8"
      assert {nil, 0xF9} in covered, "LD SP, HL"
      assert {nil, 0x08} in covered, "LD (a16), SP"
      assert {nil, 0xFF} in covered, "RST 38H"

      assert {nil, 0x18} in covered, "JR e8"
      assert {nil, 0x20} in covered, "JR NZ, e8"
      assert {nil, 0xC3} in covered, "JP a16"
      assert {nil, 0xE9} in covered, "JP HL"
      assert {nil, 0xCA} in covered, "JP Z, a16"
      assert {nil, 0xCD} in covered, "CALL a16"
      assert {nil, 0xD4} in covered, "CALL NC, a16"
      assert {nil, 0xC9} in covered, "RET"
      assert {nil, 0xD8} in covered, "RET C"

      assert {nil, 0xCB} in covered, "the CB prefix"
      assert {:cb, 0x00} in covered, "RLC B"
      assert {:cb, 0x36} in covered, "SWAP (HL)"
      assert {:cb, 0x7E} in covered, "BIT 7, (HL)"
      assert {:cb, 0x86} in covered, "RES 0, (HL)"
      assert {:cb, 0xFF} in covered, "SET 7, A"

      assert {nil, 0x76} in covered, "HALT"
      assert {nil, 0xD9} in covered, "RETI"
      assert {nil, 0xF3} in covered, "DI"
      assert {nil, 0xFB} in covered, "EI"

      # The whole table, no exceptions.
      assert length(Emit.table_coverage()) == length(Table.all())
      assert Emit.missing() == []

      # The prefix joins the dispatchable set without being a table entry.
      assert MapSet.size(covered) == length(Table.all()) + 1
      assert Emit.prefix_covered?()
    end

    test "the mnemonic-to-primitive mapping follows Gen's" do
      # `gen.ex:1490` does the same translation for both Elixir backends.
      # Qu'elles divergent produirait du code natif qui appelle une routine
      # inexistante — ou pire, la mauvaise.
      exportees = MapSet.new(Enum.map(Atomboy.CPU.ALU.__info__(:functions), &elem(&1, 0)))

      for mnemonic <- [:add, :adc, :sub, :sbc, :and, :xor, :or, :cp] do
        routine = Emit.routine(mnemonic)

        assert routine in exportees,
               "#{mnemonic} vise #{routine}, que Atomboy.CPU.ALU n'exporte pas"
      end

      assert Emit.routine(:and) == :bit_and
      assert Emit.routine(:add) == :add
    end

    test "tout ce que le natif couvre, l'oracle le couvre aussi" do
      assert MapSet.subset?(MapSet.new(Emit.coverage()), MapSet.new(Atomboy.CPU.implemented()))
    end
  end

  describe "execution" do
    test "a memory of NOPs advances PC one step per instruction" do
      memory = :binary.copy(<<0x00>>, 0x10000)

      result = Run.run!(memory, %State{}, 100)

      assert result.status == :ok
      assert result.cycles == 100
      assert result.state.pc == 25
      assert result.memory == memory
    end

    test "an opcode absent from the table stops dead and names itself" do
      # 0xE3 does not exist on the SM83: neither the table nor the oracle has it.
      memory = :binary.copy(<<0xE3>>, 0x10000)

      result = Run.run!(memory, %State{}, 100)

      assert result.status == :unknown_opcode
      assert result.opcode == 0xE3
    end

    test "POP AF jette les quatre bits bas du registre de drapeaux" do
      # Le seul endroit d'où une valeur arbitraire peut entrer dans F. Les
      # low four bits do not exist on hardware, and `POP AF` must lose them.
      #
      # This test is here because cross-equivalence does not catch it: in a
      # random program the next ALU operation rewrites F entirely, so the
      # pollution is erased before it is observed. Verified by mutation --
      # dropping the mask leaves all eight seeds green.
      memory = program(%{0x100 => 0xF1, 0x200 => 0xFF, 0x201 => 0x12})

      result = Run.run!(memory, %State{pc: 0x100, sp: 0x200}, 12)

      assert result.status == :ok
      assert result.state.a == 0x12
      assert result.state.f == 0xF0, "F is #{result.state.f}, the low bits survived"
      assert result.state.sp == 0x202
    end

    test "PUSH then POP return the pair intact, low byte first" do
      # PUSH BC then POP DE: DE must equal BC, and the stack hold the low byte
      # at the low address -- the order the hardware expects.
      memory = program(%{0x100 => 0xC5, 0x101 => 0xD1})

      result = Run.run!(memory, %State{pc: 0x100, sp: 0x200, b: 0xBE, c: 0xEF}, 28)

      assert result.status == :ok
      assert {result.state.d, result.state.e} == {0xBE, 0xEF}
      assert result.state.sp == 0x200
      assert :binary.at(result.memory, 0x1FE) == 0xEF, "low byte at the low address"
      assert :binary.at(result.memory, 0x1FF) == 0xBE
    end

    test "RST pushes the return address and jumps to its target" do
      # RST 28H: the opcode is one byte, so the pushed address is the one
      # le suit.
      memory = program(%{0x100 => 0xEF})

      result = Run.run!(memory, %State{pc: 0x100, sp: 0x200}, 16)

      assert result.status == :ok
      assert result.state.pc == 0x28
      assert result.state.sp == 0x1FE
      assert :binary.at(result.memory, 0x1FE) == 0x01
      assert :binary.at(result.memory, 0x1FF) == 0x01
    end

    test "an untaken branch still consumes its operand and costs less" do
      # JR NZ, +4 with Z set: the offset is read -- so PC advances by two --
      # but the jump does not happen, and the instruction costs 8 T not 12.
      memory = program(%{0x100 => 0x20, 0x101 => 0x04})

      result = Run.run!(memory, %State{pc: 0x100, f: 0x80}, 8)

      assert result.status == :ok
      assert result.state.pc == 0x102, "the operand must be consumed even without a jump"
      assert result.cycles == 8
    end

    test "the same branch, taken, jumps and costs more" do
      memory = program(%{0x100 => 0x20, 0x101 => 0x04})

      result = Run.run!(memory, %State{pc: 0x100, f: 0x00}, 12)

      assert result.status == :ok
      assert result.state.pc == 0x106, "the target is relative to the PC following the operand"
      assert result.cycles == 12
    end

    test "a negative JR offset goes backwards" do
      # 0xFE is -2: the jump lands back on the opcode itself.
      memory = program(%{0x100 => 0x18, 0x101 => 0xFE})

      result = Run.run!(memory, %State{pc: 0x100}, 12)

      assert result.state.pc == 0x100
    end

    test "CALL puis RET reviennent exactement où il faut" do
      # CALL 0x300, and a RET at 0x300. The return address is the one following
      # the two operand bytes.
      memory = program(%{0x100 => 0xCD, 0x101 => 0x00, 0x102 => 0x03, 0x300 => 0xC9})

      result = Run.run!(memory, %State{pc: 0x100, sp: 0x200}, 40)

      assert result.status == :ok
      assert result.state.pc == 0x103
      assert result.state.sp == 0x200, "the stack must be given back"
      assert result.cycles == 40, "24 pour le CALL, 16 pour le RET"
    end

    test "JP HL touches no memory" do
      memory = program(%{0x100 => 0xE9})

      result = Run.run!(memory, %State{pc: 0x100, h: 0x12, l: 0x34}, 4)

      assert result.state.pc == 0x1234
      assert result.memory == memory
    end

    test "BIT n weighs bit n, and only that one" do
      # The same blind spot as `POP AF`: `BIT` writes only F, so the next ALU
      # operation erases its result before it is observed. Verified by mutation
      # -- shifting the bit number by one leaves cross-equivalence entirely
      # green, in both families.
      #
      # 0xAA vaut 10101010 : Z ne doit se lever que sur les bits pairs. C entre
      # comes in at 1 and must come out intact, H must be set.
      for n <- 0..7 do
        memory = program(%{0x100 => 0xCB, 0x101 => 0x40 + n * 8})

        result = Run.run!(memory, %State{pc: 0x100, b: 0xAA, f: 0x10}, 8)

        zero = if rem(n, 2) == 0, do: 0x80, else: 0x00

        assert result.state.f == zero + 0x20 + 0x10,
               "BIT #{n}, B sur 0xAA : F vaut #{Atomboy.CPU.State.flag_string(result.state)}"

        assert result.state.b == 0xAA, "BIT must not write its target"
      end
    end

    test "PC wraps at 0xFFFF without overflowing" do
      memory = :binary.copy(<<0x00>>, 0x10000)

      result = Run.run!(memory, %State{pc: 0xFFFE}, 12)

      assert result.status == :ok
      assert result.state.pc == 1
    end
  end

  # Two families, because they do not prove the same thing.
  #
  # **Linear** programs exclude everything that diverts PC: execution then
  # sweeps the address space end to end and every emitted opcode
  # passe des dizaines de fois. C'est la famille qui donne la *largeur*.
  #
  # Programs **with jumps** take the whole table. Measured: they visit only 37
  # to 290 distinct addresses out of 65536, because a `JR -2` is enough to trap
  # PC in a loop. So they prove almost nothing about breadth -- but they are the
  # only ones exercising branches, the stack in real use and self-modification.
  # That is the family giving
  # *profondeur*.
  #
  # Believing the second sufficed was a mistake: "40000 instructions"
  # reads like coverage, and is not.
  describe "cross-equivalence -- linear programs" do
    for seed <- @seeds do
      test "linear program, seed #{seed}" do
        :rand.seed(:exsss, {unquote(seed), 0, 0})

        memory = random_program(linear_opcodes())
        state = random_state()

        {expected, oracle_memory, budget, faulty} = oracle(memory, state, @steps)

        result = Run.run!(memory, state, budget)

        assert result.status == :ok
        assert result.cycles == budget
        assert result.state == expected

        divergences =
          for addr <- 0..0xFFFF,
              oracle_byte = Flat.read8(oracle_memory, addr),
              native_byte = :binary.at(result.memory, addr),
              oracle_byte != native_byte,
              do: {addr, oracle_byte, native_byte}

        assert divergences == []

        # The programs self-modify -- `LD (HL), r` sometimes writes onto
        # chemin de PC — et fabriquent alors des opcodes que le natif ne sait
        # cannot emit yet. Equivalence covers the sane prefix; one cycle more
        # must make the native side fail on *that* opcode.
        if faulty do
          next_result = Run.run!(memory, state, budget + 1)

          assert next_result.statut == :unknown_opcode
          assert next_result.opcode == faulty
        end
      end
    end

    test "a linear program really does cross the whole table" do
      # Without this measurement the linear family could narrow unnoticed --
      # which is exactly what had happened to the other one.
      :rand.seed(:exsss, {1, 0, 0})
      memory = random_program(linear_opcodes())
      {_, _, _, _, seen} = trace(memory, random_state(), @steps)

      assert MapSet.size(seen) > 200,
             "only #{MapSet.size(seen)} distinct opcodes executed out of #{length(linear_opcodes())}"
    end
  end

  describe "cross-equivalence -- programs with jumps" do
    for seed <- @seeds do
      test "program with jumps, seed #{seed}" do
        :rand.seed(:exsss, {unquote(seed), 0, 0})

        memory = random_program(all_opcodes())
        state = random_state()

        {expected, oracle_memory, budget, faulty} = oracle(memory, state, @steps)

        result = Run.run!(memory, state, budget)

        assert result.status == :ok
        assert result.cycles == budget
        assert result.state == expected

        divergences =
          for addr <- 0..0xFFFF,
              oracle_byte = Flat.read8(oracle_memory, addr),
              native_byte = :binary.at(result.memory, addr),
              oracle_byte != native_byte,
              do: {addr, oracle_byte, native_byte}

        assert divergences == []

        if faulty do
          next_result = Run.run!(memory, state, budget + 1)

          assert next_result.statut == :unknown_opcode
          assert next_result.opcode == faulty
        end
      end
    end
  end

  # The interrupt hardware is what `loop_test.exs` calls its main client, and
  # random programs barely serve it: the service turns IME off, so it only
  # happens again after an `EI` or a `RETI`. Measured, three to seven services
  # across sixteen runs. Hence hand-written scenarios, each checked against the
  # oracle exactly as a random program is -- equivalence stays the contract, we
  # merely choose the inputs.
  describe "les interruptions" do
    test "an armed source diverts execution to its vector" do
      # Le bit 2 d'IF est le timer : vecteur 0x50.
      memory = program(%{0x100 => 0x00, 0xFF0F => 0x04, 0xFFFF => 0x1F})
      state = %State{pc: 0x100, sp: 0x200, ime: 1}

      result = equivalence!(memory, state, 1)

      assert result.state.pc == 0x50
      assert result.state.ime == 0, "the service turns IME off"
      assert result.state.sp == 0x1FE
      assert :binary.at(result.memory, 0x1FE) == 0x00, "PC pushed, low byte"
      assert :binary.at(result.memory, 0x1FF) == 0x01
      assert :binary.at(result.memory, 0xFF0F) == 0x00, "le bit servi retombe"
      assert result.cycles == 20
    end

    test "the lowest source goes first" do
      # Two armed sources: bit 1 (LCD STAT, vector 0x48) must win, and
      # le bit 2 rester en attente.
      memory = program(%{0x100 => 0x00, 0xFF0F => 0x06, 0xFFFF => 0x1F})

      result = equivalence!(memory, %State{pc: 0x100, sp: 0x200, ime: 1}, 1)

      assert result.state.pc == 0x48
      assert :binary.at(result.memory, 0xFF0F) == 0x04, "the other source waits its turn"
    end

    test "an armed source without enable diverts nothing" do
      memory = program(%{0x100 => 0x00, 0x101 => 0x00, 0xFF0F => 0x1F, 0xFFFF => 0x1F})

      result = equivalence!(memory, %State{pc: 0x100, sp: 0x200, ime: 0}, 2)

      assert result.state.pc == 0x102, "IME off: both NOPs run"
    end

    test "IE masks what IF armed" do
      # IF arme le timer, IE n'autorise que le vblank : rien ne passe.
      memory = program(%{0x100 => 0x00, 0xFF0F => 0x04, 0xFFFF => 0x01})

      result = equivalence!(memory, %State{pc: 0x100, sp: 0x200, ime: 1}, 1)

      assert result.state.pc == 0x101
      assert result.state.ime == 1
    end

    test "EI arms without enabling, and the state just after says so" do
      # The budget stops right after the EI, before the next `fetch` promotes
      # the arming -- the budget check comes first. That is the
      # seul instant où la distinction est observable, et sans ce test un `EI`
      # turning IME on directly would be indistinguishable: verified by
      # mutation, il passait les 42 autres tests.
      memory = program(%{0x100 => 0xFB, 0xFFFF => 0x00})

      result = equivalence!(memory, %State{pc: 0x100}, 1)

      assert result.state.ime == 0, "EI n'autorise pas encore"
      assert result.state.ime_pending == 1, "il arme"
    end

    test "EI arms, and the promotion shows on the next step" do
      memory = program(%{0x100 => 0xFB, 0x101 => 0x00, 0xFF0F => 0x01, 0xFFFF => 0x01})

      result = equivalence!(memory, %State{pc: 0x100, sp: 0x200}, 2)

      # Ce que fait exactement l'oracle est son affaire ; ce test exige que le
      # natif en soit indiscernable, et que l'autorisation ait bien pris.
      assert result.state.pc in [0x40, 0x102]
    end

    test "DI turns off what an EI had just turned on" do
      # No armed source, otherwise the service would leave as soon as the EI is
      # promoted -- that is, *before* the DI runs. So the arming is never
      # visible at an instruction boundary: `DI` clears `ime_pending` for
      # symmetry with the oracle, not because a program could
      # l'observer.
      memory = program(%{0x100 => 0xFB, 0x101 => 0xF3, 0x102 => 0x00, 0xFFFF => 0x00})

      result = equivalence!(memory, %State{pc: 0x100, sp: 0x200}, 3)

      assert result.state.ime == 0
      assert result.state.ime_pending == 0
      assert result.state.pc == 0x103
    end

    test "RETI re-enables IME immediately" do
      # La pile porte 0x0300 comme adresse de retour.
      memory = program(%{0x100 => 0xD9, 0x200 => 0x00, 0x201 => 0x03, 0x300 => 0x00})

      result = equivalence!(memory, %State{pc: 0x100, sp: 0x200}, 1)

      assert result.state.pc == 0x300
      assert result.state.ime == 1
      assert result.state.sp == 0x202
    end

    test "HALT sleeps in four-cycle steps while nothing is pending" do
      memory = program(%{0x100 => 0x76, 0xFF0F => 0x00, 0xFFFF => 0x00})

      result = equivalence!(memory, %State{pc: 0x100}, 40)

      assert result.state.halted, "still asleep"
      assert result.state.pc == 0x101, "PC no longer moves"
    end

    test "HALT wakes on an armed source, even with IME off" do
      memory = program(%{0x100 => 0x76, 0x101 => 0x00, 0xFF0F => 0x01, 0xFFFF => 0x01})

      result = equivalence!(memory, %State{pc: 0x100, sp: 0x200, ime: 0}, 3)

      refute result.state.halted, "waking does not need IME"
      assert result.state.pc == 0x102
    end
  end

  describe "code size" do
    test "the interpreter stays well under the C6 cache" do
      memory = :binary.copy(<<0x00>>, 0x10000)
      image = Interp.image(memory, %State{}, 1)

      # `table_base` opens the data section: everything before it is code. That
      # is the number that has to fit in 32 KB.
      code = image.labels[:table_base]

      assert code < 32 * 1024,
             "the code is #{code} bytes -- the C6 cache is 32768"
    end
  end

  # ══ Equivalence, in one line ═════════════════════════════════════════════════

  # Runs `steps` oracle steps, replays the same budget natively, and demands
  # nothing tells them apart -- state, cycles, and all 65536 bytes. Returns the
  # native result so the caller can additionally assert precise facts.
  defp equivalence!(memory, state, steps) do
    {expected, oracle_memory, budget, _faulty} = oracle(memory, state, steps)

    result = Run.run!(memory, state, budget)

    assert result.status == :ok
    assert result.cycles == budget
    assert result.state == expected

    divergences =
      for addr <- 0..0xFFFF,
          oracle_byte = Flat.read8(oracle_memory, addr),
          native_byte = :binary.at(result.memory, addr),
          oracle_byte != native_byte,
          do: {addr, oracle_byte, native_byte}

    assert divergences == []

    result
  end

  # ══ Generation ═══════════════════════════════════════════════════════════════

  # A 64 KB memory filled with 0xE3 -- an encoding that does not exist on the
  # SM83 -- with a few bytes placed where we want them. The filler is a guard:
  # if execution runs past the intended program it stops and says so,
  # au lieu de courir dans du bruit.
  #
  # It was HALT until stage eight. Now that HALT is implemented it would put
  # the processor to sleep instead of stopping it -- a guard that guards
  # plus rien est pire qu'une absence de garde.
  defp program(bytes) do
    for addr <- 0..0xFFFF, into: <<>>, do: <<Map.get(bytes, addr, 0xE3)>>
  end

  # One byte per address, drawn from the given pool -- so each draw is a valid
  # program end to end, which self-modifies, pushes and pops.
  defp random_program(opcodes) do
    0..0xFFFF
    |> Enum.map(fn _addr -> Enum.random(opcodes) end)
    |> :binary.list_to_bin()
  end

  # Everything the native side dispatches from an opcode byte, CB prefix too.
  defp all_opcodes, do: for({nil, op} <- Emit.coverage(), do: op)

  # The same pool minus everything that diverts PC. Execution then moves from
  # one instruction to the next and tours the 64 KB, which is the only way to
  # exercise every emitted opcode a great many times.
  defp linear_opcodes do
    jumps =
      for %Insn{prefix: nil, mnemonic: m, opcode: op} <- Table.base(),
          m in [:jr, :jp, :call, :ret, :rst],
          do: op

    all_opcodes() -- jumps
  end

  defp random_state do
    %State{
      a: :rand.uniform(256) - 1,
      # F: the top four bits only, as on hardware.
      f: (:rand.uniform(16) - 1) * 16,
      b: :rand.uniform(256) - 1,
      c: :rand.uniform(256) - 1,
      d: :rand.uniform(256) - 1,
      e: :rand.uniform(256) - 1,
      h: :rand.uniform(256) - 1,
      l: :rand.uniform(256) - 1,
      sp: :rand.uniform(0x10000) - 1,
      pc: :rand.uniform(0x10000) - 1,
      # Since stage eight the interrupt state is part of the draw. Measured:
      # that yields only three to seven services across the sixteen runs,
      # because the service turns IME off and only EI and RETI turn it back on.
      # So random programs prove almost nothing here -- the scenarios above do
      # that. `halted` stays out of the draw: a seed starting asleep with no
      # armed source sleeps its 5000 steps and
      # teste rien du tout.
      ime: :rand.uniform(2) - 1,
      ime_pending: :rand.uniform(2) - 1
    }
  end

  # N oracle steps over a flat memory initialised from the program. Returns
  # `{state, memory, budget_in_cycles, faulty_opcode | nil}`.
  #
  # The budget is the exact sum of those steps' cycles: if the native side
  # counted differently it would run a different number of instructions and the
  # states would diverge. The oracle stops by itself as soon as PC points at an
  # opcode outside what the native side can emit -- otherwise it would run on
  # alone, and the divergence would say "the native side stopped" rather than
  # "the native side got it wrong", which is entirely different information.
  defp oracle(memory, state, steps) do
    {st, mem, cycles, faulty, _seen} = trace(memory, state, steps)
    {st, mem, cycles, faulty}
  end

  # The same thing, plus the set of opcodes actually executed -- which
  # permet de mesurer la largeur d'une famille de programmes au lieu de la
  # supposer.
  defp trace(memory, state, steps) do
    plate =
      Flat.new(for {byte, addr} <- Enum.with_index(:binary.bin_to_list(memory)), do: {addr, byte})

    loop_steps(state, plate, 0, steps, MapSet.new())
  end

  defp loop_steps(st, mem, cycles, 0, seen), do: {st, mem, cycles, nil, seen}

  # Stopping happens on exception rather than by pre-checking the opcode: with
  # the table fully emitted, what the native side refuses and what the oracle
  # refuses coincide exactly. And the pre-check read the byte under PC even when
  # the processor was asleep or servicing an interrupt, so in the wrong
  # endroit. C'est la structure de `loop_test.exs`.
  defp loop_steps(st, mem, cycles, steps, seen) do
    seen = if st.halted, do: seen, else: MapSet.put(seen, Flat.read8(mem, st.pc))
    {suite, mem, pas} = Atomboy.CPU.tick(st, mem)
    loop_steps(suite, mem, cycles + pas, steps - 1, seen)
  rescue
    error in Atomboy.CPU.Unimplemented -> {st, mem, cycles, error.opcode, seen}
  end
end
