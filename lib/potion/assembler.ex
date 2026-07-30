defmodule Potion.Assembler do
  @moduledoc """
  The SM83 instruction table, read backwards.

  ## Why there is not a single encoding in this file

  `Atomboy.CPU.Table` describes the 500 instructions of the processor: for each
  one, its opcode, its prefix and the shape of its operands. The decoder derives
  function clauses from it; this assembler derives a **reverse index** — from
  `{mnemonic, condition, operand shapes}` to `{prefix, opcode}`.

  It is the only choice that guarantees what Potion needs. An assembler that
  copied the encodings by hand would be a second table, to be kept in agreement
  with the first; and any divergence would show up not as a compile error but as
  a ROM that *runs* while doing something other than what is written. By
  deriving, the agreement is structural: every decodable instruction is
  assemblable, with the same bytes, and the round-trip test checks that across
  all 500.

  The index key *is* the list of operand templates — there is no intermediate
  normalisation. What remains to be done, and it is all this module does, is to
  go from source syntax (`{:ld, :a, {:mem, :hl}}`, written for the human hand)
  to that form (`[{:reg, :a}, :hl_ind]`, written for the silicon).

  ## Two passes, and why they are enough

  On the SM83 no instruction size depends on a distance: an opcode, plus the
  prefix byte where applicable, plus its immediates, all of fixed width. Every
  element therefore knows its size before any address is resolved.

  Pass 1 walks the program summing sizes and notes where each label falls; pass
  2 walks it again and emits the bytes, the targets now being known. Without
  that property a fixed point would be needed — a distant branch takes more
  room, which pushes the following targets further away, which lengthens other
  branches. The SM83 spares us that.

  The invariant that locks the two passes together — *the number of bytes
  emitted in pass 2 is exactly the size announced in pass 1* — is checked on
  every assembly, not only in the tests: a ROM of unexpected length runs all the
  same, and gives wrong results.

  ## The source format

  A program is a list. Three kinds of element:

      {:label, :main_loop}      zero size; names the current address
      {:bytes, <<1, 2, 3>>}     raw bytes — data, tiles
      {:ld, :a, {:mem, :hl}}     an instruction

  An instruction is a tuple whose head is the mnemonic **exactly** as the table
  names it (`:ld`, `:ldh`, `:add_sp`, `:jr`, `:rst`, `:bit`…). For the
  conditional forms the condition comes first: `{:jr, :nz, {:label, :done}}`,
  `{:ret, :c}`.

  The operands:

      :a … :l                  an 8-bit register
      :bc :de :hl :sp :af      a 16-bit pair
      0x12 / 0x1234            an immediate, width deduced from the table
      {:mem, :hl}              the byte at address HL
      {:mem, :bc | :de | :hl_inc | :hl_dec}
      {:mem, 0xC000}           the byte at an absolute address
      {:mem, {:label, :n}} same, the address coming from a label
      {:high, 0x44}            the high page: 0xFF00 + 0x44
      {:high, :c}              the high page via C
      {:label, :n}         the target of a jump or a call

  The accumulator is **explicit** in the arithmetic operations, as it is in the
  table: `{:add, :a, :b}`, `{:sub, :a, 0x10}`, `{:cp, :a, {:mem, :hl}}`. The
  table spells A out because the processor reads it and writes it; the classic
  assembler leaves it out (`SUB B`), and it is the classic assembler that is
  irregular.

  ## What the assembler deduces, and what it demands

  The width of an immediate is never written: `{:ld, :a, 0x12}` is a byte,
  `{:ld, :hl, 0x1234}` a word, because the table knows only one form in each
  case. The index decides, and it cannot be wrong — if two competing forms
  existed for the same mnemonic, the round-trip test would fail.

  The value, on the other hand, is checked: out of range, assembly stops. A
  silent truncation would produce a plausible, wrong ROM, which costs far more
  than an error message.
  """

  import Bitwise

  alias Atomboy.CPU.Insn
  alias Atomboy.CPU.Table

  @typedoc """
  A source operand, in the syntax readable by the human hand.
  """
  @type operand ::
          atom()
          | integer()
          | {:mem, atom() | non_neg_integer() | {:label, atom()}}
          | {:high, :c | non_neg_integer() | {:label, atom()}}
          | {:label, atom()}

  @typedoc """
  A program element: a label, raw bytes, or an instruction.
  """
  @type element :: {:label, atom()} | {:bytes, binary()} | tuple()

  # 0x0150: the first free address after the cartridge header. That is where the
  # entry point jumps, and therefore the default origin of a Potion program.
  @default_origin 0x0150

  # The reverse index, built at compile time from the table. Key: the shape of
  # the instruction as the table describes it. Value: what it takes to write it.
  # The operand templates are not stored in the value — they are already in the
  # key, and two copies of one truth are one too many.
  @index (for %Insn{} = insn <- Table.all(), into: %{} do
            {{insn.mnemonic, insn.condition, insn.operands}, {insn.prefix, insn.opcode}}
          end)

  # If two instructions shared a key, `into: %{}` would silently lose one and
  # the corresponding encoding would become unreachable. The day the table gains
  # a family, this is where it breaks — at compile time, not in a ROM.
  if map_size(@index) != length(Table.all()) do
    raise "degenerate reverse index: #{length(Table.all())} instructions for " <>
            "#{map_size(@index)} {mnemonic, condition, operands} keys"
  end

  @mnemonics Table.all() |> Enum.map(& &1.mnemonic) |> Enum.uniq() |> Enum.sort()

  # The only two mnemonics whose 8-bit immediate is signed: JR counts a
  # distance, ADD SP a stack displacement. Everywhere else a byte is a byte.
  @signed [:jr, :add_sp]

  @doc """
  Assembles a program into bytes.

  `opts[:origin]` is the address of the first instruction — needed to resolve
  labels, which name absolute addresses and not offsets. Defaults to 0x0150.

      iex> Potion.Assembler.assemble([{:ld, :a, 0x05}, {:add, :a, :b}])
      <<0x3E, 0x05, 0x80>>
  """
  @spec assemble([element()], keyword()) :: binary()
  def assemble(program, opts \\ []) do
    origin = Keyword.get(opts, :origin, @default_origin)
    {plan, labels, size} = measure(program, origin)
    bytes = plan |> Enum.map(&emit(&1, labels)) |> IO.iodata_to_binary()

    if byte_size(bytes) != size do
      raise "inconsistent assembly: pass 1 announces #{size} bytes, " <>
              "pass 2 emitted #{byte_size(bytes)}"
    end

    bytes
  end

  @doc """
  The label addresses of a program, without emitting the bytes.

  Pass 1 computes them anyway; exposing them saves the caller from counting
  instructions by hand to find out where its entry point landed. It is what the
  kernel will need in order to write the cartridge header.
  """
  @spec addresses([element()], keyword()) :: %{atom() => non_neg_integer()}
  def addresses(program, opts \\ []) do
    origin = Keyword.get(opts, :origin, @default_origin)
    {_plan, labels, _size} = measure(program, origin)
    labels
  end

  # ══ Pass 1: the sizes and the labels ═════════════════════════════════════════

  defp measure(program, origin) do
    {plan, labels, address} =
      program
      |> Enum.with_index()
      |> Enum.reduce({[], %{}, origin}, &measure_element/2)

    {Enum.reverse(plan), labels, address - origin}
  end

  defp measure_element({{:label, name}, index}, {plan, labels, address})
       when is_atom(name) do
    case labels do
      %{^name => previous} ->
        raise ArgumentError, """
        duplicate label: #{inspect(name)}, at element ##{index}.

        It is already placed at 0x#{hex(previous)} and would be placed again at \
        0x#{hex(address)} — a jump target cannot name two addresses.
        """

      _ ->
        {plan, Map.put(labels, name, address), address}
    end
  end

  defp measure_element({{:bytes, bytes}, _index}, {plan, labels, address})
       when is_binary(bytes) do
    {[{:bytes, bytes} | plan], labels, address + byte_size(bytes)}
  end

  defp measure_element({{:label, other}, index}, _acc) do
    raise ArgumentError,
          "malformed label at element ##{index}: the name must be an atom, " <>
            "got #{inspect(other)}"
  end

  defp measure_element({{:bytes, other}, index}, _acc) do
    raise ArgumentError,
          "malformed bytes at element ##{index}: expected a binary, " <>
            "got #{inspect(other)}"
  end

  defp measure_element({source, index}, {plan, labels, address})
       when is_tuple(source) and tuple_size(source) > 0 do
    insn = prepare(source, index, address)
    {[{:instruction, insn} | plan], labels, address + insn.size}
  end

  defp measure_element({other, index}, _acc) do
    raise ArgumentError, """
    unknown program element at element ##{index}: #{inspect(other)}

    A program is a list of `{:label, name}`, `{:bytes, binary}` and \
    instructions — the latter being tuples whose head is a mnemonic.
    """
  end

  # ── Resolving one instruction ───────────────────────────────────────────────

  defp prepare(source, index, address) do
    [mnemonic | arguments] = Tuple.to_list(source)

    unless is_atom(mnemonic) do
      raise ArgumentError, """
      malformed instruction at element ##{index} (0x#{hex(address)}): \
      #{inspect(source)}

      The head of the tuple must be a mnemonic from the table, not #{inspect(mnemonic)}.
      """
    end

    {prefix, opcode, pairs} =
      case resolve(mnemonic, arguments) do
        nil ->
          raise ArgumentError, unknown_message(source, mnemonic, arguments, index, address)

        found ->
          found
      end

    immediates = for {template, operand} <- pairs, width(template) > 0, do: {template, operand}
    body = Enum.sum(Enum.map(immediates, fn {template, _} -> width(template) end))

    %{
      source: source,
      index: index,
      address: address,
      size: 1 + if(prefix, do: 1, else: 0) + body,
      mnemonic: mnemonic,
      prefix: prefix,
      opcode: opcode,
      immediates: immediates
    }
  end

  # A mnemonic and source arguments in; the encoding and the pairing of the
  # operands with the table's templates out, or `nil`.
  #
  # The method is a search, not a translation: some source operands have several
  # possible shapes (an integer can be an 8-bit immediate, a 16-bit one, an RST
  # target, a bit number) and it is the index that settles it. The cartesian
  # product stays tiny — sixteen combinations at most — and the uniqueness of
  # the keys means at most one succeeds.
  defp resolve(mnemonic, arguments) do
    Enum.find_value(readings(arguments), fn {condition, operands} ->
      operands
      |> Enum.map(&forms/1)
      |> product()
      |> Enum.find_value(fn templates ->
        case Map.fetch(@index, {mnemonic, condition, templates}) do
          {:ok, {prefix, opcode}} -> {prefix, opcode, Enum.zip(templates, operands)}
          :error -> nil
        end
      end)
    end)
  end

  # `:c` is both a register and a condition — `{:inc, :c}` increments C,
  # `{:ret, :c}` returns if carry. No syntactic rule tells them apart, so we try
  # both readings and the index settles it: only one of the two corresponds to
  # an existing instruction. The unconditional one first, so that `{:inc, :c}`
  # is never read as a condition.
  defp readings([head | rest]) when head in [:nz, :z, :nc, :c] do
    [{nil, [head | rest]}, {head, rest}]
  end

  defp readings(arguments), do: [{nil, arguments}]

  defp product([]), do: [[]]

  defp product([forms | rest]) do
    for form <- forms, tail <- product(rest), do: [form | tail]
  end

  # The table shapes a source operand can take. Several when the syntax is
  # ambiguous, none when the operand makes no sense.
  defp forms(register) when register in [:a, :b, :c, :d, :e, :h, :l], do: [{:reg, register}]
  defp forms(pair) when pair in [:bc, :de, :hl, :sp, :af], do: [{:pair, pair}]

  # An integer: an immediate of either width, or a value encoded in the opcode
  # itself (the target of an RST, the bit number of a BIT/RES/SET).
  defp forms(integer) when is_integer(integer) do
    [{:imm, 8}, {:imm, 16}, {:rst, integer}, {:bit, integer}]
  end

  # A label is an address: 16 bits for JP and CALL, 8 signed bits for JR alone —
  # the index chooses, and `immediate/4` refuses the case where an 8-bit one
  # would land anywhere other than a relative jump.
  defp forms({:label, name}) when is_atom(name), do: [{:imm, 16}, {:imm, 8}]

  defp forms({:mem, :hl}), do: [:hl_ind]
  defp forms({:mem, pair}) when pair in [:bc, :de, :hl_inc, :hl_dec], do: [{:ind, pair}]
  defp forms({:mem, address}) when is_integer(address), do: [:a16_ind]
  defp forms({:mem, {:label, name}}) when is_atom(name), do: [:a16_ind]
  defp forms({:high, :c}), do: [:c_ind]
  defp forms({:high, byte}) when is_integer(byte), do: [:a8_ind]
  defp forms({:high, {:label, name}}) when is_atom(name), do: [:a8_ind]
  defp forms(_other), do: []

  defp width({:imm, 8}), do: 1
  defp width({:imm, 16}), do: 2
  defp width(:a8_ind), do: 1
  defp width(:a16_ind), do: 2
  defp width(_encoded_in_the_opcode), do: 0

  # ══ Pass 2: the bytes ════════════════════════════════════════════════════════

  defp emit({:bytes, bytes}, _labels), do: bytes

  defp emit({:instruction, insn}, labels) do
    head =
      case insn.prefix do
        nil -> <<insn.opcode>>
        :cb -> <<0xCB, insn.opcode>>
      end

    Enum.reduce(insn.immediates, head, fn {template, operand}, bytes ->
      value = immediate(template, operand, insn, labels)
      bytes <> encode(template, value)
    end)
  end

  defp encode({:imm, 8}, value), do: <<value>>
  defp encode(:a8_ind, value), do: <<value>>
  defp encode({:imm, 16}, value), do: <<value::16-little>>
  defp encode(:a16_ind, value), do: <<value::16-little>>

  # ── The value of an immediate ───────────────────────────────────────────────

  defp immediate({:imm, 8}, {:label, name}, insn, labels) do
    target = resolve_label!(name, insn, labels)

    unless insn.mnemonic == :jr do
      raise ArgumentError, """
      label where #{Atom.to_string(insn.mnemonic) |> String.upcase()} expects \
      a byte, at element ##{insn.index} (0x#{hex(insn.address)}): \
      #{inspect(insn.source)}

      A label becomes an 8-bit immediate only for a relative JR jump, where it \
      names a distance. Anywhere else, it could only fit in a byte by losing \
      half of its address.
      """
    end

    # PC is already advanced when the processor adds the displacement: the jump
    # is measured from the address *after* the instruction, not its own.
    next_pc = insn.address + insn.size
    delta = target - next_pc

    if delta < -128 or delta > 127 do
      raise ArgumentError, """
      relative jump out of range at element ##{insn.index} \
      (0x#{hex(insn.address)}): #{inspect(insn.source)}

      The gap is #{delta} bytes — from 0x#{hex(next_pc)} (the address after the \
      JR) to 0x#{hex(target)} (the label #{inspect(name)}) — and JR only encodes \
      a displacement of -128 to 127. This needs a JP, whose target is absolute.
      """
    end

    delta &&& 0xFF
  end

  defp immediate({:imm, 8}, integer, insn, _labels) when is_integer(integer) do
    # The two relative mnemonics also accept a negative integer, encoded in
    # two's complement; everywhere else the byte is never signed.
    if insn.mnemonic in @signed do
      range!(integer, -128, 0xFF, "a signed byte", insn) &&& 0xFF
    else
      range!(integer, 0, 0xFF, "a byte", insn)
    end
  end

  defp immediate({:imm, 16}, {:label, name}, insn, labels) do
    name |> resolve_label!(insn, labels) |> range!(0, 0xFFFF, "an address", insn)
  end

  defp immediate({:imm, 16}, integer, insn, _labels) when is_integer(integer) do
    range!(integer, 0, 0xFFFF, "a word", insn)
  end

  defp immediate(:a16_ind, {:mem, {:label, name}}, insn, labels) do
    name |> resolve_label!(insn, labels) |> range!(0, 0xFFFF, "an address", insn)
  end

  defp immediate(:a16_ind, {:mem, address}, insn, _labels) do
    range!(address, 0, 0xFFFF, "an address", insn)
  end

  # The high page only encodes the low byte: 0xFF00 + n. A label is accepted
  # there if — and only if — it landed in that page.
  defp immediate(:a8_ind, {:high, {:label, name}}, insn, labels) do
    target = resolve_label!(name, insn, labels)

    if target < 0xFF00 or target > 0xFFFF do
      raise ArgumentError, """
      label outside the high page at element ##{insn.index} \
      (0x#{hex(insn.address)}): #{inspect(insn.source)}

      #{inspect(name)} is at 0x#{hex(target)}, whereas LDH only reaches \
      0xFF00 to 0xFFFF: it encodes only the low byte of the address.
      """
    end

    target &&& 0xFF
  end

  defp immediate(:a8_ind, {:high, byte}, insn, _labels) do
    range!(byte, 0, 0xFF, "an offset within the high page", insn)
  end

  defp resolve_label!(name, insn, labels) do
    case labels do
      %{^name => address} ->
        address

      _ ->
        known =
          case Map.keys(labels) do
            [] -> "no label is defined in this program"
            names -> "defined: " <> Enum.map_join(Enum.sort(names), ", ", &inspect/1)
          end

        raise ArgumentError, """
        unknown label: #{inspect(name)}, at element ##{insn.index} \
        (0x#{hex(insn.address)}) — #{known}.
        """
    end
  end

  defp range!(value, low, high, what, insn) when is_integer(value) do
    if value < low or value > high do
      raise ArgumentError, """
      immediate out of range at element ##{insn.index} (0x#{hex(insn.address)}): \
      #{inspect(insn.source)}

      #{inspect(value)} does not fit in #{what}: expected #{low}..#{high}.
      """
    end

    value
  end

  defp range!(value, _low, _high, what, insn) do
    raise ArgumentError, """
    non-numeric operand at element ##{insn.index} (0x#{hex(insn.address)}): \
    #{inspect(insn.source)}

    #{inspect(value)} should be #{what}.
    """
  end

  # ══ The failure messages ═════════════════════════════════════════════════════

  defp unknown_message(source, mnemonic, arguments, index, address) do
    situation = "at element ##{index} (0x#{hex(address)}): #{inspect(source)}"
    orphans = orphans(arguments)

    cond do
      orphans != [] ->
        """
        operand of unknown shape #{situation}

        #{Enum.map_join(orphans, "\n", &"  #{inspect(&1)} matches no operand shape.")}

        The recognised shapes are: a register (:a … :l), a pair (:bc, :de, \
        :hl, :sp, :af), an integer, {:mem, …}, {:high, …} and {:label, name}.
        """

      mnemonic in @mnemonics ->
        """
        unknown instruction #{situation}

        The mnemonic #{inspect(mnemonic)} exists, but not with these operands.
        #{known_forms(mnemonic, arguments)}
        """

      true ->
        """
        unknown mnemonic #{situation}

        #{inspect(mnemonic)} is not in the SM83 table.#{suggestion(mnemonic)}
        """
    end
  end

  defp orphans(arguments) do
    # A leading condition is not an operand: drop it before looking for the
    # culprits, otherwise `{:jr, :nz, target}` would accuse `:nz`.
    arguments
    |> case do
      [head | rest] when head in [:nz, :z, :nc, :c] -> rest
      all -> all
    end
    |> Enum.filter(&(forms(&1) == []))
  end

  # The forms that actually exist, in assembler syntax. `:ld` has eighty-seven
  # of them: listing them all helps nobody. We show those that look most like
  # what was written — first by the number of operands that land right, then by
  # the arity gap. On `{:ld, :a, :bc}`, the mistake being in the second operand,
  # it is the forms taking A that come up.
  @form_limit 12

  defp known_forms(mnemonic, arguments) do
    labels =
      Table.all()
      |> Enum.filter(&(&1.mnemonic == mnemonic))
      |> Enum.sort_by(&{-matches(&1, arguments), arity_gap(&1, arguments)})
      |> Enum.map(&Insn.label/1)
      |> Enum.uniq()

    {shown, rest} = Enum.split(labels, @form_limit)

    start = "Known forms:\n" <> Enum.map_join(shown, "\n", &"  #{&1}")

    case rest do
      [] -> start
      others -> start <> "\n  … and #{length(others)} more."
    end
  end

  # The number of table operands that a source operand written in the same place
  # could actually denote.
  defp matches(insn, arguments) do
    written =
      case arguments do
        [head | rest] when head in [:nz, :z, :nc, :c] and insn.condition != nil -> rest
        all -> all
      end

    insn.operands
    |> Enum.zip(written)
    |> Enum.count(fn {template, one} -> template in forms(one) end)
  end

  defp arity_gap(insn, arguments) do
    arity = length(insn.operands) + if(insn.condition, do: 1, else: 0)
    abs(arity - length(arguments))
  end

  defp suggestion(mnemonic) do
    written = Atom.to_string(mnemonic)

    close =
      @mnemonics
      |> Enum.map(&{String.jaro_distance(written, Atom.to_string(&1)), &1})
      # 0.65 and not 0.8: SM83 mnemonics are two or three letters long, where a
      # single typo already drops the Jaro distance to 0.67.
      |> Enum.filter(fn {score, _} -> score >= 0.65 end)
      |> Enum.sort(:desc)
      |> Enum.take(3)
      |> Enum.map(fn {_, name} -> inspect(name) end)

    case close do
      [] -> ""
      [single] -> " Did you mean #{single}?"
      several -> " Did you mean #{Enum.join(several, ", ")}?"
    end
  end

  defp hex(value), do: value |> Integer.to_string(16) |> String.pad_leading(4, "0")
end
