defmodule Atomboy.CPU.Gen do
  @moduledoc """
  Traduit un `Atomboy.CPU.Insn` en code, à la compilation — vers deux backends.

  C'est la seule couche qui connaît les conventions d'appel. `Atomboy.CPU.Table`
  décrit *quoi*, ce module décide *comment* — et il le décide deux fois :

    * **`clause/1` — le backend struct.** `exec(opcode, %State{}, mem)` renvoie
      `{state, mem, cycles}`. Une allocation par instruction, un état
      observable après chacune : c'est l'oracle. Les vecteurs SM83 le valident,
      le débogage s'y fait, et la phase 5 comparera le code recompilé à lui.

    * **`loop_clause/1` — la boucle rapide.** Les registres voyagent en
      arguments de fonction, chaque clause finit par un appel terminal vers le
      fetch suivant, et rien n'est construit tant que le budget de cycles
      n'est pas épuisé. Dans du code natif AOT, ces arguments deviennent des
      registres machine.

  Pourquoi deux backends plutôt qu'un : la mesure. Sur AtomVM natif, la boucle
  à struct plafonne à ×1,21 de l'interprété — loi d'Amdahl, tout le temps part
  dans les BIFs de map que le natif ne compile pas. La sonde sans maps a donné
  ×43. Le confort du struct reste là où on lit l'état ; la vitesse là où on ne
  lit rien.

  La sémantique, elle, n'est écrite qu'une fois : les deux émetteurs partagent
  la même table et les mêmes primitives `Atomboy.CPU.ALU`. Un test
  d'équivalence croisée verrouille le reste.
  """

  alias Atomboy.CPU.Insn

  @state [:a, :f, :b, :c, :d, :e, :h, :l, :sp, :pc]

  # L'état non-registre que la boucle rapide transporte en plus : IME (RETI,
  # EI, DI) et halted (HALT). Étendre cette liste étend la boucle — têtes de
  # clauses, appels terminaux et matérialisation suivent.
  @loop_extra [:ime, :halted, :ime_pending]

  @doc "Les registres qui composent l'état, dans l'ordre des arguments."
  @spec state_names() :: [atom()]
  def state_names, do: @state

  @doc """
  Une variable non hygiénique.

  Le contexte `nil` est indispensable : ces variables sont construites ici mais
  doivent se lier à celles de la tête de fonction chez l'appelant. Avec le
  contexte par défaut elles appartiendraient à ce module et ne matcheraient rien.
  """
  @spec var(atom()) :: Macro.t()
  def var(name), do: Macro.var(name, nil)

  # ══ Backend struct ═══════════════════════════════════════════════════════════

  @doc """
  La clause de `exec/3` (backend struct) pour une instruction.

  Renvoie `{arguments, corps}`, à injecter par `unquote_splicing/1` et
  `unquote/1` dans un `def` chez l'appelant.
  """
  @spec clause(Insn.t()) :: {[Macro.t()], Macro.t()}
  def clause(%Insn{} = insn), do: {[var(:st), var(:mem)], struct_body(insn)}

  defp struct_body(%Insn{mnemonic: :nop, cycles: cycles}) do
    struct_ret(var(:st), var(:mem), cycles)
  end

  # LD r, d8 et LD (HL), d8 — l'immédiat se lit à PC, qui avance d'un cran de
  # plus. L'immédiat est lié à une variable avant l'appel : la lecture doit
  # précéder toute écriture mémoire, et un PC déjà avancé ne doit pas resservir
  # à la lecture.
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

  # STOP — un octet et rien d'autre dans le modèle du corpus ; voir la table.
  defp struct_body(%Insn{mnemonic: :stop, cycles: cycles}) do
    struct_ret(var(:st), var(:mem), cycles)
  end

  # JR — offset signé d'un octet, relatif au PC qui suit l'opérande. Le calcul
  # du signe est sans branche : retrancher 256 quand le bit 7 est levé.
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

  # LD (a16), SP — l'unique écriture 16 bits directe.
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

  # LD (BC/DE/HL±), A — écriture de A à l'adresse d'une paire, avec
  # post-ajustement de HL pour les deux dernières formes.
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

  # LD (HL), r — la mémoire change, l'état non : `st` repart tel quel.
  defp struct_body(%Insn{mnemonic: :ld, operands: [:hl_ind, src], cycles: cycles}) do
    write = quote do: mem_write(unquote(var(:mem)), unquote(var(:st)), unquote(struct_read(src)))
    struct_ret(var(:st), write, cycles)
  end

  # LD r, r' et LD r, (HL) — un seul champ change. La garde écarte les
  # opérandes d'E/S, qui ont leurs propres clauses : sans elle, l'ordre des
  # clauses déciderait silencieusement.
  defp struct_body(%Insn{mnemonic: :ld, operands: [{:reg, dst}, src], cycles: cycles})
       when is_tuple(src) or src == :hl_ind do
    struct_ret(struct_update(%{dst => struct_read(src)}), var(:mem), cycles)
  end

  # JP HL — aucun accès mémoire malgré la notation « JP (HL) » : PC reçoit la
  # paire. Le saut calculé du futur trampoline de phase 5.
  defp struct_body(%Insn{mnemonic: :jp, operands: [{:pair, :hl}], cycles: cycles}) do
    struct_ret(struct_update(%{pc: struct_pair_read({:pair, :hl})}), var(:mem), cycles)
  end

  # JP a16 et ses formes conditionnelles.
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

  # CALL a16 — l'adresse de retour (PC après l'opérande) part sur la pile.
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

  # RET, RET cc, RETI — la lecture de pile n'a lieu que si le retour se fait,
  # et RETI rallume IME dans le même souffle.
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

  # RST — un CALL vers une cible fixe encodée dans l'opcode.
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

  # PUSH rr — SP descend de deux, la paire s'écrit little-endian au nouveau SP.
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

  # POP rr — lecture au SP courant, SP remonte de deux. Voir pop_overrides/3
  # pour le masque de POP AF.
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

  # Les opérations sur l'accumulateur (z=7) — signature uniforme (a, f) → {a, f}
  # côté ALU, donc une seule clause pour les huit.
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

  # LD rr, d16 — le mot immédiat, little-endian, PC avance de deux.
  defp struct_body(%Insn{mnemonic: :ld, operands: [{:pair, _} = dst, {:imm, 16}], cycles: cycles}) do
    imm = Macro.var(:imm, __MODULE__)
    bumped = quote do: Bitwise.band(unquote(field(:pc)) + 2, 0xFFFF)
    overrides = Map.merge(struct_pair_overrides(dst, imm), %{pc: bumped})

    quote do
      unquote(imm) = mem_read_pc16(unquote(var(:mem)), unquote(var(:st)))
      unquote(struct_ret(struct_update(overrides), var(:mem), cycles))
    end
  end

  # ADD HL, rr — l'unique addition 16 bits ; Z préservé, voir ALU.add16/3.
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

  # INC rr / DEC rr — arithmétique 16 bits pure, aucun drapeau.
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

  # INC r / DEC r et les huit rotations/décalages CB — même forme :
  # (valeur, F) → {valeur, F}, la primitive porte toute la sémantique.
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

  # INC (HL) / DEC (HL) et rotations (HL) — lu-modifié-écrit : la valeur passe
  # par la mémoire dans les deux sens, seul F change dans l'état.
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

  # DI / EI / HALT — un seul champ de contrôle chacun.
  # BIT n — lecture seule, F seul change ; C traverse.
  defp struct_body(%Insn{mnemonic: :bit, operands: [{:bit, n}, target], cycles: cycles}) do
    f = Macro.var(:new_f, __MODULE__)

    quote do
      unquote(f) =
        Atomboy.CPU.ALU.bit_test(unquote(n), unquote(struct_read(target)), unquote(field(:f)))

      unquote(struct_ret(struct_update(%{f: f}), var(:mem), cycles))
    end
  end

  # RES n / SET n — bit effacé ou posé, aucun drapeau. L'arithmétique est
  # inline : il n'y a aucune subtilité à centraliser.
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

  # DI coupe tout, l'armement différé d'un EI précédent compris.
  defp struct_body(%Insn{mnemonic: :di, cycles: cycles}),
    do: struct_ret(struct_update(%{ime: 0, ime_pending: 0}), var(:mem), cycles)

  # EI n'autorise pas : il arme. La promotion se fait au pas suivant, dans
  # step/2 côté oracle et dans fetch côté boucle — même point dans les deux.
  defp struct_body(%Insn{mnemonic: :ei, cycles: cycles}),
    do: struct_ret(struct_update(%{ime_pending: 1}), var(:mem), cycles)

  defp struct_body(%Insn{mnemonic: :halt, cycles: cycles}),
    do: struct_ret(struct_update(%{halted: true}), var(:mem), cycles)

  # LD SP, HL.
  defp struct_body(%Insn{mnemonic: :ld, operands: [{:pair, :sp}, {:pair, :hl}], cycles: cycles}) do
    struct_ret(struct_update(%{sp: struct_pair_read({:pair, :hl})}), var(:mem), cycles)
  end

  # ADD SP, r8 et LD HL, SP+r8 — même arithmétique, destination différente.
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

  # LDH et LD absolus de A — la page haute (0xFF00 + a8 ou + C) et l'adresse
  # 16 bits directe partagent la même mécanique, seule l'adresse change.
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

  # ALU A, d8 — l'immédiat comme source.
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

  # ALU — l'arithmétique vit dans Atomboy.CPU.ALU, au niveau valeurs. Ici on ne
  # fait qu'envelopper le résultat dans la mise à jour de structure.
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

  # L'adresse d'un opérande d'E/S : `{prélude, expression d'adresse,
  # surcharges de PC}`. Le prélude lit l'éventuel immédiat.
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

  # Les surcharges d'état qui écrivent `value` — une expression déjà liée à
  # une variable, jamais réévaluée — dans une paire.
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

  # `%{st | champ: valeur, ...}` — une seule mise à jour, tous champs groupés.
  # Sans surcharge, `st` repart tel quel : aucune allocation.
  defp struct_update(fields) when map_size(fields) == 0, do: var(:st)

  defp struct_update(fields) do
    {:%{}, [], [{:|, [], [var(:st), Enum.to_list(fields)]}]}
  end

  defp struct_ret(state_expr, mem_expr, cycles) do
    {:{}, [], [state_expr, mem_expr, cycles]}
  end

  # ══ Backend boucle rapide ════════════════════════════════════════════════════

  @doc """
  La clause de `exec/15` de `Atomboy.CPU.Loop` pour une instruction.

  La tête reçoit `(opcode, rom, ram, budget, cycles, a, f, b, c, d, e, h, l,
  sp, pc)` ; le corps se termine par un appel terminal vers `fetch/14` avec les
  registres mis à jour. Les variables que le corps ne lit pas sont soulignées
  dans la tête — `LD B, C` écrase `b` sans le lire, et sur des centaines de
  clauses générées, les avertissements parasites noieraient ceux qui comptent.
  """
  @spec loop_clause(Insn.t()) :: {[Macro.t()], Macro.t()}
  def loop_clause(%Insn{} = insn) do
    body = loop_body(insn)
    {loop_args(body), body}
  end

  defp loop_body(%Insn{mnemonic: :nop, cycles: cycles}) do
    loop_ret(%{}, var(:ram), cycles)
  end

  # STOP — voir le backend struct.
  defp loop_body(%Insn{mnemonic: :stop, cycles: cycles}) do
    loop_ret(%{}, var(:ram), cycles)
  end

  # JR — voir le commentaire du backend struct pour le calcul du signe.
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

  # LD (a16), SP — deux écritures chaînées, little-endian.
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

  # LD r, d8 / LD (HL), d8 — même logique que côté struct : lire l'immédiat à
  # PC, puis repartir avec PC avancé d'un cran de plus.
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

  # Même garde que la clause struct équivalente : les opérandes d'E/S ont
  # leurs propres clauses.
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

  # Les opérations sur l'accumulateur (z=7).
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

  # LD rr, d16 — deux lectures à PC, little-endian.
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

  # INC rr / DEC rr — aucun drapeau.
  defp loop_body(%Insn{mnemonic: mnemonic, operands: [{:pair, _} = target], cycles: cycles})
       when mnemonic in [:inc, :dec] do
    result = Macro.var(:result, __MODULE__)
    delta = if mnemonic == :inc, do: 1, else: -1

    quote do
      unquote(result) = Bitwise.band(unquote(loop_pair_read(target)) + unquote(delta), 0xFFFF)
      unquote(loop_ret(loop_pair_overrides(target, result), var(:ram), cycles))
    end
  end

  # INC r / DEC r, rotations CB, et leurs formes (HL).
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

  # L'adresse d'un opérande d'E/S, côté boucle — même contrat que struct_io/1.
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

  # Le mot little-endian à PC, côté boucle.
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

  # L'écriture d'un mot sur la pile, little-endian, côté boucle.
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

  # L'appel terminal vers le fetch suivant : tous les registres repartent en
  # arguments, ceux d'`overrides` remplacés par leur nouvelle valeur.
  defp loop_ret(overrides, ram_expr, cycles) do
    regs = Enum.map(@state ++ @loop_extra, fn name -> Map.get(overrides, name, var(name)) end)
    counted = quote do: unquote(var(:cycles)) + unquote(cycles)
    args = [var(:rom), ram_expr, var(:budget), counted] ++ regs

    quote do: fetch(unquote_splicing(args))
  end

  # La tête de clause : opcode exclu (littéral chez l'appelant), variables non
  # lues par le corps préfixées d'un souligné. Calculé sur l'AST pour que les
  # familles à venir en héritent sans y penser.
  defp loop_args(body) do
    used = read_vars(body)

    Enum.map([:rom, :ram, :budget, :cycles] ++ @state ++ @loop_extra, fn name ->
      if MapSet.member?(used, name), do: var(name), else: var(:"_#{name}")
    end)
  end

  # Les variables référencées quelque part dans un AST. Une variable est un
  # triplet dont le troisième élément est un atome (le contexte).
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

  # ══ Dispatch arborescent ═════════════════════════════════════════════════════
  #
  # Le JIT d'AtomVM compile un `select_val` en balayage linéaire — un appel de
  # fonction C de comparaison par entrée. Sur 245 clauses plates, le coût du
  # dispatch est proportionnel à la position de l'opcode : mesuré ×10,6 entre
  # un programme de NOP (première entrée) et un programme d'OR A (~180e).
  #
  # D'où l'arbre à deux étages : `case opcode >>> 4` puis `case opcode &&& 15`.
  # Deux selects de 16 entrées au plus — pire cas ~32 comparaisons au lieu de
  # 245, moyenne ~17 au lieu de ~120. Le jour où le JIT saura émettre une table
  # de saut, il suffira de revenir aux clauses plates ici.

  @doc """
  Le corps d'un `exec` de boucle rapide : l'arbre de dispatch complet sur les
  instructions données, plus les entrées supplémentaires (le préfixe CB), avec
  `fallback` comme branche par défaut.
  """
  @spec loop_dispatch([Insn.t()], [{0..0xFF, Macro.t()}], Macro.t()) :: Macro.t()
  def loop_dispatch(insns, extra_entries, fallback) do
    entries = Enum.map(insns, fn insn -> {insn.opcode, loop_body(insn)} end) ++ extra_entries
    dispatch_tree(entries, fallback)
  end

  @doc "Le pendant backend struct de `loop_dispatch/3`."
  @spec struct_dispatch([Insn.t()], [{0..0xFF, Macro.t()}], Macro.t()) :: Macro.t()
  def struct_dispatch(insns, extra_entries, fallback) do
    entries = Enum.map(insns, fn insn -> {insn.opcode, struct_body(insn)} end) ++ extra_entries
    dispatch_tree(entries, fallback)
  end

  @doc "L'entrée 0xCB d'une boucle rapide : second fetch, dispatch vers exec_cb."
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

  @doc "L'entrée 0xCB du backend struct."
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
  La branche par défaut : un appel vers un helper local du module hôte, pas un
  `raise` inline — le fallback apparaît à chaque feuille de l'arbre, et 245
  copies de la construction d'exception par table diluent le code chaud dans
  le cache d'instructions. Le module hôte définit `unimplemented_base/1` et
  `unimplemented_cb/1`.
  """
  @spec unimplemented(atom()) :: Macro.t()
  def unimplemented(helper) when is_atom(helper) do
    quote do: unquote(helper)(unquote(var(:opcode)))
  end

  @doc """
  Le repli situé des boucles : l'opcode, mais aussi PC et la map mémoire —
  de quoi raconter *où* le processeur s'est perdu, pas seulement sur quoi.
  """
  @spec unimplemented_at(atom()) :: Macro.t()
  def unimplemented_at(helper) when is_atom(helper) do
    quote do: unquote(helper)(unquote(var(:opcode)), unquote(var(:pc)), unquote(var(:ram)))
  end

  @doc "Les arguments de tête d'un `exec` — opcode inclus, contexte nil partout."
  @spec head_args(:loop | :struct) :: [Macro.t()]
  def head_args(:loop) do
    Enum.map([:opcode, :rom, :ram, :budget, :cycles] ++ @state ++ @loop_extra, &var/1)
  end

  def head_args(:struct), do: [var(:opcode), var(:st), var(:mem)]

  # Recherche binaire en `if <` purs — profondeur log2(n), comparaisons
  # entières que le JIT compile en tests inline. La première version en `case`
  # imbriqués (16×16) compilait juste sur BEAM mais était mal traduite par le
  # JIT natif : un opcode implémenté tombait dans le fallback. Les selects sont
  # donc bannis du dispatch, pas seulement raccourcis.
  defp dispatch_tree(entries, fallback) do
    entries
    |> Enum.sort_by(fn {opcode, _body} -> opcode end)
    |> search_tree(fallback)
  end

  # La feuille garde son test d'égalité : les trous de la table — les onze
  # encodages invalides — doivent tomber dans le fallback.
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

  # ══ Commun ═══════════════════════════════════════════════════════════════════

  # Les moitiés d'une paire 16 bits. SP n'y figure pas : il vit déjà en un
  # seul champ. AF n'existe que pour la pile.
  defp pair_regs(:bc), do: {:b, :c}
  defp pair_regs(:de), do: {:d, :e}
  defp pair_regs(:hl), do: {:h, :l}
  defp pair_regs(:af), do: {:a, :f}

  # Les surcharges d'un POP. Identiques aux surcharges de paire ordinaires,
  # sauf pour AF : **les quatre bits bas de F n'existent pas physiquement** —
  # quel que soit l'octet dépopé, ils lisent zéro. Oublier ce masque laisse
  # entrer des bits fantômes dans F, que tous les calculs de drapeaux suivants
  # traînent ensuite.
  defp pop_overrides({:pair, :af}, value, overrides_fun) do
    overrides_fun.({:pair, :af}, value)
    |> Map.put(:f, quote(do: Bitwise.band(unquote(value), 0xF0)))
  end

  defp pop_overrides(pair, value, overrides_fun), do: overrides_fun.(pair, value)

  # La paire qui porte l'adresse d'un opérande indirect.
  defp ind_pair(:bc), do: {:pair, :bc}
  defp ind_pair(:de), do: {:pair, :de}
  defp ind_pair(_hl), do: {:pair, :hl}

  # Les surcharges d'état du post-ajustement de HL — vides pour BC et DE.
  # `overrides_fun` est la fabrique de surcharges du backend appelant.
  defp ind_overrides(:hl_inc, addr, overrides_fun) do
    overrides_fun.({:pair, :hl}, quote(do: Bitwise.band(unquote(addr) + 1, 0xFFFF)))
  end

  defp ind_overrides(:hl_dec, addr, overrides_fun) do
    overrides_fun.({:pair, :hl}, quote(do: Bitwise.band(unquote(addr) - 1, 0xFFFF)))
  end

  defp ind_overrides(_other, _addr, _overrides_fun), do: %{}

  # Le test d'une condition de branchement sur une expression de F.
  defp condition_expr(:nz, f), do: quote(do: Bitwise.band(unquote(f), 0x80) == 0)
  defp condition_expr(:z, f), do: quote(do: Bitwise.band(unquote(f), 0x80) != 0)
  defp condition_expr(:nc, f), do: quote(do: Bitwise.band(unquote(f), 0x10) == 0)
  defp condition_expr(:c, f), do: quote(do: Bitwise.band(unquote(f), 0x10) != 0)

  # Enveloppe un corps dans le test de condition de l'instruction — ou pas,
  # pour les formes inconditionnelles. `untaken_fun` est paresseux : la branche
  # non prise n'existe pas pour elles. `f_expr` vient du backend appelant :
  # `field(:f)` côté struct, `var(:f)` côté boucle.
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

  # L'appel ALU d'un mnémonique. `adc` et `sbc` consomment F entrant, les
  # autres non ; `and`/`or`/`xor` portent d'autres noms côté primitives parce
  # que ce sont des opérateurs d'Elixir.
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
