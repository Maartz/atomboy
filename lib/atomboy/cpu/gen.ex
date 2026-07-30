defmodule Atomboy.CPU.Gen do
  @moduledoc """
  Translates an `Atomboy.CPU.Insn` into code, at compile time — for two backends.

  This is the only layer that knows the calling conventions. `Atomboy.CPU.Table`
  describes *what*, this module decides *how* — and it decides it twice:

    * **`clause/1` — the struct backend.** `exec(opcode, %State{}, mem)` returns
      `{state, mem, cycles}`. One allocation per instruction, an observable state
      after each one: this is the oracle. The SM83 vectors validate it, debugging
      happens here, and phase 5 will compare the recompiled code against it.

    * **`loop_clause/1` — the fast loop.** The registers travel as function
      arguments, every clause ends in a tail call to the next fetch, and nothing
      is built until the cycle budget runs out. In AOT native code, those
      arguments become machine registers.

  Why two backends rather than one: measurement. On native AtomVM, the struct
  loop tops out at ×1.21 over interpreted — Amdahl's law, all the time goes into
  map BIFs that the native compiler does not compile. The map-free probe gave
  ×43. The struct's comfort stays where the state gets read; the speed goes where
  nothing gets read.

  The semantics, meanwhile, are written only once: both emitters share the same
  table and the same `Atomboy.CPU.ALU` primitives. A cross-equivalence test locks
  down the rest.
  """

  alias Atomboy.CPU.Insn

  @state [:a, :f, :b, :c, :d, :e, :h, :l, :sp, :pc]

  # The non-register state the fast loop carries in addition: IME (RETI, EI, DI)
  # and halted (HALT). Extending this list extends the loop — clause heads, tail
  # calls and materialisation all follow.
  @loop_extra [:ime, :halted, :ime_pending]

  @doc "The registers that make up the state, in argument order."
  @spec state_names() :: [atom()]
  def state_names, do: @state

  @doc """
  An unhygienic variable.

  The `nil` context is essential: these variables are built here but have to bind
  to the ones in the caller's function head. With the default context they would
  belong to this module and match nothing.
  """
  @spec var(atom()) :: Macro.t()
  def var(name), do: Macro.var(name, nil)

  # ══ Struct backend ═══════════════════════════════════════════════════════════

  @doc """
  The `exec/3` clause (struct backend) for one instruction.

  Returns `{arguments, body}`, to be injected through `unquote_splicing/1` and
  `unquote/1` into a `def` at the call site.
  """
  @spec clause(Insn.t()) :: {[Macro.t()], Macro.t()}
  def clause(%Insn{} = insn), do: {[var(:st), var(:mem)], struct_body(insn)}

  defp struct_body(%Insn{mnemonic: :nop, cycles: cycles}) do
    struct_ret(var(:st), var(:mem), cycles)
  end

  # LD r, d8 and LD (HL), d8 — the immediate is read at PC, which advances one
  # step further. The immediate is bound to a variable before the call: the read
  # has to precede any memory write, and an already-advanced PC must not be
  # reused for the read.
  defp struct_body(%Insn{mnemonic: :ld, operands: [dst, {:imm, 8}], cycles: cycles}) do
    imm = Macro.var(:imm, __MODULE__)
    read = quote do: unquote(imm) = mem_read_pc(unquote(var(:mem)), unquote(var(:st)))
    bumped = quote do: Bitwise.band(unquote(field(:pc)) + 1, 0xFFFF)

    tail =
      case dst do
        {:reg, name} ->
          struct_ret(struct_update(%{name => imm, pc: bumped}), var(:mem), cycles)

        :hl_ind ->
          write = quote do: mem_write(unquote(var(:mem)), unquote(var(:st)), unquote(imm))
          struct_ret(struct_update(%{pc: bumped}), write, cycles)
      end

    quote do
      unquote(read)
      unquote(tail)
    end
  end

  # STOP — one byte and nothing else in the corpus's model; see the table.
  defp struct_body(%Insn{mnemonic: :stop, cycles: cycles}) do
    struct_ret(var(:st), var(:mem), cycles)
  end

  # JR — one signed byte of offset, relative to the PC that follows the operand.
  # The sign is computed branch-free: subtract 256 when bit 7 is set.
  defp struct_body(%Insn{mnemonic: :jr, operands: [{:imm, 8}]} = insn) do
    offset = Macro.var(:offset, __MODULE__)

    target =
      quote do:
              Bitwise.band(
                unquote(field(:pc)) + 1 + unquote(offset) -
                  Bitwise.bsl(Bitwise.bsr(unquote(offset), 7), 8),
                0xFFFF
              )

    taken = struct_ret(struct_update(%{pc: target}), var(:mem), insn.cycles)

    body =
      case insn.condition do
        nil ->
          taken

        condition ->
          skipped = quote do: Bitwise.band(unquote(field(:pc)) + 1, 0xFFFF)
          untaken = struct_ret(struct_update(%{pc: skipped}), var(:mem), insn.cycles_untaken)

          quote do
            if unquote(condition_expr(condition, field(:f))) do
              unquote(taken)
            else
              unquote(untaken)
            end
          end
      end

    quote do
      unquote(offset) = mem_read_pc(unquote(var(:mem)), unquote(var(:st)))
      unquote(body)
    end
  end

  # LD (a16), SP — the one direct 16-bit write.
  defp struct_body(%Insn{mnemonic: :ld, operands: [:a16_ind, {:pair, :sp}], cycles: cycles}) do
    addr = Macro.var(:addr, __MODULE__)
    bumped = quote do: Bitwise.band(unquote(field(:pc)) + 2, 0xFFFF)

    write =
      quote do: mem_write16_at(unquote(var(:mem)), unquote(addr), unquote(field(:sp)))

    quote do
      unquote(addr) = mem_read_pc16(unquote(var(:mem)), unquote(var(:st)))
      unquote(struct_ret(struct_update(%{pc: bumped}), write, cycles))
    end
  end

  # LD (BC/DE/HL±), A — writes A at a pair's address, with HL post-adjusted for
  # the last two forms.
  defp struct_body(%Insn{mnemonic: :ld, operands: [{:ind, target}, {:reg, :a}], cycles: cycles}) do
    addr = Macro.var(:addr, __MODULE__)
    write = quote do: mem_write_at(unquote(var(:mem)), unquote(addr), unquote(field(:a)))

    quote do
      unquote(addr) = unquote(struct_pair_read(ind_pair(target)))

      unquote(
        struct_ret(
          struct_update(ind_overrides(target, addr, &struct_pair_overrides/2)),
          write,
          cycles
        )
      )
    end
  end

  # LD A, (BC/DE/HL±).
  defp struct_body(%Insn{mnemonic: :ld, operands: [{:reg, :a}, {:ind, target}], cycles: cycles}) do
    addr = Macro.var(:addr, __MODULE__)
    value = Macro.var(:value, __MODULE__)

    overrides =
      Map.put(ind_overrides(target, addr, &struct_pair_overrides/2), :a, value)

    quote do
      unquote(addr) = unquote(struct_pair_read(ind_pair(target)))
      unquote(value) = mem_read_at(unquote(var(:mem)), unquote(addr))
      unquote(struct_ret(struct_update(overrides), var(:mem), cycles))
    end
  end

  # LD (HL), r — memory changes, the state does not: `st` goes back out as-is.
  defp struct_body(%Insn{mnemonic: :ld, operands: [:hl_ind, src], cycles: cycles}) do
    write = quote do: mem_write(unquote(var(:mem)), unquote(var(:st)), unquote(struct_read(src)))
    struct_ret(var(:st), write, cycles)
  end

  # LD r, r' and LD r, (HL) — a single field changes. The guard rules out the I/O
  # operands, which have clauses of their own: without it, clause order would
  # decide silently.
  defp struct_body(%Insn{mnemonic: :ld, operands: [{:reg, dst}, src], cycles: cycles})
       when is_tuple(src) or src == :hl_ind do
    struct_ret(struct_update(%{dst => struct_read(src)}), var(:mem), cycles)
  end

  # JP HL — no memory access at all, despite the "JP (HL)" notation: PC receives
  # the pair. The computed jump of phase 5's future trampoline.
  defp struct_body(%Insn{mnemonic: :jp, operands: [{:pair, :hl}], cycles: cycles}) do
    struct_ret(struct_update(%{pc: struct_pair_read({:pair, :hl})}), var(:mem), cycles)
  end

  # JP a16 and its conditional forms.
  defp struct_body(%Insn{mnemonic: :jp, operands: [{:imm, 16}]} = insn) do
    target = Macro.var(:target, __MODULE__)
    taken = struct_ret(struct_update(%{pc: target}), var(:mem), insn.cycles)

    body =
      conditional(insn, field(:f), taken, fn ->
        skipped = quote do: Bitwise.band(unquote(field(:pc)) + 2, 0xFFFF)
        struct_ret(struct_update(%{pc: skipped}), var(:mem), insn.cycles_untaken)
      end)

    quote do
      unquote(target) = mem_read_pc16(unquote(var(:mem)), unquote(var(:st)))
      unquote(body)
    end
  end

  # CALL a16 — the return address (PC past the operand) goes onto the stack.
  defp struct_body(%Insn{mnemonic: :call, operands: [{:imm, 16}]} = insn) do
    target = Macro.var(:target, __MODULE__)
    new_sp = Macro.var(:new_sp, __MODULE__)
    return_to = quote do: Bitwise.band(unquote(field(:pc)) + 2, 0xFFFF)

    taken =
      quote do
        unquote(new_sp) = Bitwise.band(unquote(field(:sp)) - 2, 0xFFFF)

        unquote(
          struct_ret(
            struct_update(%{pc: target, sp: new_sp}),
            quote(do: mem_write16_at(unquote(var(:mem)), unquote(new_sp), unquote(return_to))),
            insn.cycles
          )
        )
      end

    body =
      conditional(insn, field(:f), taken, fn ->
        struct_ret(struct_update(%{pc: return_to}), var(:mem), insn.cycles_untaken)
      end)

    quote do
      unquote(target) = mem_read_pc16(unquote(var(:mem)), unquote(var(:st)))
      unquote(body)
    end
  end

  # RET, RET cc, RETI — the stack read only happens if the return is taken, and
  # RETI switches IME back on in the same breath.
  defp struct_body(%Insn{mnemonic: mnemonic, operands: []} = insn)
       when mnemonic in [:ret, :reti] do
    value = Macro.var(:value, __MODULE__)
    bumped = quote do: Bitwise.band(unquote(field(:sp)) + 2, 0xFFFF)
    extra = if mnemonic == :reti, do: %{ime: 1}, else: %{}

    taken =
      quote do
        unquote(value) = mem_read16_at(unquote(var(:mem)), unquote(field(:sp)))

        unquote(
          struct_ret(
            struct_update(Map.merge(%{pc: value, sp: bumped}, extra)),
            var(:mem),
            insn.cycles
          )
        )
      end

    conditional(insn, field(:f), taken, fn ->
      struct_ret(var(:st), var(:mem), insn.cycles_untaken)
    end)
  end

  # RST — a CALL to a fixed target encoded in the opcode.
  defp struct_body(%Insn{mnemonic: :rst, operands: [{:rst, target}], cycles: cycles}) do
    new_sp = Macro.var(:new_sp, __MODULE__)

    quote do
      unquote(new_sp) = Bitwise.band(unquote(field(:sp)) - 2, 0xFFFF)

      unquote(
        struct_ret(
          struct_update(%{pc: target, sp: new_sp}),
          quote(do: mem_write16_at(unquote(var(:mem)), unquote(new_sp), unquote(field(:pc)))),
          cycles
        )
      )
    end
  end

  # PUSH rr — SP drops by two, the pair is written little-endian at the new SP.
  defp struct_body(%Insn{mnemonic: :push, operands: [pair], cycles: cycles}) do
    new_sp = Macro.var(:new_sp, __MODULE__)

    write =
      quote do:
              mem_write16_at(unquote(var(:mem)), unquote(new_sp), unquote(struct_pair_read(pair)))

    quote do
      unquote(new_sp) = Bitwise.band(unquote(field(:sp)) - 2, 0xFFFF)
      unquote(struct_ret(struct_update(%{sp: new_sp}), write, cycles))
    end
  end

  # POP rr — read at the current SP, then SP climbs back by two. See
  # pop_overrides/3 for POP AF's mask.
  defp struct_body(%Insn{mnemonic: :pop, operands: [pair], cycles: cycles}) do
    value = Macro.var(:value, __MODULE__)
    bumped = quote do: Bitwise.band(unquote(field(:sp)) + 2, 0xFFFF)

    overrides =
      pop_overrides(pair, value, &struct_pair_overrides/2)
      |> Map.put(:sp, bumped)

    quote do
      unquote(value) = mem_read16_at(unquote(var(:mem)), unquote(field(:sp)))
      unquote(struct_ret(struct_update(overrides), var(:mem), cycles))
    end
  end

  # The accumulator operations (z=7) — a uniform (a, f) → {a, f} signature on the
  # ALU side, hence a single clause for all eight.
  defp struct_body(%Insn{mnemonic: mnemonic, operands: [], cycles: cycles})
       when mnemonic in [:rlca, :rrca, :rla, :rra, :daa, :cpl, :scf, :ccf] do
    result = Macro.var(:result, __MODULE__)
    f = Macro.var(:new_f, __MODULE__)
    call = {{:., [], [Atomboy.CPU.ALU, mnemonic]}, [], [field(:a), field(:f)]}

    quote do
      {unquote(result), unquote(f)} = unquote(call)
      unquote(struct_ret(struct_update(%{a: result, f: f}), var(:mem), cycles))
    end
  end

  # LD rr, d16 — the immediate word, little-endian, PC advances by two.
  defp struct_body(%Insn{mnemonic: :ld, operands: [{:pair, _} = dst, {:imm, 16}], cycles: cycles}) do
    imm = Macro.var(:imm, __MODULE__)
    bumped = quote do: Bitwise.band(unquote(field(:pc)) + 2, 0xFFFF)
    overrides = Map.merge(struct_pair_overrides(dst, imm), %{pc: bumped})

    quote do
      unquote(imm) = mem_read_pc16(unquote(var(:mem)), unquote(var(:st)))
      unquote(struct_ret(struct_update(overrides), var(:mem), cycles))
    end
  end

  # ADD HL, rr — the one 16-bit addition; Z preserved, see ALU.add16/3.
  defp struct_body(%Insn{mnemonic: :add, operands: [{:pair, :hl}, src], cycles: cycles}) do
    result = Macro.var(:result, __MODULE__)
    f = Macro.var(:new_f, __MODULE__)

    call =
      quote do:
              Atomboy.CPU.ALU.add16(
                unquote(struct_pair_read({:pair, :hl})),
                unquote(struct_pair_read(src)),
                unquote(field(:f))
              )

    overrides = Map.merge(struct_pair_overrides({:pair, :hl}, result), %{f: f})

    quote do
      {unquote(result), unquote(f)} = unquote(call)
      unquote(struct_ret(struct_update(overrides), var(:mem), cycles))
    end
  end

  # INC rr / DEC rr — pure 16-bit arithmetic, no flags.
  defp struct_body(%Insn{mnemonic: mnemonic, operands: [{:pair, _} = target], cycles: cycles})
       when mnemonic in [:inc, :dec] do
    result = Macro.var(:result, __MODULE__)
    delta = if mnemonic == :inc, do: 1, else: -1

    quote do
      unquote(result) =
        Bitwise.band(unquote(struct_pair_read(target)) + unquote(delta), 0xFFFF)

      unquote(struct_ret(struct_update(struct_pair_overrides(target, result)), var(:mem), cycles))
    end
  end

  # INC r / DEC r and the eight CB rotations/shifts — the same shape:
  # (value, F) → {value, F}, with the primitive carrying all the semantics.
  defp struct_body(%Insn{mnemonic: mnemonic, operands: [{:reg, name}], cycles: cycles})
       when mnemonic in [:inc, :dec, :rlc, :rrc, :rl, :rr, :sla, :sra, :swap, :srl] do
    result = Macro.var(:result, __MODULE__)
    f = Macro.var(:new_f, __MODULE__)
    call = {{:., [], [Atomboy.CPU.ALU, mnemonic]}, [], [field(name), field(:f)]}

    quote do
      {unquote(result), unquote(f)} = unquote(call)
      unquote(struct_ret(struct_update(%{name => result, f: f}), var(:mem), cycles))
    end
  end

  # INC (HL) / DEC (HL) and the (HL) rotations — read-modify-write: the value goes
  # through memory both ways, and F is the only thing that changes in the state.
  defp struct_body(%Insn{mnemonic: mnemonic, operands: [:hl_ind], cycles: cycles})
       when mnemonic in [:inc, :dec, :rlc, :rrc, :rl, :rr, :sla, :sra, :swap, :srl] do
    result = Macro.var(:result, __MODULE__)
    f = Macro.var(:new_f, __MODULE__)
    call = {{:., [], [Atomboy.CPU.ALU, mnemonic]}, [], [struct_read(:hl_ind), field(:f)]}

    quote do
      {unquote(result), unquote(f)} = unquote(call)

      unquote(
        struct_ret(
          struct_update(%{f: f}),
          quote(do: mem_write(unquote(var(:mem)), unquote(var(:st)), unquote(result))),
          cycles
        )
      )
    end
  end

  # DI / EI / HALT — one control field each.
  # BIT n — read-only, F alone changes; C passes through.
  defp struct_body(%Insn{mnemonic: :bit, operands: [{:bit, n}, target], cycles: cycles}) do
    f = Macro.var(:new_f, __MODULE__)

    quote do
      unquote(f) =
        Atomboy.CPU.ALU.bit_test(unquote(n), unquote(struct_read(target)), unquote(field(:f)))

      unquote(struct_ret(struct_update(%{f: f}), var(:mem), cycles))
    end
  end

  # RES n / SET n — the bit cleared or set, no flags. The arithmetic is inline:
  # there is no subtlety here worth centralising.
  defp struct_body(%Insn{mnemonic: mnemonic, operands: [{:bit, n}, target], cycles: cycles})
       when mnemonic in [:res, :set] do
    result = Macro.var(:result, __MODULE__)
    mask = Bitwise.bsl(1, n)

    expr =
      case mnemonic do
        :res ->
          quote do: Bitwise.band(unquote(struct_read(target)), unquote(Bitwise.bxor(mask, 0xFF)))

        :set ->
          quote do: Bitwise.bor(unquote(struct_read(target)), unquote(mask))
      end

    tail =
      case target do
        {:reg, name} ->
          struct_ret(struct_update(%{name => result}), var(:mem), cycles)

        :hl_ind ->
          write = quote do: mem_write(unquote(var(:mem)), unquote(var(:st)), unquote(result))
          struct_ret(var(:st), write, cycles)
      end

    quote do
      unquote(result) = unquote(expr)
      unquote(tail)
    end
  end

  # DI cuts everything off, including a preceding EI's deferred arming.
  defp struct_body(%Insn{mnemonic: :di, cycles: cycles}),
    do: struct_ret(struct_update(%{ime: 0, ime_pending: 0}), var(:mem), cycles)

  # EI does not enable: it arms. The promotion happens on the next step, in step/2
  # on the oracle side and in fetch on the loop side — the same point in both.
  defp struct_body(%Insn{mnemonic: :ei, cycles: cycles}),
    do: struct_ret(struct_update(%{ime_pending: 1}), var(:mem), cycles)

  defp struct_body(%Insn{mnemonic: :halt, cycles: cycles}),
    do: struct_ret(struct_update(%{halted: true}), var(:mem), cycles)

  # LD SP, HL.
  defp struct_body(%Insn{mnemonic: :ld, operands: [{:pair, :sp}, {:pair, :hl}], cycles: cycles}) do
    struct_ret(struct_update(%{sp: struct_pair_read({:pair, :hl})}), var(:mem), cycles)
  end

  # ADD SP, r8 and LD HL, SP+r8 — same arithmetic, different destination.
  defp struct_body(%Insn{mnemonic: :add_sp, operands: [dst, {:imm, 8}], cycles: cycles}) do
    imm = Macro.var(:imm, __MODULE__)
    result = Macro.var(:result, __MODULE__)
    f = Macro.var(:new_f, __MODULE__)
    bumped = quote do: Bitwise.band(unquote(field(:pc)) + 1, 0xFFFF)

    overrides =
      case dst do
        {:pair, :sp} -> %{sp: result}
        {:pair, :hl} -> struct_pair_overrides({:pair, :hl}, result)
      end
      |> Map.merge(%{f: f, pc: bumped})

    quote do
      unquote(imm) = mem_read_pc(unquote(var(:mem)), unquote(var(:st)))

      {unquote(result), unquote(f)} =
        Atomboy.CPU.ALU.add_sp(unquote(field(:sp)), unquote(imm))

      unquote(struct_ret(struct_update(overrides), var(:mem), cycles))
    end
  end

  # LDH and the absolute LDs of A — the high page (0xFF00 + a8, or + C) and the
  # direct 16-bit address share the same mechanics; only the address changes.
  defp struct_body(%Insn{mnemonic: mnemonic, operands: [io, {:reg, :a}], cycles: cycles})
       when io in [:a8_ind, :c_ind, :a16_ind] and mnemonic in [:ld, :ldh] do
    {prelude, addr, pc_overrides} = struct_io(io)
    write = quote do: mem_write_at(unquote(var(:mem)), unquote(addr), unquote(field(:a)))

    quote do
      unquote_splicing(prelude)
      unquote(struct_ret(struct_update(pc_overrides), write, cycles))
    end
  end

  defp struct_body(%Insn{mnemonic: mnemonic, operands: [{:reg, :a}, io], cycles: cycles})
       when io in [:a8_ind, :c_ind, :a16_ind] and mnemonic in [:ld, :ldh] do
    {prelude, addr, pc_overrides} = struct_io(io)
    value = Macro.var(:value, __MODULE__)

    quote do
      unquote_splicing(prelude)
      unquote(value) = mem_read_at(unquote(var(:mem)), unquote(addr))
      unquote(struct_ret(struct_update(Map.put(pc_overrides, :a, value)), var(:mem), cycles))
    end
  end

  # ALU A, d8 — the immediate as the source.
  defp struct_body(%Insn{mnemonic: :cp, operands: [{:reg, :a}, {:imm, 8}], cycles: cycles}) do
    imm = Macro.var(:imm, __MODULE__)
    f = Macro.var(:new_f, __MODULE__)
    bumped = quote do: Bitwise.band(unquote(field(:pc)) + 1, 0xFFFF)

    quote do
      unquote(imm) = mem_read_pc(unquote(var(:mem)), unquote(var(:st)))
      unquote(f) = Atomboy.CPU.ALU.cp(unquote(field(:a)), unquote(imm))
      unquote(struct_ret(struct_update(%{f: f, pc: bumped}), var(:mem), cycles))
    end
  end

  defp struct_body(%Insn{mnemonic: mnemonic, operands: [{:reg, :a}, {:imm, 8}], cycles: cycles})
       when mnemonic in [:add, :adc, :sub, :sbc, :and, :xor, :or] do
    imm = Macro.var(:imm, __MODULE__)
    result = Macro.var(:result, __MODULE__)
    f = Macro.var(:new_f, __MODULE__)
    bumped = quote do: Bitwise.band(unquote(field(:pc)) + 1, 0xFFFF)

    quote do
      unquote(imm) = mem_read_pc(unquote(var(:mem)), unquote(var(:st)))

      {unquote(result), unquote(f)} =
        unquote(alu_call(mnemonic, field(:a), field(:f), imm))

      unquote(struct_ret(struct_update(%{a: result, f: f, pc: bumped}), var(:mem), cycles))
    end
  end

  # ALU — the arithmetic lives in Atomboy.CPU.ALU, at the value level. All we do
  # here is wrap the result in the struct update.
  defp struct_body(%Insn{mnemonic: :cp, operands: [{:reg, :a}, src], cycles: cycles}) do
    f = Macro.var(:new_f, __MODULE__)

    quote do
      unquote(f) = Atomboy.CPU.ALU.cp(unquote(field(:a)), unquote(struct_read(src)))
      unquote(struct_ret(struct_update(%{f: f}), var(:mem), cycles))
    end
  end

  defp struct_body(%Insn{mnemonic: mnemonic, operands: [{:reg, :a}, src], cycles: cycles})
       when mnemonic in [:add, :adc, :sub, :sbc, :and, :xor, :or] do
    result = Macro.var(:result, __MODULE__)
    f = Macro.var(:new_f, __MODULE__)

    quote do
      {unquote(result), unquote(f)} =
        unquote(alu_call(mnemonic, field(:a), field(:f), struct_read(src)))

      unquote(struct_ret(struct_update(%{a: result, f: f}), var(:mem), cycles))
    end
  end

  defp struct_read(:hl_ind) do
    quote do: mem_read(unquote(var(:mem)), unquote(var(:st)))
  end

  defp struct_read({:reg, name}), do: field(name)

  # An I/O operand's address: `{prelude, address expression, PC overrides}`. The
  # prelude reads the immediate, if there is one.
  defp struct_io(:c_ind) do
    {[], quote(do: Bitwise.bor(0xFF00, unquote(field(:c)))), %{}}
  end

  defp struct_io(:a8_ind) do
    imm = Macro.var(:imm, __MODULE__)
    prelude = quote do: unquote(imm) = mem_read_pc(unquote(var(:mem)), unquote(var(:st)))
    bumped = quote do: Bitwise.band(unquote(field(:pc)) + 1, 0xFFFF)
    {[prelude], quote(do: Bitwise.bor(0xFF00, unquote(imm))), %{pc: bumped}}
  end

  defp struct_io(:a16_ind) do
    addr = Macro.var(:addr, __MODULE__)
    prelude = quote do: unquote(addr) = mem_read_pc16(unquote(var(:mem)), unquote(var(:st)))
    bumped = quote do: Bitwise.band(unquote(field(:pc)) + 2, 0xFFFF)
    {[prelude], addr, %{pc: bumped}}
  end

  defp struct_pair_read({:pair, :sp}), do: field(:sp)

  defp struct_pair_read({:pair, name}) do
    {hi, lo} = pair_regs(name)
    quote do: Bitwise.bsl(unquote(field(hi)), 8) |> Bitwise.bor(unquote(field(lo)))
  end

  # The state overrides that write `value` — an expression already bound to a
  # variable, never re-evaluated — into a pair.
  defp struct_pair_overrides({:pair, :sp}, value), do: %{sp: value}

  defp struct_pair_overrides({:pair, name}, value) do
    {hi, lo} = pair_regs(name)

    %{
      hi => quote(do: Bitwise.bsr(unquote(value), 8)),
      lo => quote(do: Bitwise.band(unquote(value), 0xFF))
    }
  end

  # `st.<name>`
  defp field(name), do: {{:., [], [var(:st), name]}, [no_parens: true], []}

  # `%{st | field: value, ...}` — a single update, all fields grouped. With no
  # overrides, `st` goes back out as-is: no allocation at all.
  defp struct_update(fields) when map_size(fields) == 0, do: var(:st)

  defp struct_update(fields) do
    {:%{}, [], [{:|, [], [var(:st), Enum.to_list(fields)]}]}
  end

  defp struct_ret(state_expr, mem_expr, cycles) do
    {:{}, [], [state_expr, mem_expr, cycles]}
  end

  # ══ Fast loop backend ════════════════════════════════════════════════════════

  @doc """
  `Atomboy.CPU.Loop`'s `exec/15` clause for one instruction.

  The head receives `(opcode, rom, ram, budget, cycles, a, f, b, c, d, e, h, l,
  sp, pc)`; the body ends in a tail call to `fetch/14` with the updated registers.
  Variables the body does not read are underscored in the head — `LD B, C`
  overwrites `b` without reading it, and across hundreds of generated clauses the
  spurious warnings would drown out the ones that matter.
  """
  @spec loop_clause(Insn.t()) :: {[Macro.t()], Macro.t()}
  def loop_clause(%Insn{} = insn) do
    body = loop_body(insn)
    {loop_args(body), body}
  end

  defp loop_body(%Insn{mnemonic: :nop, cycles: cycles}) do
    loop_ret(%{}, var(:ram), cycles)
  end

  # STOP — see the struct backend.
  defp loop_body(%Insn{mnemonic: :stop, cycles: cycles}) do
    loop_ret(%{}, var(:ram), cycles)
  end

  # JR — see the struct backend's comment for how the sign is computed.
  defp loop_body(%Insn{mnemonic: :jr, operands: [{:imm, 8}]} = insn) do
    offset = Macro.var(:offset, __MODULE__)

    target =
      quote do:
              Bitwise.band(
                unquote(var(:pc)) + 1 + unquote(offset) -
                  Bitwise.bsl(Bitwise.bsr(unquote(offset), 7), 8),
                0xFFFF
              )

    taken = loop_ret(%{pc: target}, var(:ram), insn.cycles)

    body =
      case insn.condition do
        nil ->
          taken

        condition ->
          skipped = quote do: Bitwise.band(unquote(var(:pc)) + 1, 0xFFFF)
          untaken = loop_ret(%{pc: skipped}, var(:ram), insn.cycles_untaken)

          quote do
            if unquote(condition_expr(condition, var(:f))) do
              unquote(taken)
            else
              unquote(untaken)
            end
          end
      end

    quote do
      unquote(offset) = mem_read(unquote(var(:rom)), unquote(var(:ram)), unquote(var(:pc)))
      unquote(body)
    end
  end

  # LD (a16), SP — two chained writes, little-endian.
  defp loop_body(%Insn{mnemonic: :ld, operands: [:a16_ind, {:pair, :sp}], cycles: cycles}) do
    addr = Macro.var(:addr, __MODULE__)
    lo = Macro.var(:lo, __MODULE__)
    hi = Macro.var(:hi, __MODULE__)
    bumped = quote do: Bitwise.band(unquote(var(:pc)) + 2, 0xFFFF)

    ram =
      quote do
        ram_write(
          ram_write(unquote(var(:ram)), unquote(addr), Bitwise.band(unquote(var(:sp)), 0xFF)),
          Bitwise.band(unquote(addr) + 1, 0xFFFF),
          Bitwise.bsr(unquote(var(:sp)), 8)
        )
      end

    quote do
      unquote(lo) = mem_read(unquote(var(:rom)), unquote(var(:ram)), unquote(var(:pc)))

      unquote(hi) =
        mem_read(
          unquote(var(:rom)),
          unquote(var(:ram)),
          Bitwise.band(unquote(var(:pc)) + 1, 0xFFFF)
        )

      unquote(addr) = Bitwise.bsl(unquote(hi), 8) |> Bitwise.bor(unquote(lo))
      unquote(loop_ret(%{pc: bumped}, ram, cycles))
    end
  end

  # LD (BC/DE/HL±), A.
  defp loop_body(%Insn{mnemonic: :ld, operands: [{:ind, target}, {:reg, :a}], cycles: cycles}) do
    addr = Macro.var(:addr, __MODULE__)
    ram = quote do: ram_write(unquote(var(:ram)), unquote(addr), unquote(var(:a)))

    quote do
      unquote(addr) = unquote(loop_pair_read(ind_pair(target)))
      unquote(loop_ret(ind_overrides(target, addr, &loop_pair_overrides/2), ram, cycles))
    end
  end

  # LD A, (BC/DE/HL±).
  defp loop_body(%Insn{mnemonic: :ld, operands: [{:reg, :a}, {:ind, target}], cycles: cycles}) do
    addr = Macro.var(:addr, __MODULE__)
    value = Macro.var(:value, __MODULE__)
    overrides = Map.put(ind_overrides(target, addr, &loop_pair_overrides/2), :a, value)

    quote do
      unquote(addr) = unquote(loop_pair_read(ind_pair(target)))
      unquote(value) = mem_read(unquote(var(:rom)), unquote(var(:ram)), unquote(addr))
      unquote(loop_ret(overrides, var(:ram), cycles))
    end
  end

  # LD r, d8 / LD (HL), d8 — same logic as on the struct side: read the immediate
  # at PC, then leave with PC advanced one step further.
  defp loop_body(%Insn{mnemonic: :ld, operands: [dst, {:imm, 8}], cycles: cycles}) do
    imm = Macro.var(:imm, __MODULE__)

    read =
      quote do:
              unquote(imm) =
                mem_read(unquote(var(:rom)), unquote(var(:ram)), unquote(var(:pc)))

    bumped = quote do: Bitwise.band(unquote(var(:pc)) + 1, 0xFFFF)

    tail =
      case dst do
        {:reg, name} ->
          loop_ret(%{name => imm, pc: bumped}, var(:ram), cycles)

        :hl_ind ->
          ram = quote do: ram_write(unquote(var(:ram)), unquote(hl()), unquote(imm))
          loop_ret(%{pc: bumped}, ram, cycles)
      end

    quote do
      unquote(read)
      unquote(tail)
    end
  end

  defp loop_body(%Insn{mnemonic: :ld, operands: [:hl_ind, src], cycles: cycles}) do
    ram = quote do: ram_write(unquote(var(:ram)), unquote(hl()), unquote(loop_read(src)))
    loop_ret(%{}, ram, cycles)
  end

  # Same guard as the equivalent struct clause: the I/O operands have clauses of
  # their own.
  defp loop_body(%Insn{mnemonic: :ld, operands: [{:reg, dst}, src], cycles: cycles})
       when is_tuple(src) or src == :hl_ind do
    loop_ret(%{dst => loop_read(src)}, var(:ram), cycles)
  end

  # DI / EI / HALT.
  # BIT n.
  defp loop_body(%Insn{mnemonic: :bit, operands: [{:bit, n}, target], cycles: cycles}) do
    f = Macro.var(:new_f, __MODULE__)

    quote do
      unquote(f) =
        Atomboy.CPU.ALU.bit_test(unquote(n), unquote(loop_read(target)), unquote(var(:f)))

      unquote(loop_ret(%{f: f}, var(:ram), cycles))
    end
  end

  # RES n / SET n.
  defp loop_body(%Insn{mnemonic: mnemonic, operands: [{:bit, n}, target], cycles: cycles})
       when mnemonic in [:res, :set] do
    result = Macro.var(:result, __MODULE__)
    mask = Bitwise.bsl(1, n)

    expr =
      case mnemonic do
        :res ->
          quote do: Bitwise.band(unquote(loop_read(target)), unquote(Bitwise.bxor(mask, 0xFF)))

        :set ->
          quote do: Bitwise.bor(unquote(loop_read(target)), unquote(mask))
      end

    tail =
      case target do
        {:reg, name} ->
          loop_ret(%{name => result}, var(:ram), cycles)

        :hl_ind ->
          ram = quote do: ram_write(unquote(var(:ram)), unquote(hl()), unquote(result))
          loop_ret(%{}, ram, cycles)
      end

    quote do
      unquote(result) = unquote(expr)
      unquote(tail)
    end
  end

  defp loop_body(%Insn{mnemonic: :di, cycles: cycles}),
    do: loop_ret(%{ime: 0, ime_pending: 0}, var(:ram), cycles)

  defp loop_body(%Insn{mnemonic: :ei, cycles: cycles}),
    do: loop_ret(%{ime_pending: 1}, var(:ram), cycles)

  defp loop_body(%Insn{mnemonic: :halt, cycles: cycles}),
    do: loop_ret(%{halted: true}, var(:ram), cycles)

  # LD SP, HL.
  defp loop_body(%Insn{mnemonic: :ld, operands: [{:pair, :sp}, {:pair, :hl}], cycles: cycles}) do
    loop_ret(%{sp: loop_pair_read({:pair, :hl})}, var(:ram), cycles)
  end

  # ADD SP, r8 et LD HL, SP+r8.
  defp loop_body(%Insn{mnemonic: :add_sp, operands: [dst, {:imm, 8}], cycles: cycles}) do
    imm = Macro.var(:imm, __MODULE__)
    result = Macro.var(:result, __MODULE__)
    f = Macro.var(:new_f, __MODULE__)
    bumped = quote do: Bitwise.band(unquote(var(:pc)) + 1, 0xFFFF)

    overrides =
      case dst do
        {:pair, :sp} -> %{sp: result}
        {:pair, :hl} -> loop_pair_overrides({:pair, :hl}, result)
      end
      |> Map.merge(%{f: f, pc: bumped})

    quote do
      unquote(imm) = mem_read(unquote(var(:rom)), unquote(var(:ram)), unquote(var(:pc)))

      {unquote(result), unquote(f)} =
        Atomboy.CPU.ALU.add_sp(unquote(var(:sp)), unquote(imm))

      unquote(loop_ret(overrides, var(:ram), cycles))
    end
  end

  # LDH et LD absolus de A.
  defp loop_body(%Insn{mnemonic: mnemonic, operands: [io, {:reg, :a}], cycles: cycles})
       when io in [:a8_ind, :c_ind, :a16_ind] and mnemonic in [:ld, :ldh] do
    {prelude, addr, pc_overrides} = loop_io(io)
    ram = quote do: ram_write(unquote(var(:ram)), unquote(addr), unquote(var(:a)))

    quote do
      unquote_splicing(prelude)
      unquote(loop_ret(pc_overrides, ram, cycles))
    end
  end

  defp loop_body(%Insn{mnemonic: mnemonic, operands: [{:reg, :a}, io], cycles: cycles})
       when io in [:a8_ind, :c_ind, :a16_ind] and mnemonic in [:ld, :ldh] do
    {prelude, addr, pc_overrides} = loop_io(io)
    value = Macro.var(:value, __MODULE__)

    quote do
      unquote_splicing(prelude)
      unquote(value) = mem_read(unquote(var(:rom)), unquote(var(:ram)), unquote(addr))
      unquote(loop_ret(Map.put(pc_overrides, :a, value), var(:ram), cycles))
    end
  end

  # ALU A, d8.
  defp loop_body(%Insn{mnemonic: :cp, operands: [{:reg, :a}, {:imm, 8}], cycles: cycles}) do
    imm = Macro.var(:imm, __MODULE__)
    f = Macro.var(:new_f, __MODULE__)
    bumped = quote do: Bitwise.band(unquote(var(:pc)) + 1, 0xFFFF)

    quote do
      unquote(imm) = mem_read(unquote(var(:rom)), unquote(var(:ram)), unquote(var(:pc)))
      unquote(f) = Atomboy.CPU.ALU.cp(unquote(var(:a)), unquote(imm))
      unquote(loop_ret(%{f: f, pc: bumped}, var(:ram), cycles))
    end
  end

  defp loop_body(%Insn{mnemonic: mnemonic, operands: [{:reg, :a}, {:imm, 8}], cycles: cycles})
       when mnemonic in [:add, :adc, :sub, :sbc, :and, :xor, :or] do
    imm = Macro.var(:imm, __MODULE__)
    result = Macro.var(:result, __MODULE__)
    f = Macro.var(:new_f, __MODULE__)
    bumped = quote do: Bitwise.band(unquote(var(:pc)) + 1, 0xFFFF)

    quote do
      unquote(imm) = mem_read(unquote(var(:rom)), unquote(var(:ram)), unquote(var(:pc)))

      {unquote(result), unquote(f)} =
        unquote(alu_call(mnemonic, var(:a), var(:f), imm))

      unquote(loop_ret(%{a: result, f: f, pc: bumped}, var(:ram), cycles))
    end
  end

  # JP HL.
  defp loop_body(%Insn{mnemonic: :jp, operands: [{:pair, :hl}], cycles: cycles}) do
    loop_ret(%{pc: loop_pair_read({:pair, :hl})}, var(:ram), cycles)
  end

  # JP a16 et ses formes conditionnelles.
  defp loop_body(%Insn{mnemonic: :jp, operands: [{:imm, 16}]} = insn) do
    target = Macro.var(:target, __MODULE__)
    taken = loop_ret(%{pc: target}, var(:ram), insn.cycles)

    body =
      conditional(insn, var(:f), taken, fn ->
        skipped = quote do: Bitwise.band(unquote(var(:pc)) + 2, 0xFFFF)
        loop_ret(%{pc: skipped}, var(:ram), insn.cycles_untaken)
      end)

    quote do
      unquote(target) = unquote(loop_read16_pc())
      unquote(body)
    end
  end

  # CALL a16.
  defp loop_body(%Insn{mnemonic: :call, operands: [{:imm, 16}]} = insn) do
    target = Macro.var(:target, __MODULE__)
    new_sp = Macro.var(:new_sp, __MODULE__)
    return_to = quote do: Bitwise.band(unquote(var(:pc)) + 2, 0xFFFF)

    taken =
      quote do
        unquote(new_sp) = Bitwise.band(unquote(var(:sp)) - 2, 0xFFFF)

        unquote(loop_ret(%{pc: target, sp: new_sp}, loop_push16(new_sp, return_to), insn.cycles))
      end

    body =
      conditional(insn, var(:f), taken, fn ->
        loop_ret(%{pc: return_to}, var(:ram), insn.cycles_untaken)
      end)

    quote do
      unquote(target) = unquote(loop_read16_pc())
      unquote(body)
    end
  end

  # RET, RET cc, RETI.
  defp loop_body(%Insn{mnemonic: mnemonic, operands: []} = insn)
       when mnemonic in [:ret, :reti] do
    value = Macro.var(:value, __MODULE__)
    lo = Macro.var(:lo, __MODULE__)
    hi = Macro.var(:hi, __MODULE__)
    bumped = quote do: Bitwise.band(unquote(var(:sp)) + 2, 0xFFFF)
    extra = if mnemonic == :reti, do: %{ime: 1}, else: %{}

    taken =
      quote do
        unquote(lo) = mem_read(unquote(var(:rom)), unquote(var(:ram)), unquote(var(:sp)))

        unquote(hi) =
          mem_read(
            unquote(var(:rom)),
            unquote(var(:ram)),
            Bitwise.band(unquote(var(:sp)) + 1, 0xFFFF)
          )

        unquote(value) = Bitwise.bsl(unquote(hi), 8) |> Bitwise.bor(unquote(lo))

        unquote(loop_ret(Map.merge(%{pc: value, sp: bumped}, extra), var(:ram), insn.cycles))
      end

    conditional(insn, var(:f), taken, fn ->
      loop_ret(%{}, var(:ram), insn.cycles_untaken)
    end)
  end

  # RST.
  defp loop_body(%Insn{mnemonic: :rst, operands: [{:rst, target}], cycles: cycles}) do
    new_sp = Macro.var(:new_sp, __MODULE__)

    quote do
      unquote(new_sp) = Bitwise.band(unquote(var(:sp)) - 2, 0xFFFF)
      unquote(loop_ret(%{pc: target, sp: new_sp}, loop_push16(new_sp, var(:pc)), cycles))
    end
  end

  # PUSH rr.
  defp loop_body(%Insn{mnemonic: :push, operands: [pair], cycles: cycles}) do
    new_sp = Macro.var(:new_sp, __MODULE__)
    value = Macro.var(:value, __MODULE__)

    ram =
      quote do
        ram_write(
          ram_write(unquote(var(:ram)), unquote(new_sp), Bitwise.band(unquote(value), 0xFF)),
          Bitwise.band(unquote(new_sp) + 1, 0xFFFF),
          Bitwise.bsr(unquote(value), 8)
        )
      end

    quote do
      unquote(value) = unquote(loop_pair_read(pair))
      unquote(new_sp) = Bitwise.band(unquote(var(:sp)) - 2, 0xFFFF)
      unquote(loop_ret(%{sp: new_sp}, ram, cycles))
    end
  end

  # POP rr.
  defp loop_body(%Insn{mnemonic: :pop, operands: [pair], cycles: cycles}) do
    value = Macro.var(:value, __MODULE__)
    lo = Macro.var(:lo, __MODULE__)
    hi = Macro.var(:hi, __MODULE__)
    bumped = quote do: Bitwise.band(unquote(var(:sp)) + 2, 0xFFFF)

    overrides =
      pop_overrides(pair, value, &loop_pair_overrides/2)
      |> Map.put(:sp, bumped)

    quote do
      unquote(lo) = mem_read(unquote(var(:rom)), unquote(var(:ram)), unquote(var(:sp)))

      unquote(hi) =
        mem_read(
          unquote(var(:rom)),
          unquote(var(:ram)),
          Bitwise.band(unquote(var(:sp)) + 1, 0xFFFF)
        )

      unquote(value) = Bitwise.bsl(unquote(hi), 8) |> Bitwise.bor(unquote(lo))
      unquote(loop_ret(overrides, var(:ram), cycles))
    end
  end

  # The accumulator operations (z=7).
  defp loop_body(%Insn{mnemonic: mnemonic, operands: [], cycles: cycles})
       when mnemonic in [:rlca, :rrca, :rla, :rra, :daa, :cpl, :scf, :ccf] do
    result = Macro.var(:result, __MODULE__)
    f = Macro.var(:new_f, __MODULE__)
    call = {{:., [], [Atomboy.CPU.ALU, mnemonic]}, [], [var(:a), var(:f)]}

    quote do
      {unquote(result), unquote(f)} = unquote(call)
      unquote(loop_ret(%{a: result, f: f}, var(:ram), cycles))
    end
  end

  # LD rr, d16 — two reads at PC, little-endian.
  defp loop_body(%Insn{mnemonic: :ld, operands: [{:pair, _} = dst, {:imm, 16}], cycles: cycles}) do
    imm = Macro.var(:imm, __MODULE__)
    lo = Macro.var(:lo, __MODULE__)
    hi = Macro.var(:hi, __MODULE__)
    bumped = quote do: Bitwise.band(unquote(var(:pc)) + 2, 0xFFFF)
    overrides = Map.merge(loop_pair_overrides(dst, imm), %{pc: bumped})

    quote do
      unquote(lo) = mem_read(unquote(var(:rom)), unquote(var(:ram)), unquote(var(:pc)))

      unquote(hi) =
        mem_read(
          unquote(var(:rom)),
          unquote(var(:ram)),
          Bitwise.band(unquote(var(:pc)) + 1, 0xFFFF)
        )

      unquote(imm) = Bitwise.bsl(unquote(hi), 8) |> Bitwise.bor(unquote(lo))
      unquote(loop_ret(overrides, var(:ram), cycles))
    end
  end

  # ADD HL, rr.
  defp loop_body(%Insn{mnemonic: :add, operands: [{:pair, :hl}, src], cycles: cycles}) do
    result = Macro.var(:result, __MODULE__)
    f = Macro.var(:new_f, __MODULE__)

    call =
      quote do:
              Atomboy.CPU.ALU.add16(
                unquote(loop_pair_read({:pair, :hl})),
                unquote(loop_pair_read(src)),
                unquote(var(:f))
              )

    overrides = Map.merge(loop_pair_overrides({:pair, :hl}, result), %{f: f})

    quote do
      {unquote(result), unquote(f)} = unquote(call)
      unquote(loop_ret(overrides, var(:ram), cycles))
    end
  end

  # INC rr / DEC rr — no flags.
  defp loop_body(%Insn{mnemonic: mnemonic, operands: [{:pair, _} = target], cycles: cycles})
       when mnemonic in [:inc, :dec] do
    result = Macro.var(:result, __MODULE__)
    delta = if mnemonic == :inc, do: 1, else: -1

    quote do
      unquote(result) = Bitwise.band(unquote(loop_pair_read(target)) + unquote(delta), 0xFFFF)
      unquote(loop_ret(loop_pair_overrides(target, result), var(:ram), cycles))
    end
  end

  # INC r / DEC r, the CB rotations, and their (HL) forms.
  defp loop_body(%Insn{mnemonic: mnemonic, operands: [target], cycles: cycles})
       when mnemonic in [:inc, :dec, :rlc, :rrc, :rl, :rr, :sla, :sra, :swap, :srl] do
    result = Macro.var(:result, __MODULE__)
    f = Macro.var(:new_f, __MODULE__)
    call = {{:., [], [Atomboy.CPU.ALU, mnemonic]}, [], [loop_read(target), var(:f)]}

    tail =
      case target do
        {:reg, name} ->
          loop_ret(%{name => result, f: f}, var(:ram), cycles)

        :hl_ind ->
          ram = quote do: ram_write(unquote(var(:ram)), unquote(hl()), unquote(result))
          loop_ret(%{f: f}, ram, cycles)
      end

    quote do
      {unquote(result), unquote(f)} = unquote(call)
      unquote(tail)
    end
  end

  defp loop_body(%Insn{mnemonic: :cp, operands: [{:reg, :a}, src], cycles: cycles}) do
    f = Macro.var(:new_f, __MODULE__)

    quote do
      unquote(f) = Atomboy.CPU.ALU.cp(unquote(var(:a)), unquote(loop_read(src)))
      unquote(loop_ret(%{f: f}, var(:ram), cycles))
    end
  end

  defp loop_body(%Insn{mnemonic: mnemonic, operands: [{:reg, :a}, src], cycles: cycles})
       when mnemonic in [:add, :adc, :sub, :sbc, :and, :xor, :or] do
    result = Macro.var(:result, __MODULE__)
    f = Macro.var(:new_f, __MODULE__)

    quote do
      {unquote(result), unquote(f)} =
        unquote(alu_call(mnemonic, var(:a), var(:f), loop_read(src)))

      unquote(loop_ret(%{a: result, f: f}, var(:ram), cycles))
    end
  end

  defp loop_read(:hl_ind) do
    quote do: mem_read(unquote(var(:rom)), unquote(var(:ram)), unquote(hl()))
  end

  defp loop_read({:reg, name}), do: var(name)

  # An I/O operand's address, loop side — same contract as struct_io/1.
  defp loop_io(:c_ind) do
    {[], quote(do: Bitwise.bor(0xFF00, unquote(var(:c)))), %{}}
  end

  defp loop_io(:a8_ind) do
    imm = Macro.var(:imm, __MODULE__)

    prelude =
      quote do:
              unquote(imm) =
                mem_read(unquote(var(:rom)), unquote(var(:ram)), unquote(var(:pc)))

    bumped = quote do: Bitwise.band(unquote(var(:pc)) + 1, 0xFFFF)
    {[prelude], quote(do: Bitwise.bor(0xFF00, unquote(imm))), %{pc: bumped}}
  end

  defp loop_io(:a16_ind) do
    addr = Macro.var(:addr, __MODULE__)
    prelude = quote do: unquote(addr) = unquote(loop_read16_pc())
    bumped = quote do: Bitwise.band(unquote(var(:pc)) + 2, 0xFFFF)
    {[prelude], addr, %{pc: bumped}}
  end

  # The little-endian word at PC, loop side.
  defp loop_read16_pc do
    quote do
      Bitwise.bsl(
        mem_read(
          unquote(var(:rom)),
          unquote(var(:ram)),
          Bitwise.band(unquote(var(:pc)) + 1, 0xFFFF)
        ),
        8
      )
      |> Bitwise.bor(mem_read(unquote(var(:rom)), unquote(var(:ram)), unquote(var(:pc))))
    end
  end

  # Writing a word onto the stack, little-endian, loop side.
  defp loop_push16(sp_expr, value_expr) do
    quote do
      ram_write(
        ram_write(unquote(var(:ram)), unquote(sp_expr), Bitwise.band(unquote(value_expr), 0xFF)),
        Bitwise.band(unquote(sp_expr) + 1, 0xFFFF),
        Bitwise.bsr(unquote(value_expr), 8)
      )
    end
  end

  defp loop_pair_read({:pair, :sp}), do: var(:sp)

  defp loop_pair_read({:pair, name}) do
    {hi, lo} = pair_regs(name)
    quote do: Bitwise.bsl(unquote(var(hi)), 8) |> Bitwise.bor(unquote(var(lo)))
  end

  defp loop_pair_overrides({:pair, :sp}, value), do: %{sp: value}

  defp loop_pair_overrides({:pair, name}, value) do
    {hi, lo} = pair_regs(name)

    %{
      hi => quote(do: Bitwise.bsr(unquote(value), 8)),
      lo => quote(do: Bitwise.band(unquote(value), 0xFF))
    }
  end

  defp hl do
    quote do: Bitwise.bsl(unquote(var(:h)), 8) |> Bitwise.bor(unquote(var(:l)))
  end

  # The tail call to the next fetch: every register leaves as an argument, with
  # those in `overrides` replaced by their new value.
  defp loop_ret(overrides, ram_expr, cycles) do
    regs = Enum.map(@state ++ @loop_extra, fn name -> Map.get(overrides, name, var(name)) end)
    counted = quote do: unquote(var(:cycles)) + unquote(cycles)
    args = [var(:rom), ram_expr, var(:budget), counted] ++ regs

    quote do: fetch(unquote_splicing(args))
  end

  # The clause head: opcode excluded (it is a literal at the call site), variables
  # the body does not read prefixed with an underscore. Computed from the AST so
  # that future families inherit it without anyone having to think about it.
  defp loop_args(body) do
    used = read_vars(body)

    Enum.map([:rom, :ram, :budget, :cycles] ++ @state ++ @loop_extra, fn name ->
      if MapSet.member?(used, name), do: var(name), else: var(:"_#{name}")
    end)
  end

  # The variables referenced anywhere in an AST. A variable is a triple whose
  # third element is an atom (the context).
  defp read_vars(ast) do
    {_ast, vars} =
      Macro.prewalk(ast, MapSet.new(), fn
        {name, _meta, context} = node, acc when is_atom(name) and is_atom(context) ->
          {node, MapSet.put(acc, name)}

        node, acc ->
          {node, acc}
      end)

    vars
  end

  # ══ Tree dispatch ════════════════════════════════════════════════════════════
  #
  # AtomVM's JIT compiles a `select_val` into a linear scan — one C comparison
  # function call per entry. Across 245 flat clauses, the dispatch cost is
  # proportional to the opcode's position: measured at ×10.6 between a program of
  # NOPs (first entry) and a program of OR A (~180th).
  #
  # Hence the two-level tree: `case opcode >>> 4` then `case opcode &&& 15`. Two
  # selects of at most 16 entries — worst case ~32 comparisons instead of 245, on
  # average ~17 instead of ~120. The day the JIT can emit a jump table, going back
  # to flat clauses here is all it takes.

  @doc """
  The body of a fast-loop `exec`: the complete dispatch tree over the given
  instructions, plus the extra entries (the CB prefix), with `fallback` as the
  default branch.
  """
  @spec loop_dispatch([Insn.t()], [{0..0xFF, Macro.t()}], Macro.t()) :: Macro.t()
  def loop_dispatch(insns, extra_entries, fallback) do
    entries = Enum.map(insns, fn insn -> {insn.opcode, loop_body(insn)} end) ++ extra_entries
    dispatch_tree(entries, fallback)
  end

  @doc "The struct backend's counterpart to `loop_dispatch/3`."
  @spec struct_dispatch([Insn.t()], [{0..0xFF, Macro.t()}], Macro.t()) :: Macro.t()
  def struct_dispatch(insns, extra_entries, fallback) do
    entries = Enum.map(insns, fn insn -> {insn.opcode, struct_body(insn)} end) ++ extra_entries
    dispatch_tree(entries, fallback)
  end

  @doc "A fast loop's 0xCB entry: second fetch, dispatch into exec_cb."
  @spec loop_cb_entry() :: {0xCB, Macro.t()}
  def loop_cb_entry do
    first = quote do: mem_read(unquote(var(:rom)), unquote(var(:ram)), unquote(var(:pc)))
    bumped = quote do: Bitwise.band(unquote(var(:pc)) + 1, 0xFFFF)

    rest =
      [var(:rom), var(:ram), var(:budget), var(:cycles)] ++
        Enum.map([:a, :f, :b, :c, :d, :e, :h, :l, :sp], &var/1) ++
        [bumped | Enum.map(@loop_extra, &var/1)]

    {0xCB, quote(do: exec_cb(unquote_splicing([first | rest])))}
  end

  @doc "The struct backend's 0xCB entry."
  @spec struct_cb_entry() :: {0xCB, Macro.t()}
  def struct_cb_entry do
    body =
      quote do
        exec_cb(
          mem_read_pc(unquote(var(:mem)), unquote(var(:st))),
          %{unquote(var(:st)) | pc: Bitwise.band(unquote(field(:pc)) + 1, 0xFFFF)},
          unquote(var(:mem))
        )
      end

    {0xCB, body}
  end

  @doc """
  The default branch: a call to a local helper in the host module, not an inline
  `raise` — the fallback appears at every leaf of the tree, and 245 copies of the
  exception construction per table dilute the hot code in the instruction cache.
  The host module defines `unimplemented_base/1` and `unimplemented_cb/1`.
  """
  @spec unimplemented(atom()) :: Macro.t()
  def unimplemented(helper) when is_atom(helper) do
    quote do: unquote(helper)(unquote(var(:opcode)))
  end

  @doc """
  The loops' located fallback: the opcode, but also PC and the memory map — enough
  to tell *where* the processor got lost, not only on what.
  """
  @spec unimplemented_at(atom()) :: Macro.t()
  def unimplemented_at(helper) when is_atom(helper) do
    quote do: unquote(helper)(unquote(var(:opcode)), unquote(var(:pc)), unquote(var(:ram)))
  end

  @doc "An `exec`'s head arguments — opcode included, nil context throughout."
  @spec head_args(:loop | :struct) :: [Macro.t()]
  def head_args(:loop) do
    Enum.map([:opcode, :rom, :ram, :budget, :cycles] ++ @state ++ @loop_extra, &var/1)
  end

  def head_args(:struct), do: [var(:opcode), var(:st), var(:mem)]

  # Binary search in pure `if <` — depth log2(n), integer comparisons that the JIT
  # compiles into inline tests. The first version, in nested `case` (16×16),
  # compiled correctly on the BEAM but was mistranslated by the native JIT: an
  # implemented opcode fell through to the fallback. Selects are therefore banned
  # from the dispatch, not merely shortened.
  defp dispatch_tree(entries, fallback) do
    entries
    |> Enum.sort_by(fn {opcode, _body} -> opcode end)
    |> search_tree(fallback)
  end

  # The leaf keeps its equality test: the table's holes — the eleven invalid
  # encodings — have to fall through to the fallback.
  defp search_tree([{opcode, body}], fallback) do
    quote do
      if unquote(var(:opcode)) === unquote(opcode) do
        unquote(body)
      else
        unquote(fallback)
      end
    end
  end

  defp search_tree(entries, fallback) do
    {left, right} = Enum.split(entries, div(length(entries), 2))
    [{pivot, _body} | _rest] = right

    quote do
      if unquote(var(:opcode)) < unquote(pivot) do
        unquote(search_tree(left, fallback))
      else
        unquote(search_tree(right, fallback))
      end
    end
  end

  # ══ Shared ═══════════════════════════════════════════════════════════════════

  # The halves of a 16-bit pair. SP does not appear: it already lives in a single
  # field. AF exists only for the stack.
  defp pair_regs(:bc), do: {:b, :c}
  defp pair_regs(:de), do: {:d, :e}
  defp pair_regs(:hl), do: {:h, :l}
  defp pair_regs(:af), do: {:a, :f}

  # A POP's overrides. Identical to the ordinary pair overrides, except for AF:
  # **F's four low bits do not physically exist** — whatever byte gets popped, they
  # read as zero. Forgetting this mask lets phantom bits into F, which every
  # subsequent flag computation then drags along.
  defp pop_overrides({:pair, :af}, value, overrides_fun) do
    overrides_fun.({:pair, :af}, value)
    |> Map.put(:f, quote(do: Bitwise.band(unquote(value), 0xF0)))
  end

  defp pop_overrides(pair, value, overrides_fun), do: overrides_fun.(pair, value)

  # The pair that carries an indirect operand's address.
  defp ind_pair(:bc), do: {:pair, :bc}
  defp ind_pair(:de), do: {:pair, :de}
  defp ind_pair(_hl), do: {:pair, :hl}

  # The state overrides for HL's post-adjustment — empty for BC and DE.
  # `overrides_fun` is the calling backend's override factory.
  defp ind_overrides(:hl_inc, addr, overrides_fun) do
    overrides_fun.({:pair, :hl}, quote(do: Bitwise.band(unquote(addr) + 1, 0xFFFF)))
  end

  defp ind_overrides(:hl_dec, addr, overrides_fun) do
    overrides_fun.({:pair, :hl}, quote(do: Bitwise.band(unquote(addr) - 1, 0xFFFF)))
  end

  defp ind_overrides(_other, _addr, _overrides_fun), do: %{}

  # The test of a branch condition against an F expression.
  defp condition_expr(:nz, f), do: quote(do: Bitwise.band(unquote(f), 0x80) == 0)
  defp condition_expr(:z, f), do: quote(do: Bitwise.band(unquote(f), 0x80) != 0)
  defp condition_expr(:nc, f), do: quote(do: Bitwise.band(unquote(f), 0x10) == 0)
  defp condition_expr(:c, f), do: quote(do: Bitwise.band(unquote(f), 0x10) != 0)

  # Wraps a body in the instruction's condition test — or does not, for the
  # unconditional forms. `untaken_fun` is lazy: the untaken branch does not exist
  # for those. `f_expr` comes from the calling backend: `field(:f)` on the struct
  # side, `var(:f)` on the loop side.
  defp conditional(%Insn{condition: nil}, _f_expr, taken, _untaken_fun), do: taken

  defp conditional(%Insn{condition: condition}, f_expr, taken, untaken_fun) do
    quote do
      if unquote(condition_expr(condition, f_expr)) do
        unquote(taken)
      else
        unquote(untaken_fun.())
      end
    end
  end

  # A mnemonic's ALU call. `adc` and `sbc` consume the incoming F, the others do
  # not; `and`/`or`/`xor` go by other names on the primitive side because they are
  # Elixir operators.
  defp alu_call(mnemonic, a_expr, f_expr, value_expr) do
    {name, args} =
      case mnemonic do
        :adc -> {:adc, [a_expr, f_expr, value_expr]}
        :sbc -> {:sbc, [a_expr, f_expr, value_expr]}
        :and -> {:bit_and, [a_expr, value_expr]}
        :xor -> {:bit_xor, [a_expr, value_expr]}
        :or -> {:bit_or, [a_expr, value_expr]}
        other -> {other, [a_expr, value_expr]}
      end

    {{:., [], [Atomboy.CPU.ALU, name]}, [], args}
  end
end
