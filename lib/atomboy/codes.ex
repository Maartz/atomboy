defmodule Atomboy.Codes do
  @moduledoc """
  The GameShark codes: memory pokes applied on every frame.

  The classic format fits in eight hexadecimal digits — `01VVLLHH`: type `01`
  (eight-bit write), the value `VV`, then the address little-endian (`LLHH` →
  `0xHHLL`). `01FF16D1` writes `0xFF` to `0xD116` on every frame — that is the
  whole secret of infinite lives.

  The active codes live in the memory map (`ram[:codes]`, a list of parsed
  writes): they travel along with saved states, and the three game loops call
  `applique/1` before each frame — the real GameShark wrote at vblank, the
  same rate. The pokes go through `CartLoop.poke/3`: banks and echo served,
  locked SRAM respected.

  Only type `01` is accepted — the banking types (`9x`) will wait for a game
  that demands them. An invalid code is simply ignored and reported on
  stderr: a GameShark with dirty contacts, not a breakdown.
  """

  import Bitwise

  alias Atomboy.CPU.CartLoop

  @type poke :: {addr :: 0x8000..0xFFFF, value :: 0..0xFF}

  @doc """
  Parses an `01VVLLHH` code. `{:ok, {address, value}}`, or `:error`.
  """
  @spec parse(String.t()) :: {:ok, poke()} | :error
  def parse(<<code::binary-size(8)>>) do
    with {:ok, <<0x01, value, low, high>>} <- Base.decode16(String.upcase(code)),
         addr = bsl(high, 8) ||| low,
         true <- addr >= 0x8000 do
      {:ok, {addr, value}}
    else
      _ -> :error
    end
  end

  def parse(_), do: :error

  @doc """
  Parses a comma-separated list — invalid codes are ignored and reported.
  Returns the list of pokes.
  """
  @spec analyse(String.t()) :: [poke()]
  def analyse(string) do
    string
    |> String.split([",", " ", "\n"], trim: true)
    |> Enum.flat_map(fn code ->
      case parse(code) do
        {:ok, poke} ->
          [poke]

        :error ->
          IO.puts(:stderr, "GameShark code ignored: #{code}")
          []
      end
    end)
  end

  @doc """
  Lays the codes into the map — `ram[:codes]`, a full replacement. An empty
  list erases the key: zero cost per frame when there are no codes.
  """
  @spec installe(map(), [poke()]) :: map()
  def installe(ram, []), do: Map.delete(ram, :codes)
  def installe(ram, pokes), do: Map.put(ram, :codes, pokes)

  @doc "Applies the active codes — one poke per code, every frame."
  @spec applique(map()) :: map()
  def applique(ram) do
    case Map.get(ram, :codes) do
      nil ->
        ram

      pokes ->
        Enum.reduce(pokes, ram, fn {addr, value}, ram ->
          CartLoop.poke(ram, addr, value)
        end)
    end
  end
end
