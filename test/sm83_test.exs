defmodule Atomboy.SM83Test do
  @moduledoc """
  One ExUnit test per implemented opcode, replaying the corpus's ~1,000 vectors.

  The granularity is deliberate: one test per opcode, not one test per vector.
  500,000 ExUnit tests would cost more in framework overhead than in emulation, and
  the useful grain is the opcode — it is the unit you write, and the unit you fix.

  The list of tests is derived from `Atomboy.CPU.implemented/0`, which is itself
  accumulated by the decoder's clauses at compile time. An added opcode is
  therefore tested without anyone having to register anything here — and there is
  no state in which the decoder moves forward without the tests following.
  """

  use ExUnit.Case, async: true

  alias Atomboy.SingleStep

  if SingleStep.corpus?() do
    available = SingleStep.available_opcodes()
    implemented = Atomboy.CPU.implemented()

    for {prefix, opcode} <- implemented, MapSet.member?(available, {prefix, opcode}) do
      test "opcode #{SingleStep.file_name(prefix, opcode)}" do
        prefix = unquote(prefix)
        opcode = unquote(opcode)

        {total, failures} = SingleStep.run(prefix, opcode)

        assert total > 0, "no vectors loaded for #{SingleStep.file_name(prefix, opcode)}"

        # `assert/2` evaluates its message even when the assertion holds: the
        # formatter must only be called on a real failure.
        if failures != [] do
          flunk(SingleStep.format_failures(prefix, opcode, total, failures))
        end
      end
    end

    # An implemented opcode with no vector file is an invented opcode — with one
    # exception: 0xCB is the extended table's prefix, it will indeed be implemented
    # and will never have vectors of its own.
    for {prefix, opcode} <- implemented,
        not MapSet.member?(available, {prefix, opcode}),
        {prefix, opcode} != {nil, Mix.Tasks.Atomboy.Corpus.prefix_opcode()} do
      test "opcode #{SingleStep.file_name(prefix, opcode)} does not exist on the SM83" do
        flunk("""
        #{SingleStep.file_name(unquote(prefix), unquote(opcode))} is implemented in \
        Atomboy.CPU but has no vector file.

        The eleven encodings 0xD3, 0xDB, 0xDD, 0xE3, 0xE4, 0xEB, 0xEC, 0xED, 0xF4, \
        0xFC and 0xFD are invalid on the SM83 — they lock the CPU up. If this one is \
        among them, the clause probably came from a Z80 table.
        """)
      end
    end
  else
    IO.warn(
      """
      SingleStepTests corpus missing — the CPU tests are not generated.

          mix atomboy.corpus
      """,
      []
    )
  end
end
