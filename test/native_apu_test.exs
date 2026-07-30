defmodule Atomboy.NativeAPUTest do
  @moduledoc """
  The native APU against the Elixir one, sample for sample.

  Three statements, in increasing order of how much they prove:

    * **the encoder is its own inverse** -- a bench whose state encoding is wrong
      reports divergences that belong to the bench;
    * **the directed cases** -- one per DMG rule, so a failure names the rule
      rather than a byte offset;
    * **the random states** -- random registers over random channel state, which
      is what finds the rules nobody wrote down.

  All three compare against `Atomboy.APU`, which is the oracle for the same
  reason it is the oracle for the renderer: it is the implementation that has
  been listened to.

  ## The negative control

  Worth recording, because a differential bench that cannot fail is worse than
  none. Flipping one bit of one duty cycle in `Atomboy.Native.APU` -- step three
  of the third cycle, 0 to 1 -- makes exactly the cases that select that duty
  diverge, at the byte where the two waveforms first part company, and leaves
  every other case at zero. Restoring it returns the suite to silence.

  ## What it costs, measured

  Twenty-seven directed cases, some running four thousand samples to watch an
  envelope decay: 609 ms under qemu, most of it the emulated UART carrying 110 KB
  of samples a byte at a time.

      code   2,420 bytes of generated RV32, against the C6's 32 KB of icache
      data     348 bytes: 144 of state, 156 frozen per frame, 48 of tables
  """

  use ExUnit.Case, async: true

  alias Atomboy.APU
  alias Atomboy.Native.APUBench

  @moduletag :qemu
  @moduletag timeout: 900_000

  describe "the state encoding" do
    test "encode and decode are inverses over a random state" do
      cases = APUBench.random_cases(24, 20_260_731)

      for %{state: state} <- cases do
        assert state
               |> APUBench.encode_state()
               |> APUBench.decode_state() == state
      end
    end

    test "a fresh APU survives the round trip" do
      assert %APU{} |> APUBench.encode_state() |> APUBench.decode_state() == %APU{}
    end
  end

  describe "the differential bench" do
    test "no divergence on the directed cases" do
      {names, cases} = APUBench.directed_cases()

      assert {:ok, report} = APUBench.run(cases, timeout: 300_000)

      assert report.divergences == [], """
      #{length(report.divergences)} divergence(s) between Atomboy.Native.APU and Atomboy.APU:

      #{format(report.divergences, names)}
      """

      assert report.leftover == 0, "the guest sent #{report.leftover} bytes nobody asked for"
    end

    test "no divergence over random registers and random channel state" do
      cases = APUBench.random_cases(64, 20_260_730)

      assert {:ok, report} = APUBench.run(cases, timeout: 300_000)

      assert report.divergences == [], """
      #{length(report.divergences)} divergence(s) on random states:

      #{format(report.divergences, [])}

      #{inputs(report.divergences, cases)}
      """
    end
  end

  defp format(divergences, names) do
    Enum.map_join(divergences, "\n", fn divergence ->
      name =
        case Enum.at(names, divergence.index) do
          nil -> "case #{divergence.index}"
          name -> "#{divergence.index}: #{name}"
        end

      samples =
        case divergence[:samples] do
          nil -> "samples agree"
          offset -> "first byte differing: #{offset}"
        end

      state =
        case divergence[:state] do
          [] -> "state agrees"
          fields -> "state: #{inspect(fields, limit: 12)}"
        end

      "  #{name}\n    #{samples}\n    #{state}"
    end)
  end

  defp inputs([], _cases), do: ""

  defp inputs(divergences, cases) do
    Enum.map_join(divergences, "\n", fn divergence ->
      bench_case = Enum.at(cases, divergence.index)

      "  case #{divergence.index}: count=#{bench_case.count} " <>
        "triggers=#{inspect(bench_case.triggers)}\n" <>
        "    registers 0xFF10-0xFF3F: #{Base.encode16(bench_case.registers)}"
    end)
  end
end
