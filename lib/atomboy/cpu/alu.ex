defmodule Atomboy.CPU.ALU do
  @moduledoc """
  The SM83's eight arithmetic and logic operations, with their flags.

  Written by hand, not generated. `Atomboy.CPU.Gen` handles the *structure* —
  which opcode calls what on which operand; the flag semantics live here, in
  readable Elixir. Emitting this computation as AST would make it unreadable
  exactly where it most needs rereading: flags are where emulators get things
  wrong, and where the mistake stays invisible longest.

  ## Value level, not state level

  The functions take and return bytes: `add(a, v) → {result, f}`. They know
  nothing of `Atomboy.CPU.State` — which is what lets the two generated backends
  share the same arithmetic:

    * the struct backend (`Atomboy.CPU.exec/3`, the oracle) wraps the result in a
      struct update;
    * the fast loop (`Atomboy.CPU.Loop`) passes it as a tail-call argument,
      building nothing.

  A single place computes the half-carry; no backend keeps a copy of it. A third
  consumer is planned: phase 5's recompiled code will call these same
  primitives — recompilation removes the fetch, the decode and the dispatch, not
  the flag arithmetic.

  ## The F register

  Four high bits, the other four always zero:

      Z (0x80)  result is zero
      N (0x40)  the last operation was a subtraction
      H (0x20)  carry between bit 3 and bit 4
      C (0x10)  carry out

  `N` and `H` exist only for `DAA`, which has to know after the fact whether the
  operation was an addition or a subtraction and whether the low nibble
  overflowed. That is why they must be set correctly even while nothing reads
  them yet: the bug will only show up when `DAA` is implemented, a long way from
  here.

  ## The half-carry trap

  For `ADC` and `SBC`, **the incoming carry counts towards `H`**.

      H of ADC = (a & 0xF) + (v & 0xF) + carry > 0xF

  Forgetting it lets the vast majority of cases through — the nibble sum has to
  land exactly on 0xF with the carry coming in set — and breaks `DAA` much later,
  when nobody is looking in this direction any more. The SingleStepTests vectors
  cover that case; it is precisely why they come before blargg's ROMs.
  """

  import Bitwise

  @z 0x80
  @n 0x40
  @h 0x20
  @c 0x10

  @type byte8 :: 0..0xFF
  @typedoc "The result of an operation that writes A: `{new A, new F}`."
  @type result :: {byte8(), byte8()}

  @doc "ADD A, v — addition."
  @spec add(byte8(), byte8()) :: result()
  def add(a, value) do
    sum = a + value
    {sum &&& 0xFF, add_flags(a, value, 0, sum)}
  end

  @doc "ADC A, v — addition with the incoming carry taken from `f`."
  @spec adc(byte8(), byte8(), byte8()) :: result()
  def adc(a, f, value) do
    carry = carry_in(f)
    sum = a + value + carry
    {sum &&& 0xFF, add_flags(a, value, carry, sum)}
  end

  @doc "SUB v — subtraction."
  @spec sub(byte8(), byte8()) :: result()
  def sub(a, value) do
    {a - value &&& 0xFF, sub_flags(a, value, 0)}
  end

  @doc "SBC A, v — subtraction with the incoming borrow taken from `f`."
  @spec sbc(byte8(), byte8(), byte8()) :: result()
  def sbc(a, f, value) do
    carry = carry_in(f)
    {a - value - carry &&& 0xFF, sub_flags(a, value, carry)}
  end

  @doc """
  CP v — comparison. Returns the flags alone.

  A subtraction whose result is thrown away: hence the reuse of `sub_flags/3` —
  duplicating the computation would mean maintaining the same borrow subtlety
  twice.
  """
  @spec cp(byte8(), byte8()) :: byte8()
  def cp(a, value), do: sub_flags(a, value, 0)

  @doc """
  AND v — logical and.

  The only logical operation that sets `H`. This is not a regularity someone
  forgot; that is how the hardware behaves.
  """
  @spec bit_and(byte8(), byte8()) :: result()
  def bit_and(a, value) do
    result = a &&& value
    {result, zero(result) ||| @h}
  end

  @doc "XOR v — exclusive or. Every flag except Z is cleared."
  @spec bit_xor(byte8(), byte8()) :: result()
  def bit_xor(a, value) do
    result = bxor(a, value)
    {result, zero(result)}
  end

  @doc "OR v — logical or. Every flag except Z is cleared."
  @spec bit_or(byte8(), byte8()) :: result()
  def bit_or(a, value) do
    result = a ||| value
    {result, zero(result)}
  end

  @doc """
  INC v — increment. Sets Z and H, clears N, **preserves C** from `f`.

  This is the second classic trap after the half-carry: setting all four flags out
  of reflex. On the hardware, INC and DEC leave the carry strictly untouched —
  games' `OR A / INC / JR C` idiom depends on it. Hence the signature: `f` goes
  in, so that the C bit can come back out.
  """
  @spec inc(byte8(), byte8()) :: result()
  def inc(value, f) do
    result = value + 1 &&& 0xFF
    half = if (value &&& 0x0F) == 0x0F, do: @h, else: 0
    {result, zero(result) ||| half ||| (f &&& @c)}
  end

  @doc "DEC v — decrement. Sets Z, N and H (borrow), **preserves C**."
  @spec dec(byte8(), byte8()) :: result()
  def dec(value, f) do
    result = value - 1 &&& 0xFF
    half = if (value &&& 0x0F) == 0x00, do: @h, else: 0
    {result, zero(result) ||| @n ||| half ||| (f &&& @c)}
  end

  @doc """
  ADD HL, rr — 16-bit addition.

  INC's mirror image: here it is **Z that is preserved** and C that moves. H is
  computed at bit 11 (the carry between the word's two high nibbles), C at bit
  15. N is cleared.
  """
  @spec add16(0..0xFFFF, 0..0xFFFF, byte8()) :: {0..0xFFFF, byte8()}
  def add16(hl, value, f) do
    sum = hl + value
    half = if (hl &&& 0x0FFF) + (value &&& 0x0FFF) > 0x0FFF, do: @h, else: 0
    carry = if sum > 0xFFFF, do: @c, else: 0
    {sum &&& 0xFFFF, (f &&& @z) ||| half ||| carry}
  end

  @doc """
  ADD SP, r8 and LD HL, SP+r8 — adding a signed offset to SP.

  The most counter-intuitive flags on the processor: a 16-bit operation whose
  flags are computed **on the low byte, as an unsigned 8-bit addition** — H at
  bit 3, C at bit 7 — with Z always cleared, even when the result is zero. The
  offset is signed for the result, unsigned for the flags.
  """
  @spec add_sp(0..0xFFFF, byte8()) :: {0..0xFFFF, byte8()}
  def add_sp(sp, offset) do
    half = if (sp &&& 0x0F) + (offset &&& 0x0F) > 0x0F, do: @h, else: 0
    carry = if (sp &&& 0xFF) + offset > 0xFF, do: @c, else: 0
    signed = offset - bsl(bsr(offset, 7), 8)
    {sp + signed &&& 0xFFFF, half ||| carry}
  end

  # ── Operations on the accumulator alone (the table's z=7 column) ────────────
  #
  # All with the signature `(a, f) → {a, f}`, even the ones that ignore one of
  # the two: the uniformity lets the generator handle them in a single clause.

  @doc """
  RLCA — rotate A left circularly. C receives the old bit 7.

  Z is **always cleared**, even when the result is zero — unlike the CB table's
  `RLC A`, which sets Z normally. Two instructions, two encodings, two Z
  semantics: a classic source of confusion.
  """
  @spec rlca(byte8(), byte8()) :: result()
  def rlca(a, _f) do
    bit7 = bsr(a, 7)
    {(bsl(a, 1) ||| bit7) &&& 0xFF, bit7 * @c}
  end

  @doc "RRCA — rotate right circularly. C receives the old bit 0, Z is cleared."
  @spec rrca(byte8(), byte8()) :: result()
  def rrca(a, _f) do
    bit0 = a &&& 1
    {bsr(a, 1) ||| bsl(bit0, 7), bit0 * @c}
  end

  @doc "RLA — rotate left through C: C comes in at bit 0, leaves from bit 7."
  @spec rla(byte8(), byte8()) :: result()
  def rla(a, f) do
    {(bsl(a, 1) ||| carry_in(f)) &&& 0xFF, bsr(a, 7) * @c}
  end

  @doc "RRA — rotate right through C."
  @spec rra(byte8(), byte8()) :: result()
  def rra(a, f) do
    {bsr(a, 1) ||| bsl(carry_in(f), 7), (a &&& 1) * @c}
  end

  @doc """
  DAA — decimal adjust after a BCD operation.

  The most twisted instruction on the processor, and the reason the N and H flags
  are set so carefully everywhere else: DAA is their *only* reader. After an
  addition (N=0), 0x06 and/or 0x60 are added back depending on H, C and the
  value; after a subtraction (N=1), they are taken away depending on H and C
  alone — A's value plays no part, that is simply how it is. C is **never
  cleared** by DAA, only set.
  """
  @spec daa(byte8(), byte8()) :: result()
  def daa(a, f) do
    n = (f &&& @n) != 0
    h = (f &&& @h) != 0
    c = (f &&& @c) != 0

    {a, c} =
      if n do
        low = if h, do: 0x06, else: 0
        high = if c, do: 0x60, else: 0
        {a - low - high &&& 0xFF, c}
      else
        low = if h or (a &&& 0x0F) > 0x09, do: 0x06, else: 0
        high = if c or a > 0x99, do: 0x60, else: 0
        {a + low + high &&& 0xFF, c or high > 0}
      end

    {a, zero(a) ||| if(n, do: @n, else: 0) ||| if(c, do: @c, else: 0)}
  end

  @doc "CPL — complement of A. Sets N and H, preserves Z and C."
  @spec cpl(byte8(), byte8()) :: result()
  def cpl(a, f) do
    {bxor(a, 0xFF), (f &&& (@z ||| @c)) ||| @n ||| @h}
  end

  @doc "SCF — sets C. Clears N and H, preserves Z. A unchanged."
  @spec scf(byte8(), byte8()) :: result()
  def scf(a, f), do: {a, (f &&& @z) ||| @c}

  @doc "CCF — flips C. Clears N and H, preserves Z. A unchanged."
  @spec ccf(byte8(), byte8()) :: result()
  def ccf(a, f), do: {a, (f &&& @z) ||| bxor(f &&& @c, @c)}

  # ── Rotations and shifts from the CB table ──────────────────────────────────
  #
  # Unlike the rotations of A (RLCA & co) which always clear Z, these set it
  # normally. Same `(v, f) → {v, f}` signature as the rest, so that the generator
  # handles them in one clause.

  @doc "RLC — rotate left circularly. C receives bit 7, Z behaves normally."
  @spec rlc(byte8(), byte8()) :: result()
  def rlc(value, _f) do
    bit7 = bsr(value, 7)
    result = (bsl(value, 1) ||| bit7) &&& 0xFF
    {result, zero(result) ||| bit7 * @c}
  end

  @doc "RRC — rotate right circularly. C receives bit 0."
  @spec rrc(byte8(), byte8()) :: result()
  def rrc(value, _f) do
    bit0 = value &&& 1
    result = bsr(value, 1) ||| bsl(bit0, 7)
    {result, zero(result) ||| bit0 * @c}
  end

  @doc "RL — rotate left through C."
  @spec rl(byte8(), byte8()) :: result()
  def rl(value, f) do
    result = (bsl(value, 1) ||| carry_in(f)) &&& 0xFF
    {result, zero(result) ||| bsr(value, 7) * @c}
  end

  @doc "RR — rotate right through C."
  @spec rr(byte8(), byte8()) :: result()
  def rr(value, f) do
    result = bsr(value, 1) ||| bsl(carry_in(f), 7)
    {result, zero(result) ||| (value &&& 1) * @c}
  end

  @doc "SLA — arithmetic left shift. Bit 0 comes in as zero."
  @spec sla(byte8(), byte8()) :: result()
  def sla(value, _f) do
    result = bsl(value, 1) &&& 0xFF
    {result, zero(result) ||| bsr(value, 7) * @c}
  end

  @doc "SRA — arithmetic right shift. Bit 7 is **replicated** — the sign survives."
  @spec sra(byte8(), byte8()) :: result()
  def sra(value, _f) do
    result = bsr(value, 1) ||| (value &&& 0x80)
    {result, zero(result) ||| (value &&& 1) * @c}
  end

  @doc "SWAP — exchanges the two nibbles. Z is the only flag that can rise."
  @spec swap(byte8(), byte8()) :: result()
  def swap(value, _f) do
    result = bsl(value &&& 0x0F, 4) ||| bsr(value, 4)
    {result, zero(result)}
  end

  @doc "SRL — logical right shift. Bit 7 comes in as zero."
  @spec srl(byte8(), byte8()) :: result()
  def srl(value, _f) do
    result = bsr(value, 1)
    {result, zero(result) ||| (value &&& 1) * @c}
  end

  @doc """
  BIT n — tests one bit: Z receives its inverse, N clears, H is set, **C is
  preserved**. The value is not written back.
  """
  @spec bit_test(0..7, byte8(), byte8()) :: byte8()
  def bit_test(n, value, f) do
    z = if (value &&& bsl(1, n)) == 0, do: @z, else: 0
    z ||| @h ||| (f &&& @c)
  end

  # ── Flags ───────────────────────────────────────────────────────────────────

  # The incoming carry, brought down to 0 or 1.
  defp carry_in(f), do: bsr(f &&& @c, 4)

  defp add_flags(a, value, carry, sum) do
    # The incoming carry takes part in the half-carry — see the moduledoc.
    half = if (a &&& 0x0F) + (value &&& 0x0F) + carry > 0x0F, do: @h, else: 0
    full = if sum > 0xFF, do: @c, else: 0
    zero(sum) ||| half ||| full
  end

  defp sub_flags(a, value, carry) do
    # In subtraction, H and C signal a *borrow*: the nibble, then the byte, go
    # below zero. The incoming borrow adds to the subtrahend.
    half = if (a &&& 0x0F) < (value &&& 0x0F) + carry, do: @h, else: 0
    full = if a < value + carry, do: @c, else: 0
    zero(a - value - carry) ||| @n ||| half ||| full
  end

  # `result` may be negative: `&&& 0xFF` takes its two's complement, which is
  # exactly the byte the hardware would have produced.
  defp zero(result), do: if((result &&& 0xFF) == 0, do: @z, else: 0)
end
