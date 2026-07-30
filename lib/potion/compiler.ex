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
  compile because the SM83 has no multiplication; `x = x + y` does not compile
  because memory-to-memory addition requires saving A or using HL, and the v0 has
  no register policy. The second will come back; the first will become a loop of
  additions the day the language knows how to write one.

  ## The generated labels

  All prefixed `potion_` and numbered. The kernel places `:actor` right before
  the fragment and never touches it again; this prefix keeps the two namespaces
  disjoint, which the assembler would check anyway — it refuses a duplicate
  label.
  """

  alias Potion.Assembler
  alias Potion.CompileError
  alias Potion.Runtime

  @typedoc """
  Where the actor's state lives: one cell per variable, plus the flag.
  """
  @type allocation :: %{
          cells: %{atom() => non_neg_integer()},
          order: [atom()],
          initial: %{atom() => byte()},
          installed: non_neg_integer()
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
  """
  @spec allocate(keyword()) :: allocation()
  def allocate(declarations) do
    list = declarations!(declarations)
    names = Keyword.keys(list)

    duplicates!(names, declarations)
    capacity!(names, declarations)

    cells =
      names
      |> Enum.with_index()
      |> Map.new(fn {name, rank} -> {name, Runtime.actor_state() + rank} end)

    %{
      cells: cells,
      order: names,
      initial: Map.new(list),
      installed: Runtime.actor_state() + length(names)
    }
  end

  defp declarations!(declarations) when is_list(declarations) do
    Enum.each(declarations, fn
      {name, value} when is_atom(name) and is_integer(value) and value in 0..255 ->
        :ok

      {name, value} when is_atom(name) ->
        raise CompileError, """
        initial value outside a byte, in `variables`: #{inspect(name)}

            #{Macro.to_string(value)}

        Rejected AST: #{inspect(value)}

        A Potion variable is a cell of WRAM: its initial value is an integer \
        literal from 0 to 255. It is laid down as it stands on the first turn, \
        with no computation — there is nobody to compute anything before the \
        actor runs.
        """

      other ->
        raise CompileError, """
        malformed declaration in `variables`: #{inspect(other)}

        `variables` expects a keyword list, each name receiving one byte:

            variables x: 80, y: 72
        """
    end)

    declarations
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

  defp capacity!(names, declarations) do
    if length(names) + 1 > @state_page do
      raise CompileError, """
      too many variables: #{length(names)} declared, #{@state_page - 1} at most.

          #{Macro.to_string(declarations)}

      The kernel leaves the actor page 0x#{hex(Runtime.actor_state())}-0x#{hex(Runtime.actor_state() + @state_page - 1)}, \
      that is #{@state_page} cells, one of which holds the "installed" flag.
      """
    end
  end

  # ══ The compilation ══════════════════════════════════════════════════════════

  @doc """
  The AST of an `every_frame` body plus an allocation, into an actor fragment.

  The fragment ends with `{:ret}`: it is a `CALL` that reaches it, once per
  frame, and `Potion.Runtime.program/1` refuses an actor that would not hand
  control back.
  """
  @spec compile(Macro.t(), allocation()) :: [Assembler.element()]
  def compile(body, allocation) do
    {compiled, _counter} = block(body, allocation, 0)
    install(allocation) ++ compiled ++ [{:ret}]
  end

  # The first turn: lay down the initial values, then never come back to them.
  # With no variables there is nothing to install, and the flag stays an inert
  # cell — we do not emit six bytes to keep a state nobody wants.
  defp install(%{order: []}), do: []

  defp install(allocation) do
    [
      {:ld, :a, {:mem, allocation.installed}},
      {:and, :a, :a},
      {:jr, :nz, {:label, :potion_installed}},
      {:ld, :a, 0x01},
      {:ld, {:mem, allocation.installed}, :a}
    ] ++
      Enum.flat_map(allocation.order, fn name ->
        [
          {:ld, :a, allocation.initial[name]},
          {:ld, {:mem, allocation.cells[name]}, :a}
        ]
      end) ++
      [{:label, :potion_installed}]
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

  defp statement({:=, _, [target, expression]} = statement, allocation, counter) do
    address = cell!(target, allocation, statement)
    {load(expression, allocation, statement) ++ [{:ld, {:mem, address}, :a}], counter}
  end

  # ── A condition on the pad ──────────────────────────────────────────────────

  defp statement({:if, _, [condition, blocks]} = statement, allocation, counter) do
    bit = key!(condition, statement)
    body = if_body!(blocks, statement)
    done = :"potion_end_#{counter}"
    {inner, counter} = block(body, allocation, counter + 1)

    elements =
      [
        {:ld, :a, {:mem, Runtime.pad()}},
        {:bit, bit, :a},
        {:jr, :z, {:label, done}}
      ] ++ inner ++ [{:label, done}]

    {elements, counter}
  end

  # ── An OAM entry ────────────────────────────────────────────────────────────

  defp statement({:sprite, _, [index, fields]} = statement, allocation, counter) do
    base = Runtime.oam_mirror() + 4 * entry!(index, statement)
    {x, y, tile} = fields!(fields, statement)

    elements =
      field(y, 16, base, allocation, statement) ++
        field(x, 8, base + 1, allocation, statement) ++
        field(tile, 0, base + 2, allocation, statement) ++
        [{:xor, :a, :a}, {:ld, {:mem, base + 3}, :a}]

    {elements, counter}
  end

  defp statement(other, _allocation, _counter), do: reject!(other)

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

  defp sprite_value(other, _offset, _allocation, statement) do
    raise CompileError, """
    `sprite` field outside the v0 subset:

        #{Macro.to_string(other)}

    Rejected AST: #{inspect(other)}

    In #{one_line(statement)}, `x:`, `y:` and `tile:` take a declared variable \
    or a literal from 0 to 255. A computation happens before, in a variable.
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

  defp load({operator, _, [left, right]}, allocation, statement)
       when operator in [:+, :-] do
    load(left, allocation, statement) ++
      [{arithmetic(operator), :a, byte!(right, statement)}]
  end

  defp load(other, _allocation, _statement), do: reject!(other)

  defp arithmetic(:+), do: :add
  defp arithmetic(:-), do: :sub

  # The right-hand term of a `+` or a `-`: a literal, never a variable. A
  # memory-to-memory addition would require keeping one operand somewhere while
  # the other is loaded, hence a register policy, hence a compiler of another
  # calibre.
  defp byte!(value, _statement) when is_integer(value) and value in 0..255, do: value

  defp byte!(other, statement) do
    raise CompileError, """
    operand outside the v0 subset:

        #{Macro.to_string(other)}

    Rejected AST: #{inspect(other)}

    In #{one_line(statement)}, only an integer literal from 0 to 255 is accepted \
    in this place. The v0 compiles `x = 5`, `x = y`, `x = x + 1` and `x = y - 3` \
    — a variable, a sign, a constant.
    """
  end

  # ── The cell of a variable ──────────────────────────────────────────────────

  defp cell!({name, _, context}, allocation, statement)
       when is_atom(name) and is_atom(context) do
    cell!(name, allocation, statement)
  end

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

  defp key!(condition, statement) do
    raise CompileError, """
    condition outside the v0 subset:

        #{Macro.to_string(condition)}

    Rejected AST: #{inspect(condition)}

    In #{one_line(statement)}, `if` only tests a pad key, in the form \
    `if pressed?(:right), do: ...`. The v0 has no comparison; the pad is the \
    only outside world an actor can question.
    """
  end

  defp if_body!(blocks, statement) do
    case blocks do
      [do: body] ->
        body

      others when is_list(others) ->
        raise CompileError, """
        branch the v0 does not compile: \
        #{Enum.map_join(Keyword.keys(others) -- [:do], ", ", &inspect/1)}

            #{one_line(statement)}

        A v0 `if` has only a `do:` — no `else:`. The opposite case is written \
        with a second `if` on another key, until the language knows how to jump \
        over two blocks.
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

        if pressed?(:right), do: x = x + 1
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
