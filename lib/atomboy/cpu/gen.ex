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

  # LD (HL), r — la mémoire change, l'état non : `st` repart tel quel.
  defp struct_body(%Insn{mnemonic: :ld, operands: [:hl_ind, src], cycles: cycles}) do
    write = quote do: mem_write(unquote(var(:mem)), unquote(var(:st)), unquote(struct_read(src)))
    struct_ret(var(:st), write, cycles)
  end

  # LD r, r' et LD r, (HL) — un seul champ change.
  defp struct_body(%Insn{mnemonic: :ld, operands: [{:reg, dst}, src], cycles: cycles}) do
    struct_ret(struct_update(%{dst => struct_read(src)}), var(:mem), cycles)
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

  # `st.<name>`
  defp field(name), do: {{:., [], [var(:st), name]}, [no_parens: true], []}

  # `%{st | champ: valeur, ...}` — une seule mise à jour, tous champs groupés.
  defp struct_update(fields) when map_size(fields) > 0 do
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

  defp loop_body(%Insn{mnemonic: :ld, operands: [{:reg, dst}, src], cycles: cycles}) do
    loop_ret(%{dst => loop_read(src)}, var(:ram), cycles)
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

  defp hl do
    quote do: Bitwise.bsl(unquote(var(:h)), 8) |> Bitwise.bor(unquote(var(:l)))
  end

  # L'appel terminal vers le fetch suivant : tous les registres repartent en
  # arguments, ceux d'`overrides` remplacés par leur nouvelle valeur.
  defp loop_ret(overrides, ram_expr, cycles) do
    regs = Enum.map(@state, fn name -> Map.get(overrides, name, var(name)) end)
    counted = quote do: unquote(var(:cycles)) + unquote(cycles)
    args = [var(:rom), ram_expr, var(:budget), counted] ++ regs

    quote do: fetch(unquote_splicing(args))
  end

  # La tête de clause : opcode exclu (littéral chez l'appelant), variables non
  # lues par le corps préfixées d'un souligné. Calculé sur l'AST pour que les
  # familles à venir en héritent sans y penser.
  defp loop_args(body) do
    used = read_vars(body)

    Enum.map([:rom, :ram, :budget, :cycles] ++ @state, fn name ->
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

  # ══ Commun ═══════════════════════════════════════════════════════════════════

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
