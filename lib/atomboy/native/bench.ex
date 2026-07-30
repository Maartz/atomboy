defmodule Atomboy.Native.Bench do
  @moduledoc """
  The flag differential test: `Atomboy.Native.ALU` against `Atomboy.CPU.ALU`,
  over the whole input space.

  ## Why exhaustive rather than by example

  `ADC`'s half-carry has a faulty case when the low nibbles sum to exactly `0xF`
  and the carry comes in at 1: one case in 4096. `DAA` has corners nobody
  guesses. A handful of examples lets those bugs through, and they only surface
  months later, far from their cause. Comparing the two implementations over
  **every** input takes the question off the table.

  ## The comparison happens inside the guest

  892,928 cases at two or three bytes make nearly two megabytes to push through
  an emulated serial port, one byte at a time. So the image carries the expected
  results, computed in Elixir by `Atomboy.CPU.ALU`, and the guest returns only
  the **divergences**: ten bytes per divergence, two bytes when all is well. The
  image grows, which costs nothing; the output shrinks, which cost everything.

  A divergence names the routine, the case index, what was produced and what was
  expected -- enough to reconstruct the input without re-running anything.

  ## What is exhaustive, and what is not

  Exhaustive: the two-byte operations (65536 cases), those on one byte and F
  (4096 cases), the eight `BIT n`. `ADC` and `SBC` are swept twice over all
  `(a, v)`, with F at `0x00` then at `0xF0` -- both carry states, and enough to
  catch a routine reading N, H or Z by mistake.

  Swept, not exhaustive: `ADD HL, rr` and `ADD SP, r8`, whose input space is
  2^32. There the second operand is derived from the first by a mix of shifts
  and exclusive-ors, covering 65536 well-spread pairs. The SM83 vectors pick
  them up later.
  """

  import Bitwise

  alias Atomboy.CPU.ALU, as: Oracle
  alias Atomboy.Native.ALU
  alias Atomboy.Native.Asm
  alias Atomboy.Native.Image
  alias Atomboy.Native.Qemu
  alias Atomboy.Native.RV32

  @divergence_magic 0xE7
  @stop 0xFF
  @max_divergences 16
  @divergence_size 10

  # ══ The sweeps ═══════════════════════════════════════════════════════════════

  @byte_and_f 4096
  @two_bytes 65536

  @doc """
  The sweeps, as data -- name, target routine, call shape, number of cases.

  Order matters: it is the index the guest returns in a divergence.
  """
  @spec sweeps() :: [map()]
  def sweeps do
    acc = [:add, :sub, :cp, :bit_and, :bit_xor, :bit_or]
    byte = [:inc, :dec, :rlc, :rrc, :rl, :rr, :sla, :sra, :swap, :srl]
    accumulator = [:rlca, :rrca, :rla, :rra, :daa, :cpl, :scf, :ccf]

    for(name <- acc, do: %{name: name, shape: :acc, f: 0x00, cases: @two_bytes}) ++
      for(
        name <- [:adc, :sbc],
        f <- [0x00, 0xF0],
        do: %{name: name, shape: :acc, f: f, cases: @two_bytes}
      ) ++
      for(name <- byte, do: %{name: name, shape: :byte, cases: @byte_and_f}) ++
      for(name <- accumulator, do: %{name: name, shape: :accumulator, cases: @byte_and_f}) ++
      for(n <- 0..7, do: %{name: :"bit_#{n}", bit: n, shape: :byte, cases: @byte_and_f}) ++
      [
        %{name: :add16, shape: :word16, cases: @two_bytes},
        %{name: :add_sp, shape: :add_sp, cases: @two_bytes}
      ]
  end

  @doc "The label of the routine a sweep targets."
  @spec label(map()) :: atom()
  def label(%{bit: n}), do: ALU.bit_label(n)
  def label(%{name: name}), do: ALU.label(name)

  # ══ What the oracle expects ══════════════════════════════════════════════════

  @doc """
  A case's inputs, derived from its index.

  The same formulas as the code emitted for the guest. The two agreeing needs no
  separate test: the expectation is computed from Elixir's derivation and the
  result produced from the guest's, so a disagreement makes them diverge.
  """
  @spec inputs(map(), non_neg_integer()) :: map()
  def inputs(%{shape: :acc, f: f}, i), do: %{a: i >>> 8, v: i &&& 0xFF, f: f}

  def inputs(%{shape: shape}, i) when shape in [:byte, :accumulator],
    do: %{v: i >>> 4, f: (i &&& 0x0F) <<< 4}

  def inputs(%{shape: :word16}, i),
    do: %{hl: i, v: mix16(i), f: (i &&& 0x0F) <<< 4}

  def inputs(%{shape: :add_sp}, i), do: %{sp: i, v: mix8(i), f: 0}

  @doc "The mix producing `ADD HL, rr`'s second 16-bit operand."
  @spec mix16(non_neg_integer()) :: 0..0xFFFF
  def mix16(i), do: bxor(bxor(i <<< 7, i >>> 3), 0x5A5A) &&& 0xFFFF

  @doc "The mix producing `ADD SP, r8`'s offset."
  @spec mix8(non_neg_integer()) :: 0..0xFF
  def mix8(i), do: bxor(i <<< 3, i >>> 5) &&& 0xFF

  @doc """
  A case's expected result: `{value, flags}`.

  The value is the one read back from the register after the call -- so the
  unchanged input for `CP`, `BIT` and `SCF`, which write only F.
  """
  @spec expected(map(), non_neg_integer()) :: {non_neg_integer(), 0..0xFF}
  def expected(%{name: :cp} = b, i) do
    %{a: a, v: v} = inputs(b, i)
    {a, Oracle.cp(a, v)}
  end

  def expected(%{bit: n} = b, i) do
    %{v: v, f: f} = inputs(b, i)
    {v, Oracle.bit_test(n, v, f)}
  end

  def expected(%{shape: :acc, name: name} = b, i) do
    %{a: a, v: v, f: f} = inputs(b, i)

    case name do
      n when n in [:adc, :sbc] -> apply(Oracle, n, [a, f, v])
      n -> apply(Oracle, n, [a, v])
    end
  end

  def expected(%{shape: shape, name: name} = b, i) when shape in [:byte, :accumulator] do
    %{v: v, f: f} = inputs(b, i)
    apply(Oracle, name, [v, f])
  end

  def expected(%{shape: :word16} = b, i) do
    %{hl: hl, v: v, f: f} = inputs(b, i)
    Oracle.add16(hl, v, f)
  end

  def expected(%{shape: :add_sp} = b, i) do
    %{sp: sp, v: v} = inputs(b, i)
    Oracle.add_sp(sp, v)
  end

  @doc "A whole sweep's expected bytes -- two per case, three for 16-bit shapes."
  @spec expectations(map()) :: binary()
  def expectations(sweep) do
    wide? = sweep.shape in [:word16, :add_sp]

    0..(sweep.cases - 1)
    |> Enum.map(fn i ->
      {value, f} = expected(sweep, i)
      if wide?, do: <<value::16-little, f>>, else: <<value, f>>
    end)
    |> IO.iodata_to_binary()
  end

  # ══ The run ══════════════════════════════════════════════════════════════════

  @doc """
  Builds and runs the bench; returns the list of divergences.

  An empty list means the two implementations are indistinguishable over
  everything swept.
  """
  @spec run(keyword()) :: {:ok, [map()]} | {:error, term()}
  def run(opts \\ []) do
    image = image()

    case Qemu.run(image.code, Keyword.put_new(opts, :timeout, 120_000)) do
      %{status: :timeout, duration_us: us} -> {:error, {:timeout, us}}
      %{status: :ok, serial: serial} -> decode(serial)
    end
  end

  @doc "The bench image: the routines, the sweep drivers, and the expectations."
  @spec image() :: Asm.assembled()
  def image do
    sweeps = sweeps()

    Image.build(
      [
        preamble(),
        sweeps |> Enum.with_index() |> Enum.map(&driver/1),
        Asm.label(:bench_done),
        RV32.li(:a0, @stop),
        Asm.call(:putc),
        RV32.mv(:a0, :s10),
        Asm.call(:putc),
        Asm.j(:poweroff),
        ALU.routines()
      ],
      data(sweeps)
    )
  end

  defp preamble do
    [
      RV32.li(:s8, 0xFFFF),
      Asm.la(:s9, :expectations),
      RV32.li(:s10, 0)
    ]
  end

  # ══ One sweep driver ═════════════════════════════════════════════════════════

  defp driver({sweep, index}) do
    loop = :"sweep_#{index}_loop"
    diverged = :"sweep_#{index}_diverged"
    next = :"sweep_#{index}_next"
    wide? = sweep.shape in [:word16, :add_sp]

    [
      RV32.li(:t6, 0),
      RV32.li(:s2, sweep.cases),
      Asm.label(loop),
      input(sweep),
      Asm.call(label(sweep)),
      RV32.mv(:t4, result_reg(sweep.shape)),
      read_expected(wide?),
      Asm.bne(:t4, :t2, diverged),
      Asm.bne(:s1, :t3, diverged),
      Asm.j(next),
      Asm.label(diverged),
      report(index),
      RV32.addi(:s10, :s10, 1),
      RV32.li(:t0, @max_divergences),
      Asm.blt(:s10, :t0, next),
      Asm.j(:bench_done),
      Asm.label(next),
      RV32.addi(:t6, :t6, 1),
      Asm.bne(:t6, :s2, loop)
    ]
  end

  # The inputs, derived from t6 -- the exact mirror of `inputs/2`. The two
  # derivations agreeing needs no separate test: the expectation is computed
  # from Elixir's and the result produced from this one, so a disagreement makes
  # them diverge. Including for operations that ignore their operand -- `SCF`
  # returns A unchanged, so A is compared anyway.
  defp input(%{shape: :acc, f: f}) do
    [
      RV32.srli(:s0, :t6, 8),
      RV32.andi(:a0, :t6, 0xFF),
      RV32.li(:s1, f)
    ]
  end

  defp input(%{shape: :byte}) do
    [
      RV32.srli(:a0, :t6, 4),
      RV32.andi(:s1, :t6, 0x0F),
      RV32.slli(:s1, :s1, 4)
    ]
  end

  defp input(%{shape: :accumulator}) do
    [
      RV32.srli(:s0, :t6, 4),
      RV32.andi(:s1, :t6, 0x0F),
      RV32.slli(:s1, :s1, 4)
    ]
  end

  defp input(%{shape: :word16}) do
    [
      RV32.mv(:a2, :t6),
      mix(7, 3, 0x5A5A),
      RV32.and_(:a0, :t0, :s8),
      RV32.andi(:s1, :t6, 0x0F),
      RV32.slli(:s1, :s1, 4)
    ]
  end

  defp input(%{shape: :add_sp}) do
    [
      RV32.mv(:a0, :t6),
      mix(3, 5, nil),
      RV32.andi(:a1, :t0, 0xFF),
      RV32.li(:s1, 0)
    ]
  end

  defp mix(left, right, salt) do
    [
      RV32.slli(:t0, :t6, left),
      RV32.srli(:t1, :t6, right),
      RV32.xor_(:t0, :t0, :t1),
      if salt do
        [RV32.li(:t1, salt), RV32.xor_(:t0, :t0, :t1)]
      else
        []
      end
    ]
  end

  defp result_reg(:acc), do: :s0
  defp result_reg(:accumulator), do: :s0
  defp result_reg(:byte), do: :a0
  defp result_reg(:word16), do: :a2
  defp result_reg(:add_sp), do: :a0

  defp read_expected(false) do
    [
      RV32.lbu(:t2, :s9, 0),
      RV32.lbu(:t3, :s9, 1),
      RV32.addi(:s9, :s9, 2)
    ]
  end

  defp read_expected(true) do
    [
      RV32.lbu(:t2, :s9, 0),
      RV32.lbu(:t5, :s9, 1),
      RV32.slli(:t5, :t5, 8),
      RV32.or_(:t2, :t2, :t5),
      RV32.lbu(:t3, :s9, 2),
      RV32.addi(:s9, :s9, 3)
    ]
  end

  # `putc` only clobbers t0, t1 and a0: t2, t3, t4, t6 and s1 cross the report
  # intact, which saves pushing them on the stack.
  defp report(index) do
    [
      byte_out(RV32.li(:a0, @divergence_magic)),
      byte_out(RV32.li(:a0, index)),
      byte_out(RV32.mv(:a0, :t6)),
      byte_out(RV32.srli(:a0, :t6, 8)),
      byte_out(RV32.mv(:a0, :t4)),
      byte_out(RV32.srli(:a0, :t4, 8)),
      byte_out(RV32.mv(:a0, :s1)),
      byte_out(RV32.mv(:a0, :t2)),
      byte_out(RV32.srli(:a0, :t2, 8)),
      byte_out(RV32.mv(:a0, :t3))
    ]
  end

  defp byte_out(load), do: [load, Asm.call(:putc)]

  # ══ The data ═════════════════════════════════════════════════════════════════

  defp data(sweeps) do
    [
      {:align, 4},
      Asm.label(:expectations),
      Enum.map(sweeps, &expectations/1)
    ]
  end

  # ══ The decoding ═════════════════════════════════════════════════════════════

  defp decode(serial) do
    read_divergences(serial, sweeps(), [])
  end

  defp read_divergences(<<@stop, _count, _rest::binary>>, _sweeps, acc),
    do: {:ok, Enum.reverse(acc)}

  defp read_divergences(
         <<@divergence_magic, index, case_index::16-little, got::16-little, flags,
           want::16-little, want_flags, rest::binary>>,
         sweeps,
         acc
       ) do
    sweep = Enum.at(sweeps, index)

    divergence = %{
      sweep: sweep.name,
      case_index: case_index,
      inputs: inputs(sweep, case_index),
      got: {got, flags},
      expected: {want, want_flags}
    }

    read_divergences(rest, sweeps, [divergence | acc])
  end

  defp read_divergences(other, _sweeps, _acc) do
    {:error,
     {:unreadable_stream, byte_size(other), binary_part(other, 0, min(32, byte_size(other)))}}
  end

  @doc "The size of a divergence record, for protocol tests."
  @spec divergence_size() :: pos_integer()
  def divergence_size, do: @divergence_size
end
