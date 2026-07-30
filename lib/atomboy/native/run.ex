defmodule Atomboy.Native.Run do
  @moduledoc """
  Running SM83 natively, seen from Elixir.

  The same signature as `Atomboy.CPU.Loop.run/4`, memory aside -- the native
  side knows only a flat 64 KB address space, without the ROM + writes overlay
  the Elixir loop carries to stay immutable.

  This is deliberately the only point of contact: everything above it
  (equivalence tests, vector replay, measurements) goes through here and never
  learns there is an image, a qemu and a serial port in the middle.
  """

  import Bitwise

  alias Atomboy.CPU.State
  alias Atomboy.Native.Interp
  alias Atomboy.Native.Qemu

  @memory 0x10000

  @typedoc "What the guest reports."
  @type result :: %{
          state: State.t(),
          memory: binary(),
          cycles: non_neg_integer(),
          status: :ok | :unknown_opcode,
          opcode: 0..0xFF,
          instret: non_neg_integer(),
          duration_us: non_neg_integer(),
          size: non_neg_integer()
        }

  @doc """
  Runs `budget` T-cycles from `state`, over a flat 64 KB memory.

  Returns `{:ok, result}`, or `{:error, reason}` if qemu never handed control
  back or the serial stream is unreadable -- two failures worth telling apart
  from a disagreement with the oracle.
  """
  @spec run(binary(), State.t(), pos_integer(), keyword()) :: {:ok, result()} | {:error, term()}
  def run(memory, %State{} = state, budget, opts \\ []) when byte_size(memory) == @memory do
    image = Interp.image(memory, state, budget)

    case Qemu.run(image.code, opts) do
      %{status: :timeout, duration_us: us} ->
        {:error, {:timeout, us}}

      %{status: :ok, serial: serial, duration_us: us} ->
        decode(serial, us, image.size)
    end
  end

  @doc """
  The same call, but raising on a harness failure.

  In a test, a qemu that loops is not a result to compare: it is a failure, and
  it should say so immediately.
  """
  @spec run!(binary(), State.t(), pos_integer(), keyword()) :: result()
  def run!(memory, state, budget, opts \\ []) do
    case run(memory, state, budget, opts) do
      {:ok, result} -> result
      {:error, reason} -> raise "the guest returned nothing usable: #{inspect(reason)}"
    end
  end

  defp decode(serial, duration_us, size) do
    magic = Interp.magic()

    case serial do
      <<^magic, a, f, b, c, d, e, h, l, sp::16-little, pc::16-little, control, cycles::32-little,
        status, opcode, instret::32-little, memory::binary-size(@memory)>> ->
        {:ok,
         %{
           state: %State{
             a: a,
             f: f,
             b: b,
             c: c,
             d: d,
             e: e,
             h: h,
             l: l,
             sp: sp,
             pc: pc,
             ime: control &&& 1,
             halted: (control &&& 2) != 0,
             ime_pending: control >>> 2 &&& 1
           },
           memory: memory,
           cycles: cycles,
           status: status_name(status),
           opcode: opcode,
           instret: instret,
           duration_us: duration_us,
           size: size
         }}

      other ->
        {:error,
         {:unreadable_stream, byte_size(other), binary_part(other, 0, min(32, byte_size(other)))}}
    end
  end

  defp status_name(code) do
    Enum.find_value(Interp.statuses(), :unknown, fn {name, value} -> value == code && name end)
  end
end
