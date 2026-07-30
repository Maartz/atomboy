defmodule Atomboy.CodesTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Atomboy.Codes
  alias Atomboy.CPU.CartLoop

  test "01VVLLHH: value and little-endian address" do
    assert {:ok, {0xD116, 0xFF}} = Codes.parse("01FF16D1")
    assert {:ok, {0xC245, 0x63}} = Codes.parse("016345c2")
  end

  test "codes outside the format are rejected" do
    # Wrong type, too short, not hex, address in ROM.
    assert :error = Codes.parse("02FF16D1")
    assert :error = Codes.parse("01FF16")
    assert :error = Codes.parse("01GG16D1")
    assert :error = Codes.parse("01FF3412")
  end

  test "parsing a list ignores the invalid ones and says so" do
    {pokes, stderr} =
      with_io(:stderr, fn -> Codes.analyse("01FF16D1, zzz, 016345C2") end)

    assert pokes == [{0xD116, 0xFF}, {0xC245, 0x63}]
    assert stderr =~ "GameShark code ignored: zzz"
  end

  test "applied every frame: the poke goes through the cartridge semantics" do
    ram =
      %{}
      |> Codes.installe([{0xD116, 0xFF}, {0xC245, 0x63}])
      |> Codes.applique()

    assert CartLoop.peek(<<0::size(0x8000 * 8)>>, ram, 0xD116) == 0xFF
    assert CartLoop.peek(<<0::size(0x8000 * 8)>>, ram, 0xC245) == 0x63
  end

  test "with no codes, the key disappears — zero cost per frame" do
    ram = Codes.installe(%{codes: [{0xD116, 1}]}, [])
    refute Map.has_key?(ram, :codes)
    assert Codes.applique(ram) == ram
  end
end
