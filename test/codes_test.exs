defmodule Atomboy.CodesTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Atomboy.Codes
  alias Atomboy.CPU.CartLoop

  test "01VVLLHH : valeur et adresse petit-boutiste" do
    assert {:ok, {0xD116, 0xFF}} = Codes.parse("01FF16D1")
    assert {:ok, {0xC245, 0x63}} = Codes.parse("016345c2")
  end

  test "les codes hors format sont rejetés" do
    # Mauvais type, trop court, pas de l'hexa, adresse en ROM.
    assert :error = Codes.parse("02FF16D1")
    assert :error = Codes.parse("01FF16")
    assert :error = Codes.parse("01GG16D1")
    assert :error = Codes.parse("01FF3412")
  end

  test "l'analyse d'une liste ignore les invalides en le signalant" do
    {écritures, stderr} =
      with_io(:stderr, fn -> Codes.analyse("01FF16D1, zzz, 016345C2") end)

    assert écritures == [{0xD116, 0xFF}, {0xC245, 0x63}]
    assert stderr =~ "zzz"
  end

  test "appliqués chaque frame : le poke traverse la sémantique cartouche" do
    ram =
      %{}
      |> Codes.installe([{0xD116, 0xFF}, {0xC245, 0x63}])
      |> Codes.applique()

    assert CartLoop.peek(<<0::size(0x8000 * 8)>>, ram, 0xD116) == 0xFF
    assert CartLoop.peek(<<0::size(0x8000 * 8)>>, ram, 0xC245) == 0x63
  end

  test "sans codes, la clé disparaît — zéro coût par frame" do
    ram = Codes.installe(%{codes: [{0xD116, 1}]}, [])
    refute Map.has_key?(ram, :codes)
    assert Codes.applique(ram) == ram
  end
end
