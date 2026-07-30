defmodule Atomboy.Native.RV32 do
  @moduledoc """
  The RISC-V 32-bit encoder -- one instruction, four bytes.

  The same bet as `Atomboy.CPU.Table`: describe the encoding as data and let
  generation produce the functions. The five RV32I formats fit in a few lines
  each, so an instruction costs one table entry -- `{:add, "add", 0x00, 0x0}` --
  rather than a copied body.

  ## The formats

      R  funct7[31:25] rs2[24:20] rs1[19:15] funct3[14:12] rd[11:7] opcode[6:0]
      I  imm[31:20]              rs1        funct3        rd       opcode
      S  imm[11:5]     rs2       rs1        funct3        imm[4:0] opcode
      B  imm[12|10:5]  rs2       rs1        funct3        imm[4:1|11] opcode
      U  imm[31:12]                                       rd       opcode
      J  imm[20|10:1|11|19:12]                            rd       opcode

  The B and J formats scramble the immediate's bits instead of laying them out
  in order. That is not affectation: the split keeps each bit at the position it
  already occupies in the other formats, which saves wiring in the hardware
  decoder. For us it is simply a trap to copy carefully, hence the external
  oracle -- `riscv64-unknown-elf-as` assembles the same text, `objdump` gives it
  back as bytes, and the test compares.

  ## Nothing compressed

  RV32C can encode some instructions in two bytes. We emit none of them,
  deliberately. A compressed instruction's size depends on its operands -- and
  for a branch, on the distance to its target, which depends on the size of the
  instructions in between. That is a fixed point, and solving it takes an
  assembler far larger than `Atomboy.Native.Asm`. Everything is four bytes, so
  pass one knows every address before a single byte is emitted.

  The day code size becomes the limiting factor -- that is the subject of this
  project, so that day will come -- compression goes where it is safe: on
  instructions whose operands are known at emission, never on those targeting a
  label.
  """

  import Bitwise

  @regs %{
    zero: 0,
    ra: 1,
    sp: 2,
    gp: 3,
    tp: 4,
    t0: 5,
    t1: 6,
    t2: 7,
    s0: 8,
    s1: 9,
    a0: 10,
    a1: 11,
    a2: 12,
    a3: 13,
    a4: 14,
    a5: 15,
    a6: 16,
    a7: 17,
    s2: 18,
    s3: 19,
    s4: 20,
    s5: 21,
    s6: 22,
    s7: 23,
    s8: 24,
    s9: 25,
    s10: 26,
    s11: 27,
    t3: 28,
    t4: 29,
    t5: 30,
    t6: 31
  }

  @typedoc "A register, named after the ABI."
  @type reg ::
          :zero
          | :ra
          | :sp
          | :gp
          | :tp
          | :t0
          | :t1
          | :t2
          | :t3
          | :t4
          | :t5
          | :t6
          | :s0
          | :s1
          | :s2
          | :s3
          | :s4
          | :s5
          | :s6
          | :s7
          | :s8
          | :s9
          | :s10
          | :s11
          | :a0
          | :a1
          | :a2
          | :a3
          | :a4
          | :a5
          | :a6
          | :a7

  @doc "A register's number. Raises on an unknown name -- a typo must not encode."
  @spec reg(reg()) :: 0..31
  def reg(name) do
    case @regs do
      %{^name => number} ->
        number

      _ ->
        raise ArgumentError,
              "unknown RV32 register: #{inspect(name)} -- names are the ABI ones (#{@regs |> Map.keys() |> Enum.sort() |> Enum.join(", ")})"
    end
  end

  @doc "Every register name, lowest number first."
  @spec regs() :: [reg()]
  def regs, do: @regs |> Enum.sort_by(&elem(&1, 1)) |> Enum.map(&elem(&1, 0))

  # ══ The tables ═══════════════════════════════════════════════════════════════
  #
  # Each entry: {Elixir name, assembler mnemonic, ...encoding fields}. The name
  # differs from the mnemonic for `and`, `or` and `xor`, which are Elixir special
  # forms and cannot be function names.

  @r_type [
    {:add, "add", 0x00, 0x0},
    {:sub, "sub", 0x20, 0x0},
    {:sll, "sll", 0x00, 0x1},
    {:slt, "slt", 0x00, 0x2},
    {:sltu, "sltu", 0x00, 0x3},
    {:xor_, "xor", 0x00, 0x4},
    {:srl, "srl", 0x00, 0x5},
    {:sra, "sra", 0x20, 0x5},
    {:or_, "or", 0x00, 0x6},
    {:and_, "and", 0x00, 0x7}
  ]

  @i_type [
    {:addi, "addi", 0x13, 0x0},
    {:slti, "slti", 0x13, 0x2},
    {:sltiu, "sltiu", 0x13, 0x3},
    {:xori, "xori", 0x13, 0x4},
    {:ori, "ori", 0x13, 0x6},
    {:andi, "andi", 0x13, 0x7},
    {:jalr, "jalr", 0x67, 0x0}
  ]

  @load_type [
    {:lb, "lb", 0x0},
    {:lh, "lh", 0x1},
    {:lw, "lw", 0x2},
    {:lbu, "lbu", 0x4},
    {:lhu, "lhu", 0x5}
  ]

  @shift_type [
    {:slli, "slli", 0x00, 0x1},
    {:srli, "srli", 0x00, 0x5},
    {:srai, "srai", 0x20, 0x5}
  ]

  @s_type [
    {:sb, "sb", 0x0},
    {:sh, "sh", 0x1},
    {:sw, "sw", 0x2}
  ]

  @b_type [
    {:beq, "beq", 0x0},
    {:bne, "bne", 0x1},
    {:blt, "blt", 0x4},
    {:bge, "bge", 0x5},
    {:bltu, "bltu", 0x6},
    {:bgeu, "bgeu", 0x7}
  ]

  @u_type [
    {:lui, "lui", 0x37},
    {:auipc, "auipc", 0x17}
  ]

  # ══ The emitters, generated ══════════════════════════════════════════════════

  for {name, asm, funct7, funct3} <- @r_type do
    @doc "`#{asm} rd, rs1, rs2`"
    @spec unquote(name)(reg(), reg(), reg()) :: binary()
    def unquote(name)(rd, rs1, rs2) do
      encode(
        <<unquote(funct7)::7, reg(rs2)::5, reg(rs1)::5, unquote(funct3)::3, reg(rd)::5, 0x33::7>>
      )
    end
  end

  for {name, asm, opcode, funct3} <- @i_type do
    @doc "`#{asm} rd, rs1, imm` -- the immediate is signed, 12 bits."
    @spec unquote(name)(reg(), reg(), -2048..2047) :: binary()
    def unquote(name)(rd, rs1, imm) do
      check_imm!(unquote(asm), imm, -2048, 2047)
      encode(<<imm::12, reg(rs1)::5, unquote(funct3)::3, reg(rd)::5, unquote(opcode)::7>>)
    end
  end

  for {name, asm, funct3} <- @load_type do
    @doc "`#{asm} rd, imm(rs1)`"
    @spec unquote(name)(reg(), reg(), -2048..2047) :: binary()
    def unquote(name)(rd, rs1, imm) do
      check_imm!(unquote(asm), imm, -2048, 2047)
      encode(<<imm::12, reg(rs1)::5, unquote(funct3)::3, reg(rd)::5, 0x03::7>>)
    end
  end

  for {name, asm, funct7, funct3} <- @shift_type do
    @doc "`#{asm} rd, rs1, shamt` -- the shift amount fits in 5 bits."
    @spec unquote(name)(reg(), reg(), 0..31) :: binary()
    def unquote(name)(rd, rs1, shamt) do
      check_imm!(unquote(asm), shamt, 0, 31)

      encode(
        <<unquote(funct7)::7, shamt::5, reg(rs1)::5, unquote(funct3)::3, reg(rd)::5, 0x13::7>>
      )
    end
  end

  for {name, asm, funct3} <- @s_type do
    @doc "`#{asm} rs2, imm(rs1)`"
    @spec unquote(name)(reg(), reg(), -2048..2047) :: binary()
    def unquote(name)(rs2, rs1, imm) do
      check_imm!(unquote(asm), imm, -2048, 2047)
      <<high::7, low::5>> = <<imm::12>>
      encode(<<high::7, reg(rs2)::5, reg(rs1)::5, unquote(funct3)::3, low::5, 0x23::7>>)
    end
  end

  for {name, asm, funct3} <- @b_type do
    @doc """
    `#{asm} rs1, rs2, offset` -- the offset is relative to the instruction
    itself, even, and fits in 13 signed bits (+/-4 KB).
    """
    @spec unquote(name)(reg(), reg(), integer()) :: binary()
    def unquote(name)(rs1, rs2, offset) do
      check_branch!(unquote(asm), offset, -4096, 4094)
      <<b12::1, b11::1, b10_5::6, b4_1::4, 0::1>> = <<offset::13>>

      encode(
        <<b12::1, b10_5::6, reg(rs2)::5, reg(rs1)::5, unquote(funct3)::3, b4_1::4, b11::1,
          0x63::7>>
      )
    end
  end

  for {name, asm, opcode} <- @u_type do
    @doc "`#{asm} rd, imm` -- the top 20 bits, the immediate already shifted."
    @spec unquote(name)(reg(), 0..0xFFFFF) :: binary()
    def unquote(name)(rd, imm) do
      check_imm!(unquote(asm), imm, 0, 0xFFFFF)
      encode(<<imm::20, reg(rd)::5, unquote(opcode)::7>>)
    end
  end

  @doc """
  `jal rd, offset` -- a relative jump, even, in 21 signed bits (+/-1 MB).

  That reach decides the shape of the jump tables: at +/-1 MB, a `j` covers any
  target in the interpreter without a detour.
  """
  @spec jal(reg(), integer()) :: binary()
  def jal(rd, offset) do
    check_branch!("jal", offset, -1_048_576, 1_048_574)
    <<b20::1, b19_12::8, b11::1, b10_1::10, 0::1>> = <<offset::21>>
    encode(<<b20::1, b10_1::10, b11::1, b19_12::8, reg(rd)::5, 0x6F::7>>)
  end

  @doc """
  `csrrs rd, csr, rs1` -- reads a control register.

  Only one address interests us: `0xC02`, the `instret` counter of retired
  instructions. Under `qemu -icount shift=0` it counts executed instructions
  exactly, which yields this project's measurement -- RV32 instructions per SM83
  instruction -- with no plugin and no line of C.
  """
  @spec csrrs(reg(), 0..0xFFF, reg()) :: binary()
  def csrrs(rd, csr, rs1) do
    check_imm!("csrrs", csr, 0, 0xFFF)
    encode(<<csr::12, reg(rs1)::5, 0x2::3, reg(rd)::5, 0x73::7>>)
  end

  # ══ Pseudo-instructions ══════════════════════════════════════════════════════

  @doc """
  `li rd, value` -- loads any constant, in one or two instructions.

  The trap: `addi` sign-extends its immediate. When the low 12 bits exceed
  0x7FF they read as negative and subtract 0x1000 from the result, so the high
  bits must be incremented to compensate. The rounding `(value + 0x800) >>> 12`
  does exactly that.

  A second trap, found by the oracle: the value is first reduced to a signed
  32-bit integer. Without that, `0xFFFFFFFF` -- the same value as `-1`, written
  differently -- came out as two instructions instead of one.
  """
  @spec li(reg(), integer()) :: [binary()]
  def li(rd, value) do
    word = value &&& 0xFFFFFFFF
    signed = if word > 0x7FFFFFFF, do: word - 0x100000000, else: word

    if signed >= -2048 and signed <= 2047 do
      [addi(rd, :zero, signed)]
    else
      high = (word + 0x800) >>> 12 &&& 0xFFFFF
      low = word - (high <<< 12) &&& 0xFFF
      low = if low > 0x7FF, do: low - 0x1000, else: low

      case low do
        0 -> [lui(rd, high)]
        _ -> [lui(rd, high), addi(rd, rd, low)]
      end
    end
  end

  @doc "`nop` -- the canonical `addi zero, zero, 0`."
  @spec nop() :: binary()
  def nop, do: addi(:zero, :zero, 0)

  @doc "`mv rd, rs` -- a register copy."
  @spec mv(reg(), reg()) :: binary()
  def mv(rd, rs), do: addi(rd, rs, 0)

  @doc "`j offset` -- a jump that keeps no return address."
  @spec j(integer()) :: binary()
  def j(offset), do: jal(:zero, offset)

  @doc "`jr rs` -- a jump to the address held in a register."
  @spec jr(reg()) :: binary()
  def jr(rs), do: jalr(:zero, rs, 0)

  @doc "`ret` -- a subroutine return, `jr ra`."
  @spec ret() :: binary()
  def ret, do: jr(:ra)

  # ══ Introspection ════════════════════════════════════════════════════════════

  @doc """
  Every emitted form, as data -- the differential test walks them.

  Each entry says how to call the emitter and how to write the same instruction
  for `riscv64-unknown-elf-as`, which lets the test cover any new instruction
  added to the tables automatically.
  """
  @spec forms() :: [%{name: atom(), asm: String.t(), shape: atom()}]
  def forms do
    Enum.map(@r_type, fn {name, asm, _, _} -> %{name: name, asm: asm, shape: :rrr} end) ++
      Enum.map(@i_type, fn {name, asm, _, _} -> %{name: name, asm: asm, shape: shape_i(name)} end) ++
      Enum.map(@load_type, fn {name, asm, _} -> %{name: name, asm: asm, shape: :load} end) ++
      Enum.map(@shift_type, fn {name, asm, _, _} -> %{name: name, asm: asm, shape: :shift} end) ++
      Enum.map(@s_type, fn {name, asm, _} -> %{name: name, asm: asm, shape: :store} end) ++
      Enum.map(@b_type, fn {name, asm, _} -> %{name: name, asm: asm, shape: :branch} end) ++
      Enum.map(@u_type, fn {name, asm, _} -> %{name: name, asm: asm, shape: :upper} end)
  end

  # as writes jalr like a load: `jalr rd, imm(rs1)`.
  defp shape_i(:jalr), do: :load
  defp shape_i(_), do: :rri

  # ══ The foundation ═══════════════════════════════════════════════════════════

  # Fields are laid out from bit 31 down to bit 0, then read back little-endian:
  # that is the order the RISC-V documentation presents them in, and the only
  # order in which re-reading an encoding is possible.
  defp encode(<<word::32>>), do: <<word::32-little>>

  defp check_imm!(mnemonic, value, low, high) when is_integer(value) do
    unless value >= low and value <= high do
      raise ArgumentError,
            "#{mnemonic}: immediate #{value} is outside #{low}..#{high}"
    end
  end

  defp check_imm!(mnemonic, value, _low, _high) do
    raise ArgumentError, "#{mnemonic}: immediate #{inspect(value)} is not an integer"
  end

  defp check_branch!(mnemonic, offset, low, high) do
    check_imm!(mnemonic, offset, low, high)

    unless rem(offset, 2) == 0 do
      raise ArgumentError,
            "#{mnemonic}: displacement #{offset} is odd -- instructions are aligned"
    end
  end
end
