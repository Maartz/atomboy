defmodule Atomboy.Play.InputTest do
  use ExUnit.Case, async: true

  alias Atomboy.Play.Input

  test "les lettres se décodent en touches" do
    assert Input.decode("x") == {[:a], ""}
    assert Input.decode("c") == {[:b], ""}
    assert Input.decode("\r") == {[:start], ""}
    assert Input.decode(" ") == {[:select], ""}
    assert Input.decode("q") == {[:quit], ""}
    assert Input.decode(<<0x03>>) == {[:quit], ""}
  end

  test "les flèches se décodent depuis leurs séquences CSI" do
    assert Input.decode("\e[A") == {[:up], ""}
    assert Input.decode("\e[B") == {[:down], ""}
    assert Input.decode("\e[C") == {[:right], ""}
    assert Input.decode("\e[D") == {[:left], ""}
    # Le mode application (SS3) de certains terminaux.
    assert Input.decode("\eOA") == {[:up], ""}
  end

  test "plusieurs touches dans une même lecture, dans l'ordre" do
    assert Input.decode("\e[Ax\r") == {[:up, :a, :start], ""}
  end

  test "une séquence coupée attend la suite" do
    assert Input.decode("\e") == {[], "\e"}
    assert Input.decode("x\e[") == {[:a], "\e["}

    # La suite arrive : le reste préfixé se complète.
    {keys, rest} = Input.decode("\e[" <> "A")
    assert {keys, rest} == {[:up], ""}
  end

  test "un échappement qui n'est pas une flèche s'ignore" do
    assert Input.decode("\eOx") == {[:a], ""}
  end

  test "le reste du clavier est muet" do
    assert Input.decode("zk9") == {[], ""}
  end

  test "les touches tenues deviennent des lignes, actives à zéro" do
    assert Input.dpad_lines([]) == 0x0F
    assert Input.dpad_lines([:right]) == 0x0E
    assert Input.dpad_lines([:left, :down]) == 0x05
    assert Input.button_lines([:a, :start]) == 0x06
    assert Input.button_lines([:up, :b]) == 0x0D
  end
end
