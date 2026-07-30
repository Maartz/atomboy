defmodule Atomboy.Native.ALU do
  @moduledoc """
  Flag arithmetic in RISC-V -- the mirror of `Atomboy.CPU.ALU`.

  One routine per function, same names, same contract. That is not affectation:
  it is what makes `Atomboy.Native.Bench`'s differential test possible, which
  compares the two implementations over the whole input space rather than over
  examples. `ADC`'s half-carry has one faulty case in 4096; a set of examples
  does not find it, an exhaustive comparison cannot miss it.

  ## Called routines, not inlining

  The 64 `ALU A, r` opcodes plus their 8 immediate forms would otherwise share
  some fifteen instructions of flag math copied seventy-two times -- about 4 KB,
  against a 32 KB instruction-cache budget which is *the entire reason this work
  exists*. The price is one `jal` and one `ret` per ALU instruction. To be
  remeasured once the table is full, not before.

  ## The calling convention

      a0    first argument, and the 8- or 16-bit result
      a1    second argument, when one is needed
      s0    A -- read and rewritten by the accumulator operations
      s1    F -- read and rewritten by nearly everything
      a2    HL -- for `add16` only
      ra    the return

  A routine may clobber `t0` through `t4`, `a0`, `a1`, and the registers of its
  own contract. Everything else survives: that is what lets an opcode handler
  keep its working state across a call.

  No routine calls another -- they are leaves, and `ra` is never saved.

  ## What stays inline elsewhere

  What `Atomboy.CPU.Gen` inlines, the native side inlines too: `RES`/`SET`, the
  16-bit INC/DEC, `POP AF`'s `0xF0` mask, `JR`'s sign extension, the condition
  tests. The boundary is therefore the same on all three sides, and it reads in
  one place -- `alu.ex` -- instead of having to be guessed.
  """

  import Bitwise

  alias Atomboy.Native.Asm
  alias Atomboy.Native.RV32

  @z 0x80
  @n 0x40
  @h 0x20
  @c 0x10

  @doc """
  Every routine, to be placed once in an image.

  They cost only their size: nothing runs unless it is called.
  """
  @spec routines() :: [Asm.item()]
  def routines do
    [
      add(),
      adc(),
      sub(),
      sbc(),
      cp(),
      bit_and(),
      bit_xor(),
      bit_or(),
      inc(),
      dec(),
      add16(),
      add_sp(),
      rlca(),
      rrca(),
      rla(),
      rra(),
      daa(),
      cpl(),
      scf(),
      ccf(),
      cb_rotations(),
      bits()
    ]
  end

  @doc """
  A routine's label name -- the bridge between the two worlds.

  `Atomboy.CPU.Gen.alu_call/4` already maps a mnemonic to an ALU function name
  for both Elixir backends; this is the native equivalent.
  """
  @spec label(atom()) :: atom()
  def label(name), do: :"alu_#{name}"

  @doc "The label name of a `BIT n`, whose bit number is baked into the routine."
  @spec bit_label(0..7) :: atom()
  def bit_label(n), do: :"alu_bit_#{n}"

  # ══ Additions ════════════════════════════════════════════════════════════════

  # ADD A, v -- the incoming carry is zero, everything else is shared.
  defp add do
    [
      Asm.label(label(:add)),
      RV32.li(:t4, 0),
      add_body(),
      RV32.ret()
    ]
  end

  # ADC A, v -- the incoming carry comes from F and **counts in the half-carry**.
  # This is the trap documented in `Atomboy.CPU.ALU`: forgetting it passes the
  # vast majority of cases and only breaks DAA, much later.
  defp adc do
    [
      Asm.label(label(:adc)),
      carry_in(:t4),
      add_body(),
      RV32.ret()
    ]
  end

  # A in s0, value in a0, incoming carry in t4. Writes s0 and s1.
  defp add_body do
    [
      # the full sum, up to 0x1FF
      RV32.add(:t3, :s0, :a0),
      RV32.add(:t3, :t3, :t4),
      # half-carry: do the low nibbles plus the carry exceed 0xF
      RV32.andi(:t0, :s0, 0x0F),
      RV32.andi(:t1, :a0, 0x0F),
      RV32.add(:t0, :t0, :t1),
      RV32.add(:t0, :t0, :t4),
      RV32.srli(:t0, :t0, 4),
      RV32.slli(:t0, :t0, 5),
      # outgoing carry: bit 8 of the sum
      RV32.srli(:t1, :t3, 8),
      RV32.slli(:t1, :t1, 4),
      RV32.or_(:t0, :t0, :t1),
      RV32.andi(:s0, :t3, 0xFF),
      zero(:s0, :t2),
      RV32.or_(:s1, :t0, :t2)
    ]
  end

  # ══ Soustractions ════════════════════════════════════════════════════════════

  defp sub do
    [
      Asm.label(label(:sub)),
      RV32.li(:t4, 0),
      sub_body(true),
      RV32.ret()
    ]
  end

  defp sbc do
    [
      Asm.label(label(:sbc)),
      carry_in(:t4),
      sub_body(true),
      RV32.ret()
    ]
  end

  # CP v -- a subtraction whose result is thrown away. The same body without the
  # write to A: duplicating the computation would mean maintaining the same
  # borrow subtlety twice.
  defp cp do
    [
      Asm.label(label(:cp)),
      RV32.li(:t4, 0),
      sub_body(false),
      RV32.ret()
    ]
  end

  defp sub_body(writes_a?) do
    [
      # nibble borrow: does A's low nibble drop below v's
      RV32.andi(:t0, :s0, 0x0F),
      RV32.andi(:t1, :a0, 0x0F),
      RV32.add(:t1, :t1, :t4),
      RV32.sltu(:t0, :t0, :t1),
      RV32.slli(:t0, :t0, 5),
      # byte borrow
      RV32.add(:t1, :a0, :t4),
      RV32.sltu(:t1, :s0, :t1),
      RV32.slli(:t1, :t1, 4),
      RV32.or_(:t0, :t0, :t1),
      RV32.ori(:t0, :t0, @n),
      # the result, written or merely weighed
      RV32.sub(:t3, :s0, :a0),
      RV32.sub(:t3, :t3, :t4),
      RV32.andi(:t3, :t3, 0xFF),
      zero(:t3, :t2),
      RV32.or_(:s1, :t0, :t2),
      if(writes_a?, do: [RV32.mv(:s0, :t3)], else: [])
    ]
  end

  # ══ Logiques ═════════════════════════════════════════════════════════════════

  # AND sets H. That is not a forgotten regularity, it is how the hardware is.
  defp bit_and do
    [
      Asm.label(label(:bit_and)),
      RV32.and_(:s0, :s0, :a0),
      zero(:s0, :t0),
      RV32.ori(:s1, :t0, @h),
      RV32.ret()
    ]
  end

  defp bit_xor do
    [
      Asm.label(label(:bit_xor)),
      RV32.xor_(:s0, :s0, :a0),
      zero(:s0, :s1),
      RV32.ret()
    ]
  end

  defp bit_or do
    [
      Asm.label(label(:bit_or)),
      RV32.or_(:s0, :s0, :a0),
      zero(:s0, :s1),
      RV32.ret()
    ]
  end

  # ══ Increments ═══════════════════════════════════════════════════════════════

  # INC and DEC **preserve C**. The second classic trap after the half-carry:
  # setting all four flags by reflex. The `OR A / INC / JR C` pattern games use
  # depends on that preservation.
  defp inc do
    [
      Asm.label(label(:inc)),
      # H when the low nibble was 0xF
      RV32.andi(:t0, :a0, 0x0F),
      RV32.xori(:t0, :t0, 0x0F),
      RV32.sltiu(:t0, :t0, 1),
      RV32.slli(:t0, :t0, 5),
      RV32.andi(:t1, :s1, @c),
      RV32.or_(:t0, :t0, :t1),
      RV32.addi(:a0, :a0, 1),
      RV32.andi(:a0, :a0, 0xFF),
      zero(:a0, :t2),
      RV32.or_(:s1, :t0, :t2),
      RV32.ret()
    ]
  end

  defp dec do
    [
      Asm.label(label(:dec)),
      # H when the low nibble was 0 -- the borrow crosses
      RV32.andi(:t0, :a0, 0x0F),
      RV32.sltiu(:t0, :t0, 1),
      RV32.slli(:t0, :t0, 5),
      RV32.andi(:t1, :s1, @c),
      RV32.or_(:t0, :t0, :t1),
      RV32.ori(:t0, :t0, @n),
      RV32.addi(:a0, :a0, -1),
      RV32.andi(:a0, :a0, 0xFF),
      zero(:a0, :t2),
      RV32.or_(:s1, :t0, :t2),
      RV32.ret()
    ]
  end

  # ══ Sixteen bits ═════════════════════════════════════════════════════════════

  # ADD HL, rr -- INC's mirror image: here Z is preserved and C moves. H is
  # computed at bit 11, C at bit 15.
  defp add16 do
    [
      Asm.label(label(:add16)),
      # 0x0FFF does not fit andi's immediate (12 signed bits): the low twelve
      # bits are masked by shifting.
      RV32.slli(:t0, :a2, 20),
      RV32.srli(:t0, :t0, 20),
      RV32.slli(:t1, :a0, 20),
      RV32.srli(:t1, :t1, 20),
      RV32.add(:t0, :t0, :t1),
      RV32.srli(:t0, :t0, 12),
      RV32.slli(:t0, :t0, 5),
      RV32.add(:t3, :a2, :a0),
      RV32.srli(:t1, :t3, 16),
      RV32.slli(:t1, :t1, 4),
      RV32.or_(:t0, :t0, :t1),
      RV32.andi(:t1, :s1, @z),
      RV32.or_(:s1, :t0, :t1),
      RV32.and_(:a2, :t3, :s8),
      RV32.ret()
    ]
  end

  # ADD SP, r8 -- the processor's most counter-intuitive flags: a 16-bit
  # operation whose flags are computed on the low byte as an unsigned 8-bit
  # addition, and Z always cleared even when the result is zero. The offset is
  # signed for the result, unsigned for the flags.
  defp add_sp do
    [
      Asm.label(label(:add_sp)),
      RV32.andi(:t0, :a0, 0x0F),
      RV32.andi(:t1, :a1, 0x0F),
      RV32.add(:t0, :t0, :t1),
      RV32.srli(:t0, :t0, 4),
      RV32.slli(:t0, :t0, 5),
      RV32.andi(:t1, :a0, 0xFF),
      RV32.add(:t1, :t1, :a1),
      RV32.srli(:t1, :t1, 8),
      RV32.slli(:t1, :t1, 4),
      RV32.or_(:s1, :t0, :t1),
      # branchless sign extension: subtract 256 when bit 7 is set
      RV32.srli(:t2, :a1, 7),
      RV32.slli(:t2, :t2, 8),
      RV32.sub(:t2, :a1, :t2),
      RV32.add(:a0, :a0, :t2),
      RV32.and_(:a0, :a0, :s8),
      RV32.ret()
    ]
  end

  # ══ The accumulator alone ════════════════════════════════════════════════════

  # A's rotations **always** clear Z, unlike their CB-table twins which set it
  # normally. Two instructions, two encodings, two meanings for Z: a classic
  # source of confusion.
  defp rlca do
    [
      Asm.label(label(:rlca)),
      RV32.srli(:t0, :s0, 7),
      RV32.slli(:s0, :s0, 1),
      RV32.or_(:s0, :s0, :t0),
      RV32.andi(:s0, :s0, 0xFF),
      RV32.slli(:s1, :t0, 4),
      RV32.ret()
    ]
  end

  defp rrca do
    [
      Asm.label(label(:rrca)),
      RV32.andi(:t0, :s0, 1),
      RV32.srli(:s0, :s0, 1),
      RV32.slli(:t1, :t0, 7),
      RV32.or_(:s0, :s0, :t1),
      RV32.slli(:s1, :t0, 4),
      RV32.ret()
    ]
  end

  defp rla do
    [
      Asm.label(label(:rla)),
      carry_in(:t1),
      RV32.srli(:t0, :s0, 7),
      RV32.slli(:s0, :s0, 1),
      RV32.or_(:s0, :s0, :t1),
      RV32.andi(:s0, :s0, 0xFF),
      RV32.slli(:s1, :t0, 4),
      RV32.ret()
    ]
  end

  defp rra do
    [
      Asm.label(label(:rra)),
      carry_in(:t1),
      RV32.andi(:t0, :s0, 1),
      RV32.srli(:s0, :s0, 1),
      RV32.slli(:t1, :t1, 7),
      RV32.or_(:s0, :s0, :t1),
      RV32.slli(:s1, :t0, 4),
      RV32.ret()
    ]
  end

  # DAA -- the processor's most contorted instruction, and the reason N and H
  # are set carefully everywhere else: it is their only reader. C is **set,
  # never cleared**.
  defp daa do
    [
      Asm.label(label(:daa)),
      RV32.andi(:t0, :s1, @n),
      Asm.bnez(:t0, :daa_soustraction),

      # After an addition: the adjustment depends on H, on C, and on the value.
      RV32.li(:t1, 0),
      RV32.andi(:t2, :s1, @h),
      Asm.bnez(:t2, :daa_bas),
      RV32.andi(:t2, :s0, 0x0F),
      RV32.sltiu(:t2, :t2, 10),
      Asm.bnez(:t2, :daa_haut),
      Asm.label(:daa_bas),
      RV32.addi(:t1, :t1, 0x06),
      Asm.label(:daa_haut),
      RV32.andi(:t2, :s1, @c),
      Asm.bnez(:t2, :daa_haut_oui),
      RV32.li(:t2, 0x99),
      RV32.sltu(:t2, :t2, :s0),
      Asm.beqz(:t2, :daa_addition_fin),
      Asm.label(:daa_haut_oui),
      RV32.addi(:t1, :t1, 0x60),
      RV32.ori(:s1, :s1, @c),
      Asm.label(:daa_addition_fin),
      RV32.add(:s0, :s0, :t1),
      Asm.j(:daa_fin),

      # After a subtraction: H and C alone decide, A's value plays no part.
      # That is how it is.
      Asm.label(:daa_soustraction),
      RV32.li(:t1, 0),
      RV32.andi(:t2, :s1, @h),
      Asm.beqz(:t2, :daa_soustraction_haut),
      RV32.addi(:t1, :t1, 0x06),
      Asm.label(:daa_soustraction_haut),
      RV32.andi(:t2, :s1, @c),
      Asm.beqz(:t2, :daa_soustraction_fin),
      RV32.addi(:t1, :t1, 0x60),
      Asm.label(:daa_soustraction_fin),
      RV32.sub(:s0, :s0, :t1),

      # N and C survive, H falls, Z is recomputed.
      Asm.label(:daa_fin),
      RV32.andi(:s0, :s0, 0xFF),
      RV32.andi(:t0, :s1, @n ||| @c),
      zero(:s0, :t1),
      RV32.or_(:s1, :t0, :t1),
      RV32.ret()
    ]
  end

  defp cpl do
    [
      Asm.label(label(:cpl)),
      RV32.xori(:s0, :s0, 0xFF),
      RV32.andi(:t0, :s1, @z ||| @c),
      RV32.ori(:s1, :t0, @n ||| @h),
      RV32.ret()
    ]
  end

  defp scf do
    [
      Asm.label(label(:scf)),
      RV32.andi(:t0, :s1, @z),
      RV32.ori(:s1, :t0, @c),
      RV32.ret()
    ]
  end

  defp ccf do
    [
      Asm.label(label(:ccf)),
      RV32.andi(:t0, :s1, @z),
      RV32.andi(:t1, :s1, @c),
      RV32.xori(:t1, :t1, @c),
      RV32.or_(:s1, :t0, :t1),
      RV32.ret()
    ]
  end

  # ══ The CB table's rotations ═════════════════════════════════════════════════
  #
  # Same shape as their twins on A, except that they set Z normally and work on
  # a0 rather than on the accumulator.

  defp cb_rotations do
    [
      rlc(),
      rrc(),
      rl(),
      rr(),
      sla(),
      sra(),
      swap(),
      srl()
    ]
  end

  defp rlc do
    [
      Asm.label(label(:rlc)),
      RV32.srli(:t0, :a0, 7),
      RV32.slli(:a0, :a0, 1),
      RV32.or_(:a0, :a0, :t0),
      RV32.andi(:a0, :a0, 0xFF),
      RV32.slli(:t0, :t0, 4),
      zero(:a0, :t1),
      RV32.or_(:s1, :t0, :t1),
      RV32.ret()
    ]
  end

  defp rrc do
    [
      Asm.label(label(:rrc)),
      RV32.andi(:t0, :a0, 1),
      RV32.srli(:a0, :a0, 1),
      RV32.slli(:t1, :t0, 7),
      RV32.or_(:a0, :a0, :t1),
      RV32.slli(:t0, :t0, 4),
      zero(:a0, :t1),
      RV32.or_(:s1, :t0, :t1),
      RV32.ret()
    ]
  end

  defp rl do
    [
      Asm.label(label(:rl)),
      carry_in(:t1),
      RV32.srli(:t0, :a0, 7),
      RV32.slli(:a0, :a0, 1),
      RV32.or_(:a0, :a0, :t1),
      RV32.andi(:a0, :a0, 0xFF),
      RV32.slli(:t0, :t0, 4),
      zero(:a0, :t1),
      RV32.or_(:s1, :t0, :t1),
      RV32.ret()
    ]
  end

  defp rr do
    [
      Asm.label(label(:rr)),
      carry_in(:t1),
      RV32.andi(:t0, :a0, 1),
      RV32.srli(:a0, :a0, 1),
      RV32.slli(:t1, :t1, 7),
      RV32.or_(:a0, :a0, :t1),
      RV32.slli(:t0, :t0, 4),
      zero(:a0, :t1),
      RV32.or_(:s1, :t0, :t1),
      RV32.ret()
    ]
  end

  defp sla do
    [
      Asm.label(label(:sla)),
      RV32.srli(:t0, :a0, 7),
      RV32.slli(:a0, :a0, 1),
      RV32.andi(:a0, :a0, 0xFF),
      RV32.slli(:t0, :t0, 4),
      zero(:a0, :t1),
      RV32.or_(:s1, :t0, :t1),
      RV32.ret()
    ]
  end

  # SRA replicates bit 7: the sign survives the shift.
  defp sra do
    [
      Asm.label(label(:sra)),
      RV32.andi(:t0, :a0, 1),
      RV32.andi(:t1, :a0, 0x80),
      RV32.srli(:a0, :a0, 1),
      RV32.or_(:a0, :a0, :t1),
      RV32.slli(:t0, :t0, 4),
      zero(:a0, :t1),
      RV32.or_(:s1, :t0, :t1),
      RV32.ret()
    ]
  end

  defp swap do
    [
      Asm.label(label(:swap)),
      RV32.andi(:t0, :a0, 0x0F),
      RV32.slli(:t0, :t0, 4),
      RV32.srli(:a0, :a0, 4),
      RV32.or_(:a0, :a0, :t0),
      zero(:a0, :s1),
      RV32.ret()
    ]
  end

  defp srl do
    [
      Asm.label(label(:srl)),
      RV32.andi(:t0, :a0, 1),
      RV32.srli(:a0, :a0, 1),
      RV32.slli(:t0, :t0, 4),
      zero(:a0, :t1),
      RV32.or_(:s1, :t0, :t1),
      RV32.ret()
    ]
  end

  # ══ BIT n ════════════════════════════════════════════════════════════════════
  #
  # Eight routines rather than one parameterised: the bit number is a
  # compile-time constant in the 64 opcodes that use it, so the mask is baked
  # into the code and no register has to carry it. Z receives the bit's inverse,
  # H is set, C is preserved, the value is not written.

  defp bits do
    for n <- 0..7 do
      [
        Asm.label(bit_label(n)),
        RV32.andi(:t0, :a0, 1 <<< n),
        RV32.sltiu(:t0, :t0, 1),
        RV32.slli(:t0, :t0, 7),
        RV32.ori(:t0, :t0, @h),
        RV32.andi(:t1, :s1, @c),
        RV32.or_(:s1, :t0, :t1),
        RV32.ret()
      ]
    end
  end

  # ══ The shared pieces ════════════════════════════════════════════════════════

  # The incoming carry, reduced to 0 or 1.
  defp carry_in(dest) do
    [RV32.andi(dest, :s1, @c), RV32.srli(dest, dest, 4)]
  end

  # Z, set when `source`'s low eight bits are zero.
  defp zero(source, dest) do
    [
      RV32.andi(dest, source, 0xFF),
      RV32.sltiu(dest, dest, 1),
      RV32.slli(dest, dest, 7)
    ]
  end
end
