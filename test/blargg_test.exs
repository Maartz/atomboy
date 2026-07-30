defmodule Atomboy.BlarggTest do
  @moduledoc """
  The individual blargg `cpu_instrs` ROMs — phase 1's integration test.

  The SM83 vectors validate each instruction in isolation; blargg validates
  the whole thing in situ: chained instructions, the stack, DAA after real BCD
  sequences, computed jumps. It is the brief's end-of-phase-1 criterion.

  Left out of the ordinary `mix test` (~30 s more):

      mix test --include blargg

  `02-interrupts` is skipped for as long as the interrupt controller does not
  exist — that is the next phase's first job, not an oversight.
  """

  use ExUnit.Case, async: true

  @moduletag :blargg
  @moduletag timeout: 300_000

  alias Mix.Tasks.Atomboy.Corpus

  if Corpus.cpu_instrs_roms() == [] do
    IO.warn("blargg ROMs missing — `mix atomboy.corpus` to fetch them.", [])
  end

  for rom <- Corpus.cpu_instrs_roms() do
    name = Path.basename(rom, ".gb")

    test name do
      case Atomboy.Blargg.run(unquote(rom)) do
        {:passed, _report} ->
          :ok

        {:failed, report} ->
          flunk("failed:\n#{report}")

        {:timeout, report} ->
          flunk("no verdict before the cycle limit:\n#{report}")
      end
    end
  end
end
