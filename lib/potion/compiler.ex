defmodule Potion.Compiler do
  @moduledoc """
  The v0 compiler: from a restricted Elixir AST to an SM83 fragment.

  This module knows no macros. It receives the AST that `Potion` captured, an
  allocation of cells, and returns a list of elements in the `Potion.Assembler`
  format. It is therefore a compiler that can be called by hand, in a console, on
  a piece of `quote` — and that is deliberate: a compiler only reachable through
  `defmodule` could only be debugged through `defmodule`.

  ## The allocation

  A game variable is **a cell of WRAM**, not a register and not a binding. Cells
  are taken in declaration order starting at `Potion.Runtime.actor_state()`:

      variables x: 80, y: 72

      0xC100  x
      0xC101  y
      0xC102  the "installed" flag

  The flag is the cell the game does not declare and never sees. It answers a
  problem the BEAM does not have: *where do the initial values go?* There is no
  "startup" in an actor — the kernel calls it once per frame, full stop. The
  first frame must therefore recognise itself, and the only state it can count on
  is the zero the init left in the page. The actor reads the flag: at zero, it
  lays down the initial values and raises the flag; afterwards it walks past. It
  is the hand-written actor pattern from `Potion.RuntimeTest`, generated.

  ## The arithmetic

  The v0 compiles three forms of assignment, and nothing else:

      x = 5          LD A, 5        / LD (x), A
      x = y          LD A, (y)      / LD (x), A
      x = x + 1      LD A, (x)      / ADD A, 1 / LD (x), A
      x = y - 3      LD A, (y)      / SUB A, 3 / LD (x), A

  Those four lines state the whole semantics: one byte, which wraps. `x = x + 1`
  on 255 gives 0, because `ADD A, 1` on 255 gives 0. No check is emitted — there
  is no room to emit one, and a Game Boy game relies on wrapping more often than
  it guards against it.

  Everything else is refused when the host module compiles. `x = x * 2` does not
  compile because the SM83 has no multiplication; it will become a loop of
  additions the day the language knows how to write one.

  ## The sign

  A byte has no sign of its own; the notation does.

      vx = -1        LD A, 255
      x = x + vx     ADD A, (HL)      -- and x goes down by one
      vx = -vx       CPL / INC A

  `-1` is how a game writes the byte `0xFF` when it means *one step backwards*,
  and nothing beyond the notation is needed to make it work: two's complement is
  built so that adding 255 and subtracting 1 leave the same byte behind. The
  arithmetic was already signed — it just had no way to be told so.

  What does *not* come for free is ordering. `CP` is an unsigned subtraction and
  the SM83 has no overflow flag, so `if vx < 0` cannot be spelled without
  biasing both sides, and no byte is below zero unsigned: it would compile to
  "never", quietly. So the four ordering comparisons refuse a negative literal,
  and the sign gets its own question instead:

      if negative?(vx), do: ...     BIT 7, A / JR Z

  `==` and `!=` take one anyway — equality is equality of bytes, and `0xFF` is
  `0xFF` under either reading.

  ## The conditions

  An `if` asks one of three things: a pad key, the sign of a variable, or a
  variable weighed against a byte.

      if pressed?(:right), do: x = x + 1
      if negative?(vx), do: x = 0
      if y > 140, do: y = 0
      if going_down == 1, do: y = y + 2, else: y = y - 2

  The six comparisons are `==`, `!=`, `<`, `>`, `<=` and `>=`, with the variable
  on the left and, on the right, a literal or another variable.

  All of them come down to `CP n`, a subtraction whose result is thrown away and
  whose flags say everything: `Z` that the two were equal, `C` that the variable
  was the smaller. Four comparisons are one jump over the body; `>` needs two,
  since it rules out equality as well as the borrow; and `<=` is the only one
  that jumps *into* the body, because "C or Z" cannot be spelled by jumping away
  from it.

  `else` is a second block and a jump over it. It is what makes a direction out
  of a comparison -- a ball that falls and climbs back needs to choose between
  two sentences, not merely to skip one.

  ## The generated labels

  All prefixed `potion_` and numbered. The kernel places `:actor` right before
  the fragment and never touches it again; this prefix keeps the two namespaces
  disjoint, which the assembler would check anyway — it refuses a duplicate
  label.
  """

  import Bitwise, only: [band: 2, bor: 2, bsr: 2]

  alias Potion.Assembler
  alias Potion.CompileError
  alias Potion.Runtime

  @typedoc """
  Where the actor's state lives: one cell per variable, plus the flag.
  """
  @type allocation :: %{
          cells: %{atom() => non_neg_integer()},
          order: [atom()],
          initial: %{atom() => byte() | [byte()]},
          arrays: %{atom() => pos_integer()},
          installed: non_neg_integer(),
          prefix: String.t(),
          tiles: %{atom() => non_neg_integer()},
          states: %{atom() => non_neg_integer()},
          state: non_neg_integer() | nil,
          entered: non_neg_integer() | nil,
          routines: MapSet.t(atom()),
          in_routine: atom() | nil
        }

  # The bits of the pad cell, as `Potion.Runtime.read_pad/0` files them. This
  # list is the only translation from the language to the hardware that is not
  # derived: the kernel documents the bits, we name them.
  @keys [right: 0, left: 1, up: 2, down: 3, a: 4, b: 5, select: 6, start: 7]

  # The OAM holds forty of them, and the DMA publishes them all.
  @oam_entries 40

  # 0xC100-0xC1FF: the page the kernel leaves to the actor.
  @state_page 0x100

  # ══ The allocation ═══════════════════════════════════════════════════════════

  @doc """
  Places the declared variables in WRAM, in the order they are written.

  The "installed" flag comes right after the last one, and that is why it is
  computed here rather than fixed at a set address: a fixed address would be a
  hole in the middle of the actor's page, and the day the language knows how to
  allocate something other than bytes, that hole would have to be worked around.

      iex> Potion.Compiler.allocate(x: 80, y: 72).cells
      %{x: 0xC100, y: 0xC101}

      iex> Potion.Compiler.allocate(x: 80, y: 72).installed
      0xC102

  An initial value may be written negative, and is laid down as the byte two's
  complement makes of it — a ball that starts by going left says so:

      iex> Potion.Compiler.allocate(vx: -1).initial
      %{vx: 0xFF}
  """
  @spec allocate(keyword(), keyword()) :: allocation()
  def allocate(declarations, opts \\ []) do
    base = Keyword.get(opts, :base, Runtime.actor_state())
    prefix = Keyword.get(opts, :prefix, "potion")
    tiles = Keyword.get(opts, :tiles, %{})
    states = Keyword.get(opts, :states, [])
    routines = Keyword.get(opts, :routines, [])
    count = Keyword.get(opts, :count, 1)

    list = declarations!(declarations)
    names = Keyword.keys(list)

    duplicates!(names, declarations)

    # Cells are handed out in declaration order and an array takes as many as it
    # has elements, so a name's address is the sum of everything written above
    # it rather than its rank. `arrays` remembers the lengths, which is the only
    # thing that tells `bullets` apart from `x` afterwards.
    # In a pool every variable is `count` cells rather than one -- an instance is
    # a column through them all. That is what lets the body's `bx` mean `bx[me]`
    # without a word of it appearing in the game.
    {cells, arrays, installed} =
      Enum.reduce(list, {%{}, %{}, base}, fn {name, value}, {cells, arrays, at} ->
        span =
          case value do
            values when is_list(values) -> length(values)
            _ -> count
          end

        arrays = if span > 1, do: Map.put(arrays, name, span), else: arrays

        {Map.put(cells, name, at), arrays, at + span}
      end)

    capacity!(installed + length(machine_cells(states)), declarations, base)

    %{
      cells: cells,
      order: names,
      initial: Map.new(list),
      installed: installed,
      arrays: arrays,
      prefix: prefix,
      tiles: tiles,
      states: states |> Enum.with_index() |> Map.new(),
      state: if(states == [], do: nil, else: installed + 1),
      entered: if(states == [], do: nil, else: installed + 2),
      routines: MapSet.new(routines),
      in_routine: nil,
      count: count,
      # The names an instance carries, which the body reads without an index and
      # everyone else reads with one.
      pooled: if(count > 1, do: MapSet.new(names), else: MapSet.new()),
      rooms: MapSet.new(Keyword.get(opts, :rooms, [])),
      # name => whether it has a bass voice.
      tunes:
        Map.new(Keyword.get(opts, :tunes, []), fn
          {name, bass?} -> {name, bass?}
          name -> {name, false}
        end)
    }
  end

  # An actor with states keeps two more cells than one without: which state it
  # is in, and which one it has already entered. They are counted here so that
  # the page's ceiling is checked against what an actor really occupies rather
  # than against what it declared.
  defp machine_cells([]), do: []
  defp machine_cells(_states), do: [:__state__, :__entered__]

  @doc """
  The address just past an allocation -- where the next actor's slice starts.
  """
  @spec next_free(allocation()) :: non_neg_integer()
  def next_free(%{entered: nil} = allocation), do: allocation.installed + 1
  def next_free(allocation), do: allocation.entered + 1

  defp declarations!(declarations) when is_list(declarations) do
    Enum.map(declarations, fn
      {name, values} when is_atom(name) and is_list(values) ->
        {name, elements!(name, values, declarations)}

      {name, value} when is_atom(name) ->
        {name, initial!(name, value)}

      other ->
        raise CompileError, """
        malformed declaration in `variables`: #{inspect(other)}

        `variables` expects a keyword list, each name receiving one byte:

            variables x: 80, y: 72
        """
    end)
  end

  defp declarations!(other) do
    raise CompileError, """
    `variables` expects a keyword list, got:

        #{Macro.to_string(other)}

    Rejected AST: #{inspect(other)}

    The form is `variables x: 80, y: 72` — a name, a byte, and one cell of WRAM \
    per name.
    """
  end

  # An array's cells, each read the way a lone one is -- so a negative element
  # is two's complement here too, and `vx: [-1, 1]` means what it looks like.
  defp elements!(_name, [], declarations) do
    raise CompileError, """
    an array with no cells in it: #{Macro.to_string(declarations)}

    An array is declared by writing its cells out, and there has to be one:

        variables bullets: [0, 0, 0, 0]
    """
  end

  defp elements!(name, values, _declarations) do
    Enum.map(values, &initial!(name, &1))
  end

  defp initial!(name, value) do
    case fold(value) do
      {:ok, folded} when folded in -128..255 ->
        two_complement(folded)

      _ ->
        raise CompileError, """
        initial value outside a byte, in `variables`: #{inspect(name)}

            #{Macro.to_string(value)}

        Rejected AST: #{inspect(value)}

        A Potion variable is a cell of WRAM: its initial value is an integer \
        literal from -128 to 255. It is laid down as it stands on the first \
        turn, with no computation — there is nobody to compute anything before \
        the actor runs.
        """
    end
  end

  defp duplicates!(names, declarations) do
    case names -- Enum.uniq(names) do
      [] ->
        :ok

      repeated ->
        raise CompileError, """
        variable declared twice: #{Enum.map_join(Enum.uniq(repeated), ", ", &inspect/1)}

            #{Macro.to_string(declarations)}

        Each name is worth one cell of WRAM, and two declarations of the same \
        name would not say which one carries the initial value.
        """
    end
  end

  defp capacity!(last, declarations, base) do
    ceiling = Runtime.actor_state() + @state_page - 1

    if last > ceiling do
      raise CompileError, """
      no room left in the actor page: #{last - base} cells asked for from \
      0x#{hex(base)}, and the page ends at 0x#{hex(ceiling)}.

          #{Macro.to_string(declarations)}

      The kernel leaves 0x#{hex(Runtime.actor_state())}-0x#{hex(ceiling)} to the actors, \
      that is #{@state_page} cells shared between all of them -- one per variable, \
      plus one "installed" flag each.
      """
    end
  end

  # Every generated label carries the actor's prefix, so two actors in one game
  # cannot collide -- the assembler would refuse the duplicate, which is the
  # right outcome but a late and puzzling one.
  defp label(allocation, kind, counter), do: :"#{allocation.prefix}_#{kind}_#{counter}"

  defp installed_label(allocation), do: :"#{allocation.prefix}_installed"

  # ══ The compilation ══════════════════════════════════════════════════════════

  @doc """
  The AST of an `every_frame` body plus an allocation, into an actor fragment.

  The fragment ends with `{:ret}`: it is a `CALL` that reaches it, once per
  frame, and `Potion.Runtime.program/1` refuses an actor that would not hand
  control back.
  """
  @spec compile(Macro.t(), allocation()) :: [Assembler.element()]
  def compile(body, allocation, routines \\ []) do
    {compiled, counter} = block(instance(body, allocation), allocation, 0)

    install(allocation) ++
      pool(compiled, allocation) ++
      [{:ret}] ++ subroutines(routines, allocation, counter)
  end

  # A pool is the body, run once per instance, with `me` counting. Everything
  # that makes the body speak of *this* instance happened before it got here:
  # `instance/2` turned each of the actor's own names into a cell of an array
  # indexed by `me`, so what loops is exactly the code a single actor would have
  # been.
  defp pool(compiled, %{count: 1}), do: compiled

  defp pool(compiled, allocation) do
    me = Runtime.me()
    again = :"#{allocation.prefix}_again"

    [{:xor, :a, :a}, {:ld, {:mem, me}, :a}, {:label, again}] ++
      compiled ++
      [
        {:ld, :a, {:mem, me}},
        {:inc, :a},
        {:ld, {:mem, me}, :a},
        {:cp, :a, allocation.count},
        {:jp, :nz, {:label, again}}
      ]
  end

  # Every name the pool owns becomes a cell of an array, subscripted by `me`.
  # A game with no pool never meets this.
  #
  # The index of an existing subscript is walked and its array is not: inside a
  # pool `bx[2]` means instance two's `bx`, which is how one instance speaks of
  # another, and rewriting the name there would make it `bx[me][2]`.
  defp instance(ast, %{pooled: pooled}) do
    if MapSet.size(pooled) == 0, do: ast, else: walk(ast, pooled)
  end

  defp walk({{:., meta, [Access, :get]}, brackets, [array, index]}, pooled) do
    {{:., meta, [Access, :get]}, brackets, [array, walk(index, pooled)]}
  end

  defp walk({name, meta, context} = node, pooled) when is_atom(name) and is_atom(context) do
    if MapSet.member?(pooled, name) do
      {{:., meta, [Access, :get]}, meta, [node, {:__me__, meta, nil}]}
    else
      node
    end
  end

  defp walk({form, meta, args}, pooled) when is_list(args) do
    {walk(form, pooled), meta, Enum.map(args, &walk(&1, pooled))}
  end

  defp walk(list, pooled) when is_list(list), do: Enum.map(list, &walk(&1, pooled))
  defp walk({left, right}, pooled), do: {walk(left, pooled), walk(right, pooled)}
  defp walk(other, _pooled), do: other

  @doc """
  An actor whose behaviour is a set of states, into one fragment.

  `states` is a list of `{name, on_enter, every_frame}` in declaration order, and
  that order is the numbering: the first state is 0 and the one the actor starts
  in.

  ## What the fragment looks like

  The current state is loaded once, and each state is a `CP` against its own
  number followed by a jump past its arm. Nothing runs between one arm's test and
  the next -- an arm that matches leaves by the end label -- so the register
  still holds the state all the way down the chain, and the whole dispatch costs
  two bytes a state.

  A linear chain rather than a jump table, and deliberately: a table costs a
  16-bit add, a `JP (HL)` and two bytes of ROM a state before the first
  instruction of any of them runs. It wins somewhere past a dozen states, which
  is more than a v0 actor has, and it would have to be explained to anybody
  reading the output.

  ## Entering

  A state with an `on_enter` compares the state against `entered` before running
  its frame body. They differ exactly once per transition, which is what makes
  `on_enter` the place to paint a screen: sixty times a second is what
  `every_frame` is for, and once is what a title screen wants.
  """
  @spec compile_machine(
          [{atom(), Macro.t() | nil, Macro.t() | nil}],
          allocation(),
          [{atom(), Macro.t()}]
        ) :: [Assembler.item()]
  def compile_machine(states, allocation, routines \\ []) do
    states =
      Enum.map(states, fn {name, enter, frame} ->
        {name, instance(enter, allocation), instance(frame, allocation)}
      end)

    done = done_label(allocation)

    {arms, counter} =
      Enum.reduce(states, {[], 0}, fn {name, on_enter, every_frame}, {acc, counter} ->
        index = Map.fetch!(allocation.states, name)
        {arm, counter} = arm(index, on_enter, every_frame, allocation, counter, done)
        {acc ++ arm, counter}
      end)

    install(allocation) ++
      [{:ld, :a, {:mem, allocation.state}}] ++
      arms ++ [{:label, done}, {:ret}] ++ subroutines(routines, allocation, counter)
  end

  defp arm(index, on_enter, every_frame, allocation, counter, done) do
    next = :"#{allocation.prefix}_state_#{index}_next"

    {enter, counter} = enter(index, on_enter, allocation, counter)

    {frame, counter} =
      if every_frame, do: block(every_frame, allocation, counter), else: {[], counter}

    arm =
      [{:cp, :a, index}, {:jp, :nz, {:label, next}}] ++
        enter ++ frame ++ [{:jp, {:label, done}}, {:label, next}]

    {arm, counter}
  end

  defp enter(_index, nil, _allocation, counter), do: {[], counter}

  defp enter(index, body, allocation, counter) do
    entered = :"#{allocation.prefix}_state_#{index}_entered"
    {compiled, counter} = block(body, allocation, counter)

    {[
       {:ld, :a, {:mem, allocation.entered}},
       {:cp, :a, index},
       {:jp, :z, {:label, entered}}
     ] ++
       compiled ++
       [
         {:ld, :a, index},
         {:ld, {:mem, allocation.entered}, :a},
         {:label, entered}
       ], counter}
  end

  # A routine is a labelled block ending in RET, laid after the actor's body
  # where nothing falls into it. `check_actor!` looks at the fragment's last
  # element and finds the last routine's RET, which is why appending them is
  # safe rather than merely convenient.
  defp subroutines([], _allocation, _counter), do: []

  defp subroutines(list, allocation, counter) do
    acyclic!(list)

    {elements, _counter} =
      Enum.reduce(list, {[], counter}, fn {name, body}, {acc, counter} ->
        {compiled, counter} =
          block(instance(body, allocation), %{allocation | in_routine: name}, counter)

        {acc ++ [{:label, routine_label(allocation, name)}] ++ compiled ++ [{:ret}], counter}
      end)

    elements
  end

  # Routines that call each other in a circle would run until the stack reached
  # the actor's own cells, which is a crash a long way from its cause. The graph
  # is walked here, where the names are still names.
  defp acyclic!(list) do
    graph = Map.new(list, fn {name, body} -> {name, calls(body)} end)
    Enum.each(Map.keys(graph), &descend!(&1, graph, []))
  end

  defp calls(body) do
    {_tree, found} =
      Macro.prewalk(body, [], fn
        {name, _, []} = node, acc when is_atom(name) -> {node, [name | acc]}
        node, acc -> {node, acc}
      end)

    Enum.uniq(found)
  end

  defp descend!(name, graph, seen) do
    if name in seen do
      raise CompileError, """
      the routines call each other in a circle: #{Enum.map_join(Enum.reverse([name | seen]), " -> ", &inspect/1)}

      A call is a `CALL`, and the return address it pushes is only taken back by \
      the matching `RET`. Going round would grow the stack by two bytes a lap \
      until it reached the actor's own cells -- a crash a long way from its cause.
      """
    end

    Enum.each(Map.get(graph, name, []), &descend!(&1, graph, [name | seen]))
  end

  defp routine_label(allocation, name), do: :"#{allocation.prefix}_do_#{name}"

  defp done_label(allocation), do: :"#{allocation.prefix}_done"

  # The first turn: lay down the initial values, then never come back to them.
  # With no variables there is nothing to install, and the flag stays an inert
  # cell — we do not emit six bytes to keep a state nobody wants.
  defp install(%{order: []}), do: []

  defp install(allocation) do
    [
      {:ld, :a, {:mem, allocation.installed}},
      {:and, :a, :a},
      # JP and not JR: what this jumps over is five bytes per declared variable,
      # so an actor with twenty-six of them would put the label out of a JR's
      # reach. See `skip_unless/4` for why that rule is applied everywhere.
      {:jp, :nz, {:label, installed_label(allocation)}},
      {:ld, :a, 0x01},
      {:ld, {:mem, allocation.installed}, :a}
    ] ++
      Enum.flat_map(allocation.order, fn name -> initial(name, allocation) end) ++
      first_state(allocation) ++
      [{:label, installed_label(allocation)}]
  end

  # An array lays down one value per element, at consecutive addresses. There is
  # no loop: the values are known here and a loop would cost a counter, a
  # pointer and a comparison to save four bytes on a first frame that runs once.
  defp initial(name, allocation) do
    case allocation.initial[name] do
      values when is_list(values) ->
        values
        |> Enum.with_index()
        |> Enum.flat_map(fn {value, offset} ->
          [{:ld, :a, value}, {:ld, {:mem, allocation.cells[name] + offset}, :a}]
        end)

      value ->
        # In a pool this lays the same first value in every instance, which is
        # what "they all start alike" means and is all a game can say today.
        [{:ld, :a, value}] ++
          Enum.map(0..(span(name, allocation) - 1)//1, fn offset ->
            {:ld, {:mem, allocation.cells[name] + offset}, :a}
          end)
    end
  end

  defp span(name, allocation) do
    if MapSet.member?(Map.get(allocation, :pooled, MapSet.new()), name) do
      allocation.count
    else
      1
    end
  end

  # The state an actor wakes up in is the first one written, and `entered` starts
  # at a number no state answers to -- the count, since indices stop one short of
  # it. That is what makes the first frame an entry rather than a continuation,
  # so `on_enter` runs for the opening state without it being a special case.
  defp first_state(%{state: nil}), do: []

  defp first_state(allocation) do
    [
      {:xor, :a, :a},
      {:ld, {:mem, allocation.state}, :a},
      {:ld, :a, map_size(allocation.states)},
      {:ld, {:mem, allocation.entered}, :a}
    ]
  end

  # A block: the statements one after another, the label counter passing from one
  # to the next. It comes back out of the block because two sibling `if`s cannot
  # share an end label.
  defp block(body, allocation, counter) do
    body
    |> statements()
    |> Enum.reduce({[], counter}, fn statement, {acc, counter} ->
      {elements, counter} = statement(statement, allocation, counter)
      {acc ++ elements, counter}
    end)
  end

  defp statements({:__block__, _, list}), do: list
  defp statements(nil), do: []
  defp statements(single), do: [single]

  # ── An assignment ───────────────────────────────────────────────────────────

  # `bullets[i] = …`. The value is worked out first and pushed, because the
  # address is worked out through HL and the expression is free to use HL too --
  # `bullets[i] = bullets[i] + x` uses it twice. Two bytes to make the order of
  # those two never matter.
  #
  # A literal index needs none of that: `bullets[2]` is an address the compiler
  # already knows, so it compiles into exactly what a plain cell does.
  defp statement(
         {:=, _, [{{:., _, [Access, :get]}, _, [array, index]}, expression]} = statement,
         allocation,
         counter
       ) do
    value = load(expression, allocation, statement)

    case indexed(array, index, allocation, statement) do
      {[], {:mem, address}} ->
        {value ++ [{:ld, {:mem, address}, :a}], counter}

      {setup, operand} ->
        {value ++ [{:push, :af}] ++ setup ++ [{:pop, :af}, {:ld, operand, :a}], counter}
    end
  end

  defp statement({:=, _, [target, expression]} = statement, allocation, counter) do
    address = cell!(target, allocation, statement)
    {load(expression, allocation, statement) ++ [{:ld, {:mem, address}, :a}], counter}
  end

  # ── A condition ─────────────────────────────────────────────────────────────

  defp statement({:if, _, [condition, blocks]} = statement, allocation, counter) do
    {then_body, else_body} = if_bodies!(blocks, statement)

    done = label(allocation, "end", counter)
    otherwise = if else_body == :none, do: done, else: label(allocation, "else", counter)

    {test, counter} = condition!(condition, otherwise, allocation, statement, counter + 1)
    {taken, counter} = block(then_body, allocation, counter)
    {tail, counter} = else_tail(else_body, otherwise, done, allocation, counter)

    {test ++ taken ++ tail, counter}
  end

  # ── An OAM entry ────────────────────────────────────────────────────────────

  defp statement({:sprite, _, [index, fields]} = statement, allocation, counter)
       when is_integer(index) do
    base = Runtime.oam_mirror() + 4 * entry!(index, statement)
    {x, y, tile} = fields!(fields, statement)
    tile = tile!(tile, allocation, statement)

    elements =
      field(y, 16, base, allocation, statement) ++
        field(x, 8, base + 1, allocation, statement) ++
        field(tile, 0, base + 2, allocation, statement) ++
        [{:xor, :a, :a}, {:ld, {:mem, base + 3}, :a}]

    {elements, counter}
  end

  # An entry the game picks while it runs -- which is what a pool of bullets
  # needs, each instance writing its own. The address is `mirror + 4 * n`, and
  # four is two doublings rather than a multiply the processor does not have.
  #
  # It is kept in DE and not HL, and that is the whole reason this clause is
  # short. A field's value may be a cell of an array, which goes through HL, so
  # an address parked there would be gone by the time the value arrived. `LD
  # (DE), A` exists, DE survives everything the values do, and the four bytes
  # are consecutive so `INC DE` walks them.
  defp statement({:sprite, _, [index, fields]} = statement, allocation, counter) do
    {x, y, tile} = fields!(fields, statement)
    tile = tile!(tile, allocation, statement)

    address =
      [
        {:ld, :a, {:mem, cell!(index, allocation, statement)}},
        {:add, :a, :a},
        {:add, :a, :a},
        {:ld, :e, :a},
        {:ld, :d, 0},
        {:ld, :hl, Runtime.oam_mirror()},
        {:add, :hl, :de},
        {:ld, :d, :h},
        {:ld, :e, :l}
      ]

    write = fn value, offset ->
      sprite_value(value, offset, allocation, statement) ++
        [{:ld, {:mem, :de}, :a}, {:inc, :de}]
    end

    elements =
      address ++
        write.(y, 16) ++
        write.(x, 8) ++
        write.(tile, 0) ++
        [{:xor, :a, :a}, {:ld, {:mem, :de}, :a}]

    {elements, counter}
  end

  # ── A square of the background ──────────────────────────────────────────────

  defp statement({:background, _, [column, row, fields]} = statement, allocation, counter) do
    address = Runtime.background_address(square!(column, statement), square!(row, statement))
    {kind, value} = background_field!(fields, statement)
    value = if kind == :tile, do: tile!(value, allocation, statement), else: value
    base = if kind == :digit, do: Runtime.digits(), else: 0

    {sprite_value(value, base, allocation, statement) ++ [{:ld, {:mem, address}, :a}], counter}
  end

  # ── Words on the background ─────────────────────────────────────────────────

  defp statement({:text, _, [column, row, string]} = statement, _allocation, counter)
       when is_binary(string) do
    column = square!(column, statement)
    row = square!(row, statement)
    characters = string |> String.upcase() |> String.to_charlist()

    if column + length(characters) > 32 do
      raise CompileError, """
      #{inspect(string)} runs off the map: #{length(characters)} squares from \
      column #{column}, and the map is 32 wide.

          #{one_line(statement)}

      The screen shows the first 20 columns, so a line meant to be read starts \
      at 20 minus its length or less.
      """
    end

    # Unrolled, one character at a time, and there is nothing to unroll it from:
    # the string is known here and the map addresses are consecutive, so a loop
    # would need the string in ROM, a pointer, a counter and a terminator to save
    # three bytes a character on a title screen written once.
    {characters
     |> Enum.with_index()
     |> Enum.flat_map(fn {character, offset} ->
       [
         {:ld, :a, glyph!(character, string, statement)},
         {:ld, {:mem, Runtime.background_address(column + offset, row)}, :a}
       ]
     end), counter}
  end

  defp statement({:text, _, [_column, _row, other]} = statement, _allocation, _counter) do
    raise CompileError, """
    `text` takes a string written out: #{Macro.to_string(other)}

        #{one_line(statement)}

    The letters are turned into tile numbers while the game compiles, and laid \
    down one store each. There is nothing at run time that could read a cell and \
    find words in it.

    A number that changes is what `digit:` is for:

        background(2, 1, digit: score)
    """
  end

  # ── A note ──────────────────────────────────────────────────────────────────
  #
  # The console has no pitch register. It has an eleven-bit number `x`, and the
  # square wave it makes comes out at
  #
  #     f = 131072 / (2048 - x)
  #
  # so a note is that formula run backwards, here, at compile time. A game says
  # `beep(:c5)` and never learns the number -- which is the same bargain `tile:`
  # and `digit:` strike, and the reason the frequency table below is written as
  # arithmetic rather than as a list of magic words.
  #
  # 440 Hz is A4 by definition and every other note is a twelfth root of two away
  # from it, so the whole table is one expression. Below about 64 Hz the formula
  # asks for a negative `x` and there is no note to be had; that is where the
  # range stops, and it stops on its own rather than by being clipped.
  # One table, in `Potion.Music`, because a note means the same thing whether it
  # is a sound effect or a bar of a tune -- and two tables that agreed today
  # would be two tables to keep agreeing.

  @notes Potion.Music.notes()

  defp statement({:beep, _, [note]} = statement, _allocation, counter) when is_atom(note) do
    {duty, envelope, low, high} = Runtime.pulse()

    x = note!(note, statement)

    # Four writes and no state kept. The envelope is what makes that enough: the
    # channel is told to start at full volume and step down on its own, so the
    # sound ends without the game ever coming back to end it. A `beep` inside an
    # `if` is a sound effect, and the frame after it has nothing to remember.
    {[
       # 50% duty, no length counter -- the envelope decides when it stops.
       {:ld, :a, 0x80},
       {:ldh, {:high, duty}, :a},
       # Volume 15, stepping down, one tick of 64 Hz between steps: about a
       # quarter of a second from full to silence.
       {:ld, :a, 0xF1},
       {:ldh, {:high, envelope}, :a},
       {:ld, :a, band(x, 0xFF)},
       {:ldh, {:high, low}, :a},
       # Bit 7 is the trigger, and it comes last: the frequency has to be there
       # before the channel is told to start, or the first instant is the old note.
       {:ld, :a, bor(0x80, bsr(x, 8))},
       {:ldh, {:high, high}, :a}
     ], counter}
  end

  defp statement({:beep, _, [other]} = statement, _allocation, _counter) do
    raise CompileError, """
    `beep` takes a note, written out: #{Macro.to_string(other)}

        #{one_line(statement)}

    The console has no pitch register — it has a number, and which number a note \
    is gets worked out while the game compiles. There is nothing at run time that \
    could turn a cell into a frequency.
    """
  end

  # ── A screen ────────────────────────────────────────────────────────────────
  #
  # `show(:clearing)` paints a whole room: the kernel turns the panel off,
  # copies 360 bytes into the background map, and turns it back on. One dark
  # frame -- which is exactly what a room change looked like on the machines
  # this console imitates, and the honest alternative to writes the panel would
  # drop mid-scan.
  #
  # HL carries the room's address into the call, which is the whole calling
  # convention: HL is already the register every seam here clobbers freely.
  defp statement({:show, _, [name]} = statement, allocation, counter) when is_atom(name) do
    rooms = Map.get(allocation, :rooms, MapSet.new())

    unless MapSet.member?(rooms, name) do
      known = rooms |> Enum.sort() |> Enum.map_join(", ", &inspect/1)

      raise CompileError, """
      no room is called #{inspect(name)}.

          #{one_line(statement)}

      #{if known == "", do: "This game declares none.", else: "The ones it has: #{known}."}

      A room is declared beside the actors and shown by name:

          room :clearing, \"\"\"
          ...twenty columns by eighteen rows...
          \"\"\", tiles: %{?# => :wall}

          show(:clearing)
      """
    end

    {[
       {:ld, :hl, {:label, :"potion_room_#{name}"}},
       {:call, {:label, :show_room}}
     ], counter}
  end

  defp statement({:show, _, [other]} = statement, _allocation, _counter) do
    raise CompileError, """
    `show` takes the name of a room, written out: #{Macro.to_string(other)}

        #{one_line(statement)}

    A room is 360 bytes at a known place in the cartridge, and which place is \
    decided while the game compiles.
    """
  end

  # ── A knock ─────────────────────────────────────────────────────────────────
  #
  # Channel 4 is a shift register, not an oscillator: there is no note to name.
  # What `NR43` sets is how often the register is clocked -- a divisor and a
  # shift -- so the choice a game makes is how *coarse* the noise is, and the
  # four below are that continuum with names on it.
  #
  #     :tick  0x20  shift 2, divisor 8    a bright short hiss
  #     :hit   0x44  shift 4, divisor 64   a knock
  #     :thud  0x66  shift 6, divisor 96   low, and a beat longer
  #     :boom  0x77  shift 7, divisor 112  the lowest rumble the chip has
  #
  # The second byte is the envelope, and it is what makes a knock a knock: full
  # volume stepping down on its own, faster for the short ones. Nothing is kept,
  # exactly as `beep` keeps nothing -- four writes and the channel sees itself
  # out.
  #
  # Numbers rather than a name would have been the honest exposure of a register
  # and a bad language: `noise(4, 2)` is a thing an author picks blind, and this
  # project has already paid once for a number chosen that way.
  @noises %{
    tick: {0x20, 0xF1},
    hit: {0x44, 0xF1},
    thud: {0x66, 0xF2},
    boom: {0x77, 0xF4}
  }

  defp statement({:noise, _, [kind]} = statement, _allocation, counter) when is_atom(kind) do
    {_length, envelope, shape, trigger} = Runtime.noise()

    case Map.fetch(@noises, kind) do
      {:ok, {nr43, nr42}} ->
        {[
           {:ld, :a, nr42},
           {:ldh, {:high, envelope}, :a},
           {:ld, :a, nr43},
           {:ldh, {:high, shape}, :a},
           # The trigger last, once the shape is there -- a channel told to start
           # before it is told what to be starts as whatever it was.
           {:ld, :a, 0x80},
           {:ldh, {:high, trigger}, :a}
         ], counter}

      :error ->
        raise CompileError, """
        no noise is called #{inspect(kind)}.

            #{one_line(statement)}

        There are four, from the brightest to the lowest: \
        #{@noises |> Map.keys() |> Enum.sort() |> Enum.map_join(", ", &inspect/1)}.

        They are channel 4, which has no pitch to name — it is a shift register, \
        and what these choose is how coarse it sounds.
        """
    end
  end

  defp statement({:noise, _, [other]} = statement, _allocation, _counter) do
    raise CompileError, """
    `noise` takes one of four names, written out: #{Macro.to_string(other)}

        #{one_line(statement)}

    #{@noises |> Map.keys() |> Enum.sort() |> Enum.map_join(", ", &inspect/1)}
    """
  end

  # ── A tune ──────────────────────────────────────────────────────────────────
  #
  # Two pointers and a countdown, and then the kernel does the rest: it reads a
  # step every frame between the pad and the actors. A game says this once.
  #
  # The base is written as well as the cursor, and that is what makes a tune
  # loop -- the player, reaching a step of length zero, goes back to where the
  # base says it started.
  defp statement({:play, _, [name]} = statement, allocation, counter) when is_atom(name) do
    voices = tune!(name, allocation, statement)

    {[
       {:ld, :a, voices.duty},
       {:ld, {:mem, Runtime.duty_cell()}, :a},
       {:ld, :a, voices.envelope},
       {:ld, {:mem, Runtime.env_cell()}, :a}
     ] ++
       wobble(voices.vibrato) ++
       arm(Runtime.music_cells(), :"potion_tune_#{name}") ++
       start(voices.harmony?, Runtime.harmony_cells(), :"potion_harmony_#{name}", :pulse_two) ++
       start(voices.bass?, Runtime.bass_cells(), :"potion_bass_#{name}", :wave), counter}
  end

  defp statement({:play, _, [other]} = statement, _allocation, _counter) do
    raise CompileError, """
    `play` takes the name of a tune, written out: #{Macro.to_string(other)}

        #{one_line(statement)}

    A tune is a run of bytes at a known place in the cartridge, and which place \
    is decided while the game compiles.
    """
  end

  # A pointer of zero is what the kernel reads as silence, and the envelope is
  # taken down in the same breath so the note already sounding stops rather than
  # hanging on until something else triggers the channel.
  defp statement({:silence, _, []}, _allocation, counter) do
    {tune, _, _} = Runtime.music_cells()
    {harmony, _, _} = Runtime.harmony_cells()
    {bass, _, _} = Runtime.bass_cells()
    {_nr10, _nr11, nr12, _nr13, _nr14} = Runtime.pulse_one()
    {_nr21, nr22, _nr23, _nr24} = Runtime.pulse_two()
    {_nr30, nr32, _nr33, _nr34} = Runtime.wave()

    {[
       {:xor, :a, :a},
       {:ld, {:mem, tune}, :a},
       {:ld, {:mem, tune + 1}, :a},
       {:ld, {:mem, harmony}, :a},
       {:ld, {:mem, harmony + 1}, :a},
       {:ld, {:mem, bass}, :a},
       {:ld, {:mem, bass + 1}, :a},
       {:ldh, {:high, nr12}, :a},
       {:ldh, {:high, nr22}, :a},
       {:ldh, {:high, nr32}, :a}
     ], counter}
  end

  # ── Calling a routine ───────────────────────────────────────────────────────
  #
  # Written `bounce()`, and the empty parentheses are what make it unambiguous:
  # a cell arrives as `{name, meta, nil}` and every other statement carries
  # arguments, so a name with an empty argument list can only be a call.
  #
  # No parameters, and none are missing. An actor's cells are the only storage
  # there is, and both callers of Pong's bounce set `off` and `vx` before calling
  # -- which is what an argument would have compiled to anyway, minus the
  # register juggling.
  defp statement({name, _, []} = statement, allocation, counter) when is_atom(name) do
    unless MapSet.member?(allocation.routines, name) do
      known = allocation.routines |> Enum.sort() |> Enum.map_join(", ", &inspect/1)

      raise CompileError, """
      no routine is named #{inspect(name)}.

          #{one_line(statement)}

      #{if known == "", do: "This actor declares none.", else: "The ones it has: #{known}."}

      A routine is written once inside the actor and called by its name:

          routine :bounce do
            …
          end
      """
    end

    {[{:call, {:label, routine_label(allocation, name)}}], counter}
  end

  # ── Changing state ──────────────────────────────────────────────────────────

  defp statement({:become, _, [name]} = statement, allocation, counter) do
    if allocation.in_routine do
      raise CompileError, """
      `become` inside the routine #{inspect(allocation.in_routine)}.

          #{one_line(statement)}

      `become` ends the frame by jumping to the end of the actor, and a routine \
      was reached by a `CALL` -- so the return address it pushed would still be \
      on the stack, and every transition would leave two more bytes there until \
      the stack reached the actor's own cells.

      Have the routine decide, and the caller act on it:

          routine :check do
            if theirs >= 5, do: finished = 1
          end

          check()
          if finished == 1, do: become(:over)
      """
    end

    if allocation.state == nil do
      raise CompileError, """
      `become` in an actor that has no states.

          #{one_line(statement)}

      An actor is either one `every_frame` or a set of `state` blocks. There is \
      nothing here to become.

          defactor :ball do
            state :serving do
              every_frame do
                if pressed?(:start), do: become(:playing)
              end
            end

            state :playing do
              every_frame do
                …
              end
            end
          end
      """
    end

    index = state!(name, allocation, statement)

    # `entered` is set to the impossible number rather than left alone, so that
    # `become` into the state already running is a real re-entry and runs
    # `on_enter` again. Leaving it would have made that one case silently
    # different from every other, which is the kind of rule nobody remembers.
    #
    # And it ends the frame: what follows `become` in the block does not run.
    # An actor that has changed state has finished this turn, and the alternative
    # -- carrying on through the body of the state just left -- is a bug that
    # reads like a feature.
    {[
       {:ld, :a, map_size(allocation.states)},
       {:ld, {:mem, allocation.entered}, :a},
       {:ld, :a, index},
       {:ld, {:mem, allocation.state}, :a},
       {:jp, {:label, done_label(allocation)}}
     ], counter}
  end

  # ── The palette, which is what a fade is made of ────────────────────────────

  # Four steps to black. Each byte is four two-bit entries, low pair first,
  # saying which grey each shade prints as -- so darkening is not a blend, it is
  # a rewriting of that table.
  #
  #     0xE4  11 10 01 00   the identity: shade 0 white, shade 3 black
  #     0xF9  11 11 10 01   everything one grey darker
  #     0xFE  11 11 11 10   two darker, and the bottom already at black
  #     0xFF  11 11 11 11   every shade black
  @fades {0xE4, 0xF9, 0xFE, 0xFF}

  defp statement({:fade, _, [level]}, _allocation, counter)
       when is_integer(level) and level in 0..3 do
    {bgp, obp0} = Runtime.palettes()

    {[
       {:ld, :a, elem(@fades, level)},
       {:ldh, {:high, bgp}, :a},
       {:ldh, {:high, obp0}, :a}
     ], counter}
  end

  defp statement({:fade, _, [other]} = statement, _allocation, _counter) do
    raise CompileError, """
    `fade` takes a step from 0 to 3, written out: #{Macro.to_string(other)}

        #{one_line(statement)}

    0 is the picture as drawn and 3 is a black screen; 1 and 2 are the two \
    between. A fade is therefore a state that counts frames and says `fade(1)`, \
    `fade(2)`, `fade(3)` as it goes.

    A step held in a cell would want a table and a lookup, and does not exist \
    yet.
    """
  end

  defp statement(other, _allocation, _counter), do: reject!(other)

  # A voice the tune does not have is silenced rather than left alone: whatever
  # the last tune put on that channel would otherwise go on sounding underneath
  # this one.
  defp start(true, cells, label, _kind), do: arm(cells, label)

  defp start(false, {tune, _base, _wait}, _label, kind) do
    register =
      case kind do
        :pulse_two -> elem(Runtime.pulse_two(), 1)
        :wave -> elem(Runtime.wave(), 1)
      end

    [
      {:xor, :a, :a},
      {:ld, {:mem, tune}, :a},
      {:ld, {:mem, tune + 1}, :a},
      {:ldh, {:high, register}, :a}
    ]
  end

  # Which table the kernel walks, as an address -- or nothing at all, which is
  # what a zero there means.
  defp wobble(:none) do
    cell = Runtime.wobble_cell()
    [{:xor, :a, :a}, {:ld, {:mem, cell}, :a}, {:ld, {:mem, cell + 1}, :a}]
  end

  defp wobble(kind) do
    cell = Runtime.wobble_cell()

    [
      {:ld, :hl, {:label, :"wobble_#{kind}"}},
      {:ld, :a, :l},
      {:ld, {:mem, cell}, :a},
      {:ld, :a, :h},
      {:ld, {:mem, cell + 1}, :a}
    ]
  end

  defp arm({tune, base, wait}, label) do
    [
      {:ld, :hl, {:label, label}},
      {:ld, :a, :l},
      {:ld, {:mem, tune}, :a},
      {:ld, {:mem, base}, :a},
      {:ld, :a, :h},
      {:ld, {:mem, tune + 1}, :a},
      {:ld, {:mem, base + 1}, :a},
      # Nothing to wait for: the next frame reads the first step.
      {:xor, :a, :a},
      {:ld, {:mem, wait}, :a}
    ]
  end

  defp tune!(name, allocation, statement) do
    tunes = Map.get(allocation, :tunes, %{})

    if Map.has_key?(tunes, name) do
      Map.fetch!(tunes, name)
    else
      known = tunes |> Map.keys() |> Enum.sort() |> Enum.map_join(", ", &inspect/1)

      raise CompileError, """
      no tune is called #{inspect(name)}.

          #{one_line(statement)}

      #{if known == "", do: "This game declares none.", else: "The ones it has: #{known}."}

      A tune is declared beside the actors and named where it is started:

          music :theme, "c4 . e4 . g4 ."

          play(:theme)
      """
    end
  end

  @doc """
  The notes a `beep` can name, and the eleven-bit number each one is.

      iex> Potion.Compiler.notes()[:a4]
      1750
      iex> Potion.Compiler.notes()[:a5]
      1899

  1750 is `2048 - 131072/440`, which is the console's own formula for 440 Hz. An
  octave up halves the divisor, which is why the two numbers are not a ratio of
  each other -- the register counts *down* to a period, not up to a pitch.
  """
  @spec notes() :: %{atom() => 0..2047}
  defdelegate notes, to: Potion.Music

  # The screen shows 20 columns of 18 rows, and a room is exactly a screen.
  @room_w 20
  @room_h 18

  @doc """
  A drawing of a screen into the 360 bytes the background map takes.

  Twenty columns by eighteen rows -- the panel, exactly. A space is the empty
  tile without being declared; every other character is named by the mapping,
  as a tile of the game's sheet or a bare index.

  A row shorter than twenty columns is padded with the empty tile, and that is
  an allowance for editors rather than looseness: most strip trailing spaces on
  save, and refusing what an editor silently did would be a fight nobody wins.
  A missing *row* is refused -- there is no editor that eats lines.
  """
  @spec room!(atom(), String.t(), map(), %{atom() => non_neg_integer()}) :: binary()
  def room!(name, ascii, mapping, tiles) do
    unless is_map(mapping) do
      raise CompileError, """
      the room #{inspect(name)}'s tiles are a map from character to tile:

          room #{inspect(name)}, "…", tiles: %{?# => :wall, ?~ => 0}
      """
    end

    rows =
      case ascii |> String.split("\n") |> Enum.reverse() do
        ["" | rest] -> Enum.reverse(rest)
        rest -> Enum.reverse(rest)
      end

    unless length(rows) == @room_h do
      raise CompileError, """
      the room #{inspect(name)} is #{length(rows)} rows tall, and a screen is #{@room_h}.

      A room is exactly what the panel shows: #{@room_w} columns by #{@room_h} \
      rows. Rows may run short -- editors strip trailing spaces -- but every one \
      of the eighteen has to be there.
      """
    end

    for {row, y} <- Enum.with_index(rows), into: <<>> do
      length = String.length(row)

      if length > @room_w do
        raise CompileError, """
        the room #{inspect(name)}'s row #{y} is #{length} columns wide, and a \
        screen is #{@room_w}.
        """
      end

      padded = String.pad_trailing(row, @room_w)

      for <<character::utf8 <- padded>>, into: <<>> do
        <<cell!(character, {name, y}, mapping, tiles)>>
      end
    end
  end

  # A space is the empty tile the init already filled the map with -- the same
  # bargain `text` strikes -- so the unmarked parts of a drawing cost nothing
  # to say.
  defp cell!(?\s, _where, _mapping, _tiles), do: 1

  defp cell!(character, {name, y}, mapping, tiles) do
    case Map.fetch(mapping, character) do
      {:ok, index} when is_integer(index) and index in 0..255 ->
        index

      {:ok, tile} when is_atom(tile) ->
        case Map.fetch(tiles, tile) do
          {:ok, index} ->
            Runtime.art_base() + index

          :error ->
            known = tiles |> Map.keys() |> Enum.sort() |> Enum.map_join(", ", &inspect/1)

            raise CompileError, """
            the room #{inspect(name)} maps #{inspect(<<character::utf8>>)} to \
            #{inspect(tile)}, and no tile is named that.

            #{if known == "", do: "This game declares no tiles.", else: "The ones it has: #{known}."}
            """
        end

      {:ok, other} ->
        raise CompileError, """
        the room #{inspect(name)} maps #{inspect(<<character::utf8>>)} to \
        #{inspect(other)} -- a tile is a name from the sheet or an index from 0 \
        to 255.
        """

      :error ->
        raise CompileError, """
        the room #{inspect(name)} draws #{inspect(<<character::utf8>>)} on row \
        #{y}, and the mapping does not say which tile that is.

        A space is the empty tile without being declared; everything else is \
        named:

            room #{inspect(name)}, "…", tiles: %{?#{<<character::utf8>>} => :wall}
        """
    end
  end

  defp note!(name, statement) do
    case Map.fetch(@notes, name) do
      {:ok, x} ->
        x

      :error ->
        raise CompileError, """
        no note is called #{inspect(name)}.

            #{one_line(statement)}

        Notes are a letter, an optional `s` for the sharp, and an octave: \
        #{inspect(:c2)} up to #{inspect(:b7)}, so #{inspect(:a4)} is concert A \
        and #{inspect(:fs5)} is the F sharp above the treble staff.

        Below C2 the console cannot help: its register counts down to a period, \
        and under about 64 Hz the number it would need is negative.
        """
    end
  end

  # A character to the tile that draws it. Three ranges and a space, and the
  # space is the one worth pointing at: it is tile 1, the empty tile the init
  # already fills the whole map with, so a gap between two words costs nothing
  # that was not already spent.
  defp glyph!(?\s, _string, _statement), do: 1

  defp glyph!(character, _string, _statement) when character in ?0..?9,
    do: Runtime.digits() + (character - ?0)

  defp glyph!(character, _string, _statement) when character in ?A..?Z,
    do: Runtime.alphabet() + (character - ?A)

  defp glyph!(character, string, statement) do
    case Enum.find_index(~c".,!?-:", &(&1 == character)) do
      nil ->
        raise CompileError, """
        no glyph for #{inspect(<<character::utf8>>)}, in #{inspect(string)}.

            #{one_line(statement)}

        The kernel's font is A to Z, the ten digits, a space, and `. , ! ? - :` \
        Anything else would be a tile the game draws itself and places with \
        `background`.
        """

      index ->
        Runtime.alphabet() + 26 + index
    end
  end

  defp state!(name, allocation, statement) when is_atom(name) do
    case Map.fetch(allocation.states, name) do
      {:ok, index} ->
        index

      :error ->
        known =
          allocation.states
          |> Enum.sort_by(fn {_name, index} -> index end)
          |> Enum.map_join(", ", fn {name, _index} -> inspect(name) end)

        raise CompileError, """
        no state is named #{inspect(name)}.

            #{one_line(statement)}

        The ones this actor has, in the order they were written: #{known}.
        """
    end
  end

  defp state!(other, _allocation, statement) do
    raise CompileError, """
    `become` takes the name of a state, written out: #{Macro.to_string(other)}

        #{one_line(statement)}

    The target is decided when the game compiles, not while it runs -- a state \
    is a place in the ROM, and there is nothing to look it up in.
    """
  end

  # A bare atom in `tile:` is a name from `tiles from: ...`, and it can be
  # nothing else: a variable arrives as `{name, meta, context}` and an index as
  # an integer, so there is no ambiguity to resolve and no keyword to introduce.
  #
  # The base is added here for the same reason `digit:` adds the font's: a game
  # says what it drew, and never learns that the kernel spoke for the first
  # twelve tiles before it.
  defp tile!(name, allocation, statement) when is_atom(name) and name not in [nil, true, false] do
    tiles = Map.get(allocation, :tiles, %{})

    case Map.fetch(tiles, name) do
      {:ok, index} ->
        Runtime.art_base() + index

      :error ->
        raise CompileError, """
        no tile is named #{inspect(name)}.

            #{one_line(statement)}

        #{known_tiles(tiles)}

        Names are given to the tiles of a sheet in reading order — left to \
        right, then down — by the `tiles` declaration:

            tiles from: "art/pong.png", names: [:ball, :paddle]
        """
    end
  end

  defp tile!(value, _allocation, _statement), do: value

  defp known_tiles(tiles) when map_size(tiles) == 0 do
    "This game declares no tiles at all."
  end

  defp known_tiles(tiles) do
    names =
      tiles
      |> Enum.sort_by(fn {_name, index} -> index end)
      |> Enum.map_join(", ", fn {name, _index} -> inspect(name) end)

    "The ones it has, in the order they were drawn: #{names}."
  end

  defp square!(value, _statement) when is_integer(value) and value in 0..31, do: value

  defp square!(other, statement) do
    raise CompileError, """
    background square outside the map: #{Macro.to_string(other)}

        #{one_line(statement)}

    The map is 32 by 32, and the column and the row are literals -- the address \
    is worked out here rather than by the console. The screen shows the first \
    20 columns and 18 rows of it; past that a square is real but off-view until \
    the game scrolls.
    """
  end

  # `digit:` is `tile:` with the font's base added, and it is worth its own word:
  # a game says what it means -- "the digit three" -- and never learns that the
  # kernel put its font at tile 2.
  defp background_field!([tile: value], _statement), do: {:tile, value}
  defp background_field!([digit: value], _statement), do: {:digit, value}

  defp background_field!(fields, statement) do
    raise CompileError, """
    malformed `background`: #{Macro.to_string(fields)}

        #{one_line(statement)}

    A square takes exactly one of the two, a literal or a variable:

        background(2, 1, digit: score)   the digit, the kernel's font
        background(0, 0, tile: 0)        a tile index, whatever it holds
    """
  end

  # Without an `else`, the false branch already lands on the end label and there
  # is nothing to emit. With one, the taken branch has to jump over it.
  defp else_tail(:none, _otherwise, done, _allocation, counter) do
    {[{:label, done}], counter}
  end

  defp else_tail(body, otherwise, done, allocation, counter) do
    {elements, counter} = block(body, allocation, counter)

    {[{:jp, {:label, done}}, {:label, otherwise}] ++ elements ++ [{:label, done}], counter}
  end

  # ── The conditions ──────────────────────────────────────────────────────────
  #
  # A condition emits its test plus the jumps that reach `otherwise` when it is
  # **false**. Saying it that way rather than "jump when true" is what lets an
  # `if` with and without an `else` share one shape: `otherwise` is the end label
  # in the first case and the else label in the second, and nothing else changes.

  defp condition!({:pressed?, _, [_key]} = condition, otherwise, _allocation, statement, counter) do
    bit = key!(condition, statement)

    {[
       {:ld, :a, {:mem, Runtime.pad()}},
       {:bit, bit, :a},
       {:jp, :z, {:label, otherwise}}
     ], counter}
  end

  # Bit 7 *is* the sign, so the question the SM83 already answers is the one the
  # language asks. `BIT 7, A` sets Z when the bit is clear -- that is, when the
  # value is not negative -- and Z is exactly the jump away from the body.
  defp condition!(
         {:negative?, _, [{name, _, context}]},
         otherwise,
         allocation,
         statement,
         counter
       )
       when is_atom(name) and is_atom(context) do
    {[
       {:ld, :a, {:mem, cell!(name, allocation, statement)}},
       {:bit, 7, :a},
       {:jp, :z, {:label, otherwise}}
     ], counter}
  end

  # `touching?(:wall, x, y)`: which tile of the current room the pixel (x, y)
  # stands on, against the one named. The kernel does the arithmetic -- room
  # bytes are read from ROM, not from the map, so nothing a `text` scribbled
  # becomes an obstacle -- and answers in the Z flag, which makes this exactly
  # the shape `pressed?` already has.
  #
  # The pixel is taken to be on screen. Off it, the arithmetic lands on some
  # other cell of the room and answers about that -- there is no room in a
  # frame to range-check what the game can keep in bounds itself.
  defp condition!({:touching?, _, [tile, x, y]}, otherwise, allocation, statement, counter) do
    index = tile!(tile, allocation, statement)

    {[{:ld, :a, index}, {:ld, {:mem, Runtime.probe_cell()}, :a}] ++
       sprite_value(x, 0, allocation, statement) ++
       [{:ld, :c, :a}] ++
       sprite_value(y, 0, allocation, statement) ++
       [
         {:call, {:label, :touching}},
         {:jp, :nz, {:label, otherwise}}
       ], counter}
  end

  defp condition!({op, _, [left, right]}, otherwise, allocation, statement, counter)
       when op in [:==, :!=, :<, :>, :<=, :>=] do
    if op in [:<, :>, :<=, :>=], do: unsigned!(right, statement)
    {setup, operand} = term(right, allocation, statement)
    {jumps, counter} = skip_unless(op, otherwise, allocation, counter)

    left = load(left, allocation, statement)

    {left ++ keep_a(setup, right) ++ [{:cp, :a, operand}] ++ jumps, counter}
  end

  # `and` is free, and that is not a turn of phrase: a condition already emits
  # the jumps that leave for `otherwise` when it is false, so two of them, one
  # after the other, leave for `otherwise` when *either* is false. Nothing is
  # added and nothing is inverted -- the concatenation is the whole
  # implementation, and the bytes are the same the nested ifs it replaces
  # produced.
  #
  # It nests by construction: `a and b and c` parses as `(a and b) and c`, and
  # either side of this clause may be any condition, including another one.
  defp condition!({:and, _, [left, right]}, otherwise, allocation, statement, counter) do
    {first, counter} = condition!(left, otherwise, allocation, statement, counter)
    {second, counter} = condition!(right, otherwise, allocation, statement, counter)

    {first ++ second, counter}
  end

  # `or` costs one jump, and it is the only shape that has to invert a test the
  # rest of this module states in one direction.
  #
  # Rather than write a second table of flags -- the complement of every one in
  # `skip_unless/4`, where `>` and `<=` are already two jumps and would become
  # awkward -- the inversion is spelled by jumping over a jump. The left
  # condition leaves for `next` when it is false; falling through it means it
  # was true, and the body is entered directly. `next` is where the right
  # condition gets its turn, and that one leaves for `otherwise` as usual.
  #
  # Three bytes, and no flag is reasoned about twice.
  defp condition!({:or, _, [left, right]}, otherwise, allocation, statement, counter) do
    next = label(allocation, "or_next", counter)
    body = label(allocation, "or_body", counter + 1)

    {first, counter} = condition!(left, next, allocation, statement, counter + 2)
    {second, counter} = condition!(right, otherwise, allocation, statement, counter)

    {first ++
       [{:jp, {:label, body}}, {:label, next}] ++
       second ++ [{:label, body}], counter}
  end

  defp condition!(condition, _otherwise, _allocation, statement, _counter) do
    reject_condition!(condition, statement)
  end

  # An ordering against a negative literal is refused rather than emitted.
  #
  # `CP` is an unsigned subtraction, and the SM83 has no overflow flag: there is
  # no ordering that reads 0xFF as -1 without biasing both sides by 0x80 first.
  # Emitting that quietly would make `vx < 0` and `vx < 1` two different
  # orderings of the same byte, and the plain reading -- unsigned -- would turn
  # `vx < 0` into "never". So the v0 keeps one ordering, the console's, and hands
  # the sign its own question.
  #
  # `==` and `!=` are let through: equality does not order anything, and 0xFF is
  # 0xFF under either reading.
  defp unsigned!(right, statement) do
    case fold(right) do
      {:ok, value} when value < 0 ->
        raise CompileError, """
        ordering against a negative literal: #{Macro.to_string(right)}

            #{one_line(statement)}

        A comparison in Potion is the console's: `CP` subtracts without a sign, \
        and no byte is below zero that way -- this would compile to a branch \
        never taken. What the hardware does answer, in one instruction, is \
        whether the sign bit is set:

            if negative?(vx), do: vx = 1

        `==` and `!=` take a negative literal as they stand: 0xFF is 0xFF \
        whichever way it is read.
        """

      _ ->
        :ok
    end
  end

  # `CP n` is a subtraction whose result is thrown away: Z says the two were
  # equal, C says A was the smaller. Four of the six comparisons are therefore
  # one jump; `>` needs two, since it must rule out both equality and the
  # borrow; and `<=` is the only one that jumps *into* the body, because "C or
  # Z" cannot be spelled by jumping away from it.
  #
  # Every jump that leaves for `otherwise` is a JP and not a JR, and that is the
  # rule rather than a local choice: `otherwise` sits past the body, the body is
  # whatever the game wrote, and a relative jump reaches 127 bytes. Pong's ball
  # found the cliff at 152 -- a collision, the offset it was struck at, and two
  # ladders of four speeds. Nothing about that block is extravagant, and the
  # failure it produced named an assembler the author of the game has no reason
  # to have heard of.
  #
  # It costs one byte and four cycles per taken jump. Choosing JR when it fits
  # and JP when it does not would cost neither, and wants an assembler that
  # relaxes branches -- sizes depend on distances which depend on sizes, so it
  # iterates to a fixed point. That is worth doing the day a frame is short of
  # cycles. It is not worth a cliff at 127 bytes in the meantime.
  #
  # `below` is the exception that proves the rule: it is the compiler's own
  # label, three bytes ahead, and no game can move it.
  defp skip_unless(:==, otherwise, _allocation, counter),
    do: {[{:jp, :nz, {:label, otherwise}}], counter}

  defp skip_unless(:!=, otherwise, _allocation, counter),
    do: {[{:jp, :z, {:label, otherwise}}], counter}

  defp skip_unless(:<, otherwise, _allocation, counter),
    do: {[{:jp, :nc, {:label, otherwise}}], counter}

  defp skip_unless(:>=, otherwise, _allocation, counter),
    do: {[{:jp, :c, {:label, otherwise}}], counter}

  defp skip_unless(:>, otherwise, _allocation, counter) do
    {[{:jp, :c, {:label, otherwise}}, {:jp, :z, {:label, otherwise}}], counter}
  end

  defp skip_unless(:<=, otherwise, allocation, counter) do
    below = label(allocation, "below", counter)

    {[
       {:jr, :c, {:label, below}},
       {:jp, :nz, {:label, otherwise}},
       {:label, below}
     ], counter + 1}
  end

  # One byte of OAM: the value, shifted by the hardware offset. On a literal the
  # shift happens here — the processor need not add what the compiler already
  # knows. On a variable it costs two bytes, and it wraps like everything else.
  defp field(source, offset, address, allocation, statement) do
    load = sprite_value(source, offset, allocation, statement)
    load ++ [{:ld, {:mem, address}, :a}]
  end

  defp sprite_value(literal, offset, _allocation, _statement) when is_integer(literal) do
    [{:ld, :a, Integer.mod(literal + offset, 0x100)}]
  end

  defp sprite_value({name, _, context}, offset, allocation, statement)
       when is_atom(name) and is_atom(context) do
    load = [{:ld, :a, {:mem, cell!(name, allocation, statement)}}]
    if offset == 0, do: load, else: load ++ [{:add, :a, offset}]
  end

  # A cell of an array drives a sprite the same way a lone cell does, which is
  # the point of arrays existing: a pool of bullets is a pool of positions, and
  # a position that could not reach the OAM would be half a feature.
  defp sprite_value({{:., _, [Access, :get]}, _, [array, index]}, offset, allocation, statement) do
    {setup, operand} = indexed(array, index, allocation, statement)
    load = setup ++ [{:ld, :a, operand}]

    if offset == 0, do: load, else: load ++ [{:add, :a, offset}]
  end

  defp sprite_value(other, _offset, _allocation, statement) do
    raise CompileError, """
    `sprite` field outside the v0 subset:

        #{Macro.to_string(other)}

    Rejected AST: #{inspect(other)}

    In #{one_line(statement)}, `x:`, `y:` and `tile:` take a declared variable, \
    a cell of an array, or a literal from 0 to 255. A computation happens \
    before, in a variable.
    """
  end

  # ── The right-hand side of an assignment ────────────────────────────────────

  defp load(literal, _allocation, statement) when is_integer(literal) do
    [{:ld, :a, byte!(literal, statement)}]
  end

  defp load({name, _, context}, allocation, statement)
       when is_atom(name) and is_atom(context) do
    [{:ld, :a, {:mem, cell!(name, allocation, statement)}}]
  end

  defp load({{:., _, [Access, :get]}, _, [array, index]}, allocation, statement) do
    {setup, operand} = indexed(array, index, allocation, statement)
    setup ++ [{:ld, :a, operand}]
  end

  defp load({:-, _, [literal]}, _allocation, statement) when is_integer(literal) do
    [{:ld, :a, byte!(-literal, statement)}]
  end

  # `vx = -vx`, the sentence a bounce is made of. Two's complement is a flip and
  # a step: CPL turns 1 into 0xFE, INC A makes it 0xFF. Zero is the one value
  # that comes back unchanged, which is what "not moving, the other way" ought
  # to mean.
  #
  # The clause is written on any expression, not on a variable, so `x = -(y + 1)`
  # negates what the rest of the compiler just put in A -- there is nothing to
  # special-case.
  defp load({:-, _, [operand]}, allocation, statement) do
    load(operand, allocation, statement) ++ [{:cpl}, {:inc, :a}]
  end

  defp load({operator, _, [left, right]}, allocation, statement)
       when operator in [:+, :-] do
    {setup, operand} = term(right, allocation, statement)

    load(left, allocation, statement) ++
      keep_a(setup, right) ++ [{arithmetic(operator), :a, operand}]
  end

  defp load(other, _allocation, _statement), do: reject!(other)

  # The left-hand value is already in A when the right-hand operand is set up,
  # and setting up a cell of an array reads its index into A. Two bytes so that
  # `bx[me] > by[n]` means what it says; a plain cell only loads HL and needs
  # none of this.
  defp keep_a(setup, right) do
    if match?({{:., _, [Access, :get]}, _, _}, right) do
      [{:push, :af}] ++ setup ++ [{:pop, :af}]
    else
      setup
    end
  end

  defp arithmetic(:+), do: :add
  defp arithmetic(:-), do: :sub

  # The second term of an arithmetic or a comparison: a literal, or a variable
  # reached through HL.
  #
  # A is already carrying the first operand by the time this runs, and the SM83
  # loads a byte from an arbitrary address into A and nowhere else. So the second
  # operand cannot come to A -- A has to go to it, and HL is the only register
  # that addresses memory for the ALU. `LD HL, addr` then `ADD A, (HL)`: one more
  # instruction than a literal, which is the whole cost of the register policy
  # this used to say it lacked.
  #
  # HL is free to clobber. The kernel keeps nothing in it across its `CALL` to
  # the actor, and the vblank handler pushes all four pairs before touching
  # anything -- so an interrupt landing between the `LD HL` and the `ADD` hands
  # it back untouched.
  defp term({{:., _, [Access, :get]}, _, [array, index]}, allocation, statement) do
    indexed(array, index, allocation, statement)
  end

  defp term({name, _, context}, allocation, statement)
       when is_atom(name) and is_atom(context) do
    {[{:ld, :hl, cell!(name, allocation, statement)}], {:mem, :hl}}
  end

  defp term(other, _allocation, statement) do
    case fold(other) do
      {:ok, _} -> {[], byte!(other, statement)}
      :error -> term_rejected!(other, statement)
    end
  end

  defp term_rejected!(other, statement) do
    raise CompileError, """
    operand outside the subset:

        #{Macro.to_string(other)}

    Rejected AST: #{inspect(other)}

    In #{one_line(statement)}, this place takes a variable or an integer literal \
    from -128 to 255 — `x = y + speed` as readily as `x = y + 3`. What it does \
    not take is another computation: one operation per sentence, and a variable \
    to hold the middle of a longer one.
    """
  end

  defp byte!(other, statement) do
    case fold(other) do
      {:ok, value} when value in -128..255 ->
        two_complement(value)

      _ ->
        raise CompileError, """
        value outside a byte: #{inspect(other)}

            #{one_line(statement)}

        A Potion variable holds one byte, and so does every literal it meets: \
        -128 to 255, the same 256 values read two ways. Past that the value \
        would not fit where it is going, and the wrap would be the compiler's \
        doing rather than the game's.
        """
    end
  end

  # ── The sign ────────────────────────────────────────────────────────────────
  #
  # Elixir does not fold a unary minus in a quoted block: `-1` arrives as
  # `{:-, _, [1]}`, an operator applied to a literal. Folding it here is the one
  # place the language reads an integer out of an AST, and every literal in the
  # compiler goes through it -- which is why a negative works in `variables`, in
  # an assignment and on the right of a `+` without three separate decisions.
  defp fold(value) when is_integer(value), do: {:ok, value}
  defp fold({:-, _, [value]}) when is_integer(value), do: {:ok, -value}
  defp fold(_other), do: :error

  defp two_complement(value) when value < 0, do: value + 0x100
  defp two_complement(value), do: value

  # ── The cell of a variable ──────────────────────────────────────────────────

  # A case of an array, as an address. Two shapes, and which one comes out is
  # the whole of what indexing costs.
  #
  # A literal index is arithmetic the compiler can do itself, so `bullets[2]` is
  # an address and nothing is emitted at all. A cell index is a sixteen-bit add:
  # the index into L, zero into H, the base into BC, `ADD HL, BC`.
  #
  # Three bytes more than adding the index to L would cost, and today they buy
  # nothing -- the actor page is 0xC100-0xC1FF, so every array sits inside one
  # page and a byte add would never lose a carry. They are spent because that
  # page is 256 bytes for one reason, `@state_page`, and WRAM runs to the stack
  # at 0xDFFF: the day an actor wants more than a page, a byte add starts
  # wrapping arrays onto themselves and nothing says so. A test pins the add for
  # the same reason, since no game today can make it fail.
  #
  # HL is free to clobber for the same reason `term/3` says: the kernel keeps
  # nothing in it across its `CALL`, and the vblank handler pushes all four
  # pairs before touching anything.
  defp indexed(array, index, allocation, statement) do
    {name, base, length} = array!(array, allocation, statement)

    case fold(index) do
      {:ok, offset} when offset >= 0 and offset < length ->
        {[], {:mem, base + offset}}

      {:ok, offset} ->
        raise CompileError, """
        #{inspect(name)} has #{length} cells, and this asks for number #{offset}.

            #{one_line(statement)}

        They are numbered from zero, so the last one is #{length - 1}. An index \
        held in a cell is not checked -- there is no room in a frame to check it \
        -- but one written out is.
        """

      :error ->
        {[
           {:ld, :a, {:mem, cell!(index, allocation, statement)}},
           {:ld, :l, :a},
           {:ld, :h, 0},
           {:ld, :bc, base},
           {:add, :hl, :bc}
         ], {:mem, :hl}}
    end
  end

  defp array!({name, _, context}, allocation, statement)
       when is_atom(name) and is_atom(context) do
    case Map.fetch(Map.get(allocation, :arrays, %{}), name) do
      {:ok, length} ->
        {name, Map.fetch!(allocation.cells, name), length}

      :error ->
        known =
          allocation
          |> Map.get(:arrays, %{})
          |> Map.keys()
          |> Enum.sort()
          |> Enum.map_join(", ", &inspect/1)

        raise CompileError, """
        #{inspect(name)} is not an array, so it has no numbered cells.

            #{one_line(statement)}

        #{if known == "", do: "This game declares none.", else: "The arrays it has: #{known}."}

        An array is declared by writing its cells out:

            variables bullets: [0, 0, 0, 0]
        """
    end
  end

  defp array!(other, _allocation, statement) do
    raise CompileError, """
    only a name can be indexed: #{Macro.to_string(other)}

        #{one_line(statement)}
    """
  end

  defp cell!({name, _, context}, allocation, statement)
       when is_atom(name) and is_atom(context) do
    cell!(name, allocation, statement)
  end

  defp cell!(name, _allocation, _statement) when name in [:me, :__me__], do: Runtime.me()

  defp cell!(name, allocation, statement) when is_atom(name) do
    case allocation.cells do
      %{^name => address} ->
        address

      _ ->
        raise CompileError, """
        undeclared variable: #{inspect(name)}, in #{one_line(statement)}

        #{declared(allocation)}

        A Potion variable does not spring into being by being written: it is a \
        cell of WRAM, and it is `variables` that decides where. Add it:

            variables #{name}: 0
        """
    end
  end

  defp cell!(other, _allocation, statement) do
    raise CompileError, """
    assignment target that is not a variable:

        #{Macro.to_string(other)}

    Rejected AST: #{inspect(other)}

    In #{one_line(statement)}, the left-hand side of an `=` must be the name of a \
    variable declared by `variables`. The v0 has no pattern matching, no \
    structures and no bindings — an `=` is a write into a cell.
    """
  end

  defp declared(%{order: []}), do: "This game declares no variables."

  defp declared(%{order: names, cells: cells}) do
    "Declared: " <>
      Enum.map_join(names, ", ", fn name -> "#{inspect(name)} (0x#{hex(cells[name])})" end)
  end

  # ── The key of an `if` ──────────────────────────────────────────────────────

  defp key!({:pressed?, _, [key]}, statement) when is_atom(key) do
    case Keyword.fetch(@keys, key) do
      {:ok, bit} ->
        bit

      :error ->
        raise CompileError, """
        unknown key: #{inspect(key)}, in #{one_line(statement)}

        A Game Boy pad has eight of them, and the kernel files them into a byte:
        #{Enum.map_join(@keys, "\n", fn {name, bit} -> "  #{inspect(name)} — bit #{bit}" end)}
        """
    end
  end

  defp reject_condition!(condition, statement) do
    raise CompileError, """
    condition outside the subset:

        #{Macro.to_string(condition)}

    Rejected AST: #{inspect(condition)}

    In #{one_line(statement)}, a condition is a pad key, the sign of a variable,
    or a variable weighed against a byte:

        if pressed?(:right), do: ...
        if negative?(vx), do: ...
        if y > 140, do: y = 0
        if lives == 0, do: ..., else: ...

    The comparisons are ==, !=, <, >, <= and >=, with the variable on the left.
    `negative?` takes a declared variable and nothing else -- it is one `BIT 7`,
    and there is no address to read a literal's sign from.
    """
  end

  defp if_bodies!(blocks, statement) do
    case blocks do
      [do: body] ->
        {body, :none}

      [do: body, else: otherwise] ->
        {body, otherwise}

      others when is_list(others) ->
        raise CompileError, """
        branch that does not compile: \
        #{Enum.map_join(Keyword.keys(others) -- [:do, :else], ", ", &inspect/1)}

            #{one_line(statement)}

        An `if` carries a `do:` and, at most, an `else:`.
        """

      other ->
        raise CompileError, """
        malformed `if`:

            #{Macro.to_string(other)}

        Rejected AST: #{inspect(other)}

        The form is `if pressed?(:right), do: x = x + 1`, or the same with a \
        `do ... end` block.
        """
    end
  end

  # ── The OAM entry and its fields ────────────────────────────────────────────

  defp entry!(index, _statement)
       when is_integer(index) and index in 0..(@oam_entries - 1)//1 do
    index
  end

  defp entry!(index, statement) when is_integer(index) do
    raise CompileError, """
    OAM entry out of range: #{index}, in #{one_line(statement)}

    A Game Boy's OAM holds #{@oam_entries} entries, numbered 0 to \
    #{@oam_entries - 1} — four bytes each, from \
    0x#{hex(Runtime.oam_mirror())} to \
    0x#{hex(Runtime.oam_mirror() + 4 * @oam_entries - 1)} in the kernel's mirror.

    Entry #{index} would land outside that range, so the DMA would never publish \
    it: it would overwrite the kernel's cells — the pad cell is at \
    0x#{hex(Runtime.pad())} — or the actor's state.
    """
  end

  defp entry!(other, statement) do
    raise CompileError, """
    sprite number that is not a literal:

        #{Macro.to_string(other)}

    Rejected AST: #{inspect(other)}

    In #{one_line(statement)}, the first argument of `sprite` must be an integer \
    written on the spot, from 0 to #{@oam_entries - 1}: it is what gives the \
    address of the entry in the mirror, and that address is decided at compile \
    time. A sprite chosen at run time would require an indexing the v0 does not \
    have.
    """
  end

  @fields [:x, :y, :tile]

  defp fields!(fields, statement) when is_list(fields) do
    with true <- Keyword.keyword?(fields),
         [] <- Enum.sort(Keyword.keys(fields)) -- Enum.sort(@fields),
         [] <- Enum.sort(@fields) -- Enum.sort(Keyword.keys(fields)),
         [] <- Keyword.keys(fields) -- Enum.uniq(Keyword.keys(fields)) do
      {fields[:x], fields[:y], fields[:tile]}
    else
      _ -> fields_rejected!(fields, statement)
    end
  end

  defp fields!(fields, statement), do: fields_rejected!(fields, statement)

  defp fields_rejected!(fields, statement) do
    raise CompileError, """
    malformed `sprite` fields:

        #{Macro.to_string(fields)}

    Rejected AST: #{inspect(fields)}

    In #{one_line(statement)}, `sprite` expects exactly `x:`, `y:` and `tile:` \
    — each once. The attributes are zeroed by the compiler: the v0 has only one \
    object palette, and neither mirroring nor priority.
    """
  end

  # ── The general refusal ─────────────────────────────────────────────────────

  defp reject!(statement) do
    raise CompileError, """
    statement outside the v0 subset:

        #{Macro.to_string(statement)}

    Rejected AST: #{inspect(statement)}

    Inside `every_frame`, the v0 compiles exactly this:

        x = 5              a constant into a cell
        x = y              one cell into another
        x = x + 1          8-bit arithmetic, which wraps
        x = y - 3          the same, the other way
        x = x + step       a second cell, reached through HL
        vx = -1            a negative literal, in two's complement
        vx = -vx           and the sentence that turns a ball around

        if pressed?(:right), do: x = x + 1
        if negative?(vx), do: vx = 1
        if pressed?(:a) do
          x = x + 1
          y = y - 1
        end

        sprite(0, x: x, y: y, tile: 0)

    The surface is Elixir; the semantics are the console's. What does not \
    translate into a handful of SM83 instructions does not compile — not yet.
    """
  end

  # The offending statement, brought back to a single line: in an `if` unfolded
  # over five lines, the message would take up half the screen.
  defp one_line(statement) do
    statement
    |> Macro.to_string()
    |> String.split("\n")
    |> case do
      [single] -> "`#{single}`"
      [first | _] -> "`#{first} …`"
    end
  end

  defp hex(value), do: value |> Integer.to_string(16) |> String.pad_leading(4, "0")
end
