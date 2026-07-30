defmodule Atomboy.Native.Regs do
  @moduledoc """
  Where each SM83 register lives among the RISC-V 32.

  The only module that knows. Everything above says `read8({:reg, :h}, :t0)`
  and never learns that H does not exist -- that it is the high half of a
  register holding HL.

  ## The scarce resource is not the number of registers

  There are 32 for about fifteen needs. What is scarce is the `x8`-`x15`
  subset: an instruction whose operands all land there can encode in two bytes
  instead of four. We emit nothing compressed yet (see `Atomboy.Native.RV32`),
  but the day the instruction cache bites, compression will be free where the
  hot registers were placed -- and unaffordable elsewhere. Hence this map,
  decided now rather than regretted later.

  ## Three choices that are not obvious

  **`0xFFFF` takes a whole register.** `andi` only takes a 12-bit signed
  immediate: masking a byte is free, masking 16 bits is impossible. Without a
  dedicated register, every wrap -- PC, SP, HL, any address -- would cost two
  instructions instead of one.

  **HL is packed, B/C/D/E stay split.** A deliberate asymmetry with the Elixir
  backends, and the one place the native side must not imitate them. HL serves
  as an address far more often than as two bytes: every `(HL)` operand becomes
  one addition, where the split form would need a shift, an or and an addition.
  B, C, D and E go the other way -- almost always read as bytes, their paired
  forms being the rare ones.

  **F stays packed in bits 7-4.** Unpacking it would break `PUSH AF`, `DAA`,
  and above all the 1:1 contract with `Atomboy.CPU.ALU` that the exhaustive
  flag differential test depends on.

  **Two registers hold constants nothing computes.** `rom_top` and `io_base`
  bound the addresses where a store is only a store, and `Atomboy.Native.Bus`
  compares against them on every write. They land on `gp` and `tp` -- the global
  and thread pointers, which a bare-metal image has no use for -- because the
  alternative was materialising `0xFF00` on the hot path of every store, and
  `0xFF00` does not fit an immediate.
  """

  alias Atomboy.Native.RV32

  @map [
    a: :s0,
    f: :s1,
    b: :a6,
    c: :a7,
    d: :s2,
    e: :s3,
    hl: :a2,
    sp: :a3,
    pc: :a4,
    mem: :a5,
    cycles: :s4,
    budget: :s5,
    control: :s6,
    dispatch: :s7,
    mask16: :s8,
    opcode: :a1,
    rom_top: :gp,
    io_base: :tp
  ]

  for {role, register} <- @map do
    @doc "The RV32 register carrying #{role}."
    @spec unquote(role)() :: RV32.reg()
    def unquote(role)(), do: unquote(register)
  end

  @doc "The complete map, for documentation and tests."
  @spec map() :: keyword(RV32.reg())
  def map, do: @map

  @control_bits %{ime: 0x01, halted: 0x02, pending: 0x04}

  @doc """
  The control register's layout -- three booleans in one register.

  Grouping them is not register economy, there are spare ones: it is so the
  fast path of `fetch` clears all three with a single `bnez`. A game leaving
  IME off, which is the case outside an interrupt handler, then pays nothing at
  all.

  Single source: `Atomboy.Native.Emit` sets these bits, `Atomboy.Native.Interp`
  reads them and builds them from an `%Atomboy.CPU.State{}`.
  """
  @spec control_bits() :: %{ime: 1, halted: 2, pending: 4}
  def control_bits, do: @control_bits

  @doc """
  The registers a handler may use freely.

  `a1` carries the current opcode all the way through -- that is what lets
  `unknown_opcode` name it -- so it is not fair game.
  """
  @spec scratch() :: [RV32.reg()]
  def scratch, do: [:t0, :t1, :t2, :a0]

  # ══ The bytes ════════════════════════════════════════════════════════════════

  @doc """
  Reads an 8-bit SM83 register into `dest`.

  `dest` may be the carrying register itself: the read is then a useless copy,
  which the caller is free to elide.
  """
  @spec read8({:reg, atom()}, RV32.reg()) :: [binary()]
  def read8({:reg, :h}, dest), do: [RV32.srli(dest, hl(), 8)]
  def read8({:reg, :l}, dest), do: [RV32.andi(dest, hl(), 0xFF)]
  def read8({:reg, name}, dest), do: [RV32.mv(dest, direct!(name))]

  @doc """
  Writes `src` into an 8-bit SM83 register.

  `src` must already fit in eight bits. The H and L forms clobber `t1` and
  `t2`, which therefore must not carry `src`.
  """
  @spec write8({:reg, atom()}, RV32.reg()) :: [binary()]
  def write8({:reg, :h}, src) do
    guard!(:h, src, [:t1, :t2])

    [
      RV32.andi(:t1, hl(), 0xFF),
      RV32.slli(:t2, src, 8),
      RV32.or_(hl(), :t1, :t2)
    ]
  end

  def write8({:reg, :l}, src) do
    guard!(:l, src, [:t1])

    # -256 is 0xFFFFFF00 once sign-extended: the low eight bits fall, everything
    # else survives. The immediate fits in 12 signed bits, where 0xFF00 would
    # not.
    [
      RV32.andi(:t1, hl(), -256),
      RV32.or_(hl(), :t1, src)
    ]
  end

  def write8({:reg, name}, src), do: [RV32.mv(direct!(name), src)]

  # ══ The pairs ════════════════════════════════════════════════════════════════

  @doc """
  Reads a 16-bit pair into `dest`.

  `HL` and `SP` are already 16-bit registers: the read is a copy, which the
  caller may elide knowingly. `BC`, `DE` and `AF` are recomposed, which is the
  price of keeping them split -- paid on the paired forms, which are the rare
  ones.
  """
  @spec read16({:pair, atom()}, RV32.reg()) :: [binary()]
  def read16({:pair, :hl}, dest), do: [RV32.mv(dest, hl())]
  def read16({:pair, :sp}, dest), do: [RV32.mv(dest, sp())]
  def read16({:pair, :bc}, dest), do: compose(b(), c(), dest)
  def read16({:pair, :de}, dest), do: compose(d(), e(), dest)
  def read16({:pair, :af}, dest), do: compose(a(), f(), dest)

  @doc """
  Writes `src` into a 16-bit pair. `src` must already fit in sixteen bits.

  The `AF` case carries the `0xF0` mask on F: the flag register's low four bits
  do not exist on hardware, and `POP AF` is the only place an arbitrary value
  could enter them. `Atomboy.CPU.Gen` does the same (gen.ex:1441) -- the mask
  lives here rather than at the call site because `AF` is written nowhere
  else.
  """
  @spec write16({:pair, atom()}, RV32.reg()) :: [binary()]
  def write16({:pair, :hl}, src), do: [RV32.mv(hl(), src)]
  def write16({:pair, :sp}, src), do: [RV32.mv(sp(), src)]
  def write16({:pair, :bc}, src), do: decompose(b(), c(), src, 0xFF)
  def write16({:pair, :de}, src), do: decompose(d(), e(), src, 0xFF)
  def write16({:pair, :af}, src), do: decompose(a(), f(), src, 0xF0)

  defp compose(high, low, dest) do
    [RV32.slli(dest, high, 8), RV32.or_(dest, dest, low)]
  end

  defp decompose(high, low, src, mask) do
    [RV32.srli(high, src, 8), RV32.andi(low, src, mask)]
  end

  defp direct!(name) do
    case Keyword.fetch(@map, name) do
      {:ok, register} ->
        register

      :error ->
        raise ArgumentError,
              "SM83 register with no direct carrier: #{inspect(name)} -- H and L go through HL"
    end
  end

  defp guard!(name, src, forbidden) do
    if src in forbidden do
      raise ArgumentError,
            "writing #{String.upcase(to_string(name))} from #{src}: that register is a temporary here"
    end
  end
end
