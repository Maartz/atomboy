defmodule Atomboy.CPU.State do
  @moduledoc """
  The SM83 CPU's state.

  The eight 8-bit registers, the two 16-bit registers, and the interrupt state —
  in a single named term.

  ## Registers

  `a` and `f` (accumulator and flags), `b`, `c`, `d`, `e`, `h`, `l`, plus `sp`
  (stack pointer) and `pc` (program counter). The SM83 pairs them into 16-bit
  registers — `AF`, `BC`, `DE`, `HL` — but 8-bit access is by far the most
  frequent, so they are stored separately and recombined when needed.

  ## Interrupts

  `ime` is the master enable flag; `ie` is really the memory register 0xFFFF,
  duplicated here because the SingleStepTests vectors supply it separately.
  `halted` holds the effect of `HALT`.

  ## The F register

  The flags are kept **packed** in the `f` byte — Z in bit 7, N in 6, H in 5, C
  in 4, the four low bits always zero. That is the hardware's representation, the
  test vectors' representation, and the one `PUSH AF` / `POP AF` demand.

  Keeping them unpacked as four booleans would be faster on arithmetic code, but
  would force a repack on every access to `AF` and a permanent gap between the
  internal state and what the vectors assert. Worth revisiting if the profile
  calls for it; not before.
  """

  @type t :: %__MODULE__{
          a: 0..0xFF,
          f: 0..0xFF,
          b: 0..0xFF,
          c: 0..0xFF,
          d: 0..0xFF,
          e: 0..0xFF,
          h: 0..0xFF,
          l: 0..0xFF,
          sp: 0..0xFFFF,
          pc: 0..0xFFFF,
          ime: 0..1,
          ime_pending: 0..1,
          ie: 0..0xFF,
          halted: boolean()
        }

  defstruct a: 0x00,
            f: 0x00,
            b: 0x00,
            c: 0x00,
            d: 0x00,
            e: 0x00,
            h: 0x00,
            l: 0x00,
            sp: 0x0000,
            pc: 0x0000,
            ime: 0,
            ime_pending: 0,
            ie: 0x00,
            halted: false

  import Bitwise

  @flags [z: 0x80, n: 0x40, h: 0x20, c: 0x10]

  @doc """
  The flags that are set, as a list of atoms.

      iex> Atomboy.CPU.State.flags(%Atomboy.CPU.State{f: 0xB0})
      [:z, :h, :c]

  For inspection and error messages: `f: 176` teaches you nothing.
  """
  @spec flags(t()) :: [:z | :n | :h | :c]
  def flags(%__MODULE__{f: f}) do
    for {flag, bit} <- @flags, (f &&& bit) != 0, do: flag
  end

  @doc """
  The flags spelled out, one character per bit in Z N H C order.

      iex> Atomboy.CPU.State.flag_string(%Atomboy.CPU.State{f: 0xB0})
      "Z-HC"
  """
  @spec flag_string(t()) :: String.t()
  def flag_string(%__MODULE__{f: f}) do
    Enum.map_join(@flags, fn {flag, bit} ->
      if (f &&& bit) != 0 do
        flag |> Atom.to_string() |> String.upcase()
      else
        "-"
      end
    end)
  end

  @doc """
  The 16-bit pair `HL`, the most used indirect address in the instruction set.
  """
  @spec hl(t()) :: 0..0xFFFF
  def hl(%__MODULE__{h: h, l: l}), do: bsl(h, 8) ||| l
end
