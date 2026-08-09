defmodule Atomboy.Server.Universe do
  @moduledoc """
  One universe of a split, and the process that keeps it.

  A universe is a machine — the `{state, ram, apu}` trio a snapshot freezes
  — and this process owns one for as long as the split stands. The loop
  never holds it and never sends it: per frame it posts the pad, and what
  comes back is pictures. That asymmetry is the whole point.

  A memory map is a map of tens of thousands of keys, and the BEAM copies a
  map whole every time it crosses between processes. Stepping four
  universes in four short-lived tasks copied four maps in and four maps
  back out every frame — plus, through the closure, everything else the
  loop was holding, the rewind ring included. Owning the machine here costs
  one copy at the fork and one at the commit; in between, what travels is a
  pad byte one way and refcounted binaries the other, which the runtime
  passes by reference rather than by value.

  The universe does not know which one it is, nor which one is being
  listened to. It is told how many PCM samples to draw — the focused
  universe is asked for the frame's worth and the other three for none, so
  every APU still consumes its captured triggers and a switch of focus
  never lands in the middle of a note nobody played.
  """

  alias Atomboy.APU
  alias Atomboy.Codes
  alias Atomboy.CPU.CartLoop
  alias Atomboy.Joypad
  alias Atomboy.Screen

  @typedoc "The trio a snapshot freezes: registers, memory map, sound."
  @type machine :: {struct(), map(), struct()}

  @typedoc "What a stepped frame yields, or the derailment that ended it."
  @type frame ::
          {:ok, binary(), binary(), binary()} | {:derailed, Exception.t(), Exception.stacktrace()}

  @doc """
  A process holding `machine`, stepping it against `rom`. Linked: the split
  cannot outlive the loop that forked it, and a universe that dies of
  anything the step does not rescue takes the session with it, exactly as a
  task did.
  """
  @spec open(binary(), machine()) :: pid()
  def open(rom, machine), do: spawn_link(fn -> serve(rom, machine) end)

  @doc """
  One frame asked for. Returns immediately with the reference the answer
  will carry — the four are asked in turn and awaited afterwards, which is
  what puts them on four cores.
  """
  @spec step(pid(), byte(), byte(), atom(), struct(), non_neg_integer()) :: reference()
  def step(universe, dpad, btns, palette, lcd, samples) do
    ref = make_ref()
    send(universe, {:step, self(), ref, dpad, btns, palette, lcd, samples})
    ref
  end

  @doc "The answer to a `step/6`, waited for."
  @spec await(reference(), timeout()) :: frame()
  def await(ref, timeout) do
    receive do
      {^ref, frame} -> frame
    after
      timeout -> raise "a universe took longer than #{timeout} ms over one frame"
    end
  end

  @doc """
  The machine itself, copied out — the one expensive message in the
  protocol, and the reason it is asked for only when a split ends, a
  session ends, or a universe derails.
  """
  @spec machine(pid(), timeout()) :: machine()
  def machine(universe, timeout) do
    ref = make_ref()
    send(universe, {:machine, self(), ref})

    receive do
      {^ref, machine} -> machine
    after
      timeout -> raise "a universe would not say where it stood"
    end
  end

  @doc "Retired. What it was holding is gone unless it was asked for first."
  @spec close(pid()) :: :ok
  def close(universe) do
    Process.unlink(universe)
    send(universe, :close)
    :ok
  end

  defp serve(rom, machine) do
    receive do
      {:step, from, ref, dpad, btns, palette, lcd, samples} ->
        {frame, machine} = advance(rom, machine, dpad, btns, palette, lcd, samples)
        send(from, {ref, frame})
        serve(rom, machine)

      {:machine, from, ref} ->
        send(from, {ref, machine})
        serve(rom, machine)

      :close ->
        :ok
    end
  end

  # The step the single loop takes, taken here instead: the pad onto the
  # joypad lines, the codes reapplied, the frame run and rendered, and the
  # sound drawn — all of it against this universe's own map.
  #
  # A derailment is carried back rather than raised: an exit crossing the
  # barrier would reach the loop with the cartridge unsaved, and the battery
  # of the universe being listened to is written before any crash report
  # flies.
  defp advance(rom, machine, dpad, btns, palette, lcd, samples) do
    {before_state, before_ram, before_apu} = machine

    ram =
      before_ram
      |> CartLoop.rtc_live()
      |> Joypad.set(dpad, btns)
      |> Codes.applique()

    {pixels, state, ram} = Screen.frame(before_state, rom, ram, true)
    {pcm, ram, apu} = APU.samples(ram, before_apu, samples)

    {{:ok, pixels, Screen.to_rgb(pixels, palette, lcd), pcm}, {state, ram, apu}}
  rescue
    e in [Atomboy.CPU.Unimplemented, Atomboy.CPU.Derailed] ->
      {{:derailed, e, __STACKTRACE__}, machine}
  end
end
