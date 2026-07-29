defmodule Atomboy.Play.InputTest do
  use ExUnit.Case, async: true

  alias Atomboy.Play.Input

  test "les lettres se décodent en frappes au relâchement inconnu" do
    assert Input.decode("x") == {[{:key, :a}], ""}
    assert Input.decode("c") == {[{:key, :b}], ""}
    assert Input.decode("\r") == {[{:key, :start}], ""}
    assert Input.decode(" ") == {[{:key, :select}], ""}
    assert Input.decode("q") == {[{:key, :quit}], ""}
    assert Input.decode(<<0x03>>) == {[{:key, :quit}], ""}
  end

  test "les flèches classiques, CSI comme SS3" do
    assert Input.decode("\e[A") == {[{:key, :up}], ""}
    assert Input.decode("\e[B") == {[{:key, :down}], ""}
    assert Input.decode("\e[C") == {[{:key, :right}], ""}
    assert Input.decode("\e[D") == {[{:key, :left}], ""}
    assert Input.decode("\eOA") == {[{:key, :up}], ""}
  end

  test "plusieurs événements dans une même lecture, dans l'ordre" do
    assert Input.decode("\e[Ax\r") == {[{:key, :up}, {:key, :a}, {:key, :start}], ""}
  end

  test "une séquence coupée attend la suite" do
    assert Input.decode("\e") == {[], "\e"}
    assert Input.decode("x\e[") == {[{:key, :a}], "\e["}
    assert Input.decode("\e[1;1:") == {[], "\e[1;1:"}
    assert Input.decode("\e[" <> "A") == {[{:key, :up}], ""}
  end

  test "le protocole kitty : presse, répétition, relâchement" do
    assert Input.decode("\e[120;1u") == {[{:press, :a}], ""}
    assert Input.decode("\e[120;1:2u") == {[{:repeat, :a}], ""}
    assert Input.decode("\e[120;1:3u") == {[{:release, :a}], ""}
    assert Input.decode("\e[99;1u") == {[{:press, :b}], ""}
    assert Input.decode("\e[13;1u") == {[{:press, :start}], ""}
    assert Input.decode("\e[32;1:3u") == {[{:release, :select}], ""}
  end

  test "le protocole kitty : les flèches paramétrées" do
    assert Input.decode("\e[1;1:1A") == {[{:press, :up}], ""}
    assert Input.decode("\e[1;1:2C") == {[{:repeat, :right}], ""}
    assert Input.decode("\e[1;1:3B") == {[{:release, :down}], ""}
  end

  test "le protocole kitty : quitter par q ou Ctrl-C, le menu par Échap" do
    assert Input.decode("\e[113;1u") == {[{:press, :quit}], ""}
    assert Input.decode("\e[27;1u") == {[{:press, :menu}], ""}
    assert Input.decode("\e[99;5u") == {[{:press, :quit}], ""}
  end

  test "la réponse à la requête kitty se reconnaît" do
    assert Input.decode("\e[?11u") == {[{:kitty, 11}], ""}
    assert Input.decode("\e[?1u") == {[{:kitty, 1}], ""}
  end

  test "les touches d'action se décodent" do
    assert Input.decode("s") == {[{:key, :save_state}], ""}
    assert Input.decode("r") == {[{:key, :load_state}], ""}
    assert Input.decode("\t") == {[{:key, :turbo}], ""}
    assert Input.decode("p") == {[{:key, :pause}], ""}
    assert Input.decode("\e[115;1u") == {[{:press, :save_state}], ""}
    assert Input.decode("\e[9;1u") == {[{:press, :turbo}], ""}
  end

  test "les chiffres choisissent la case d'état" do
    assert Input.decode("3") == {[{:key, {:slot, 3}}], ""}
    assert Input.decode("\e[57;1u") == {[{:press, {:slot, 9}}], ""}
  end

  test "les séquences inconnues s'ignorent" do
    assert Input.decode("\e[5~zk") == {[], ""}
    assert Input.decode("\e[121;1u") == {[], ""}
    assert Input.decode("\eOx") == {[{:key, :a}], ""}
  end

  test "les touches tenues deviennent des lignes, actives à zéro" do
    assert Input.dpad_lines([]) == 0x0F
    assert Input.dpad_lines([:right]) == 0x0E
    assert Input.dpad_lines([:left, :down]) == 0x05
    assert Input.button_lines([:a, :start]) == 0x06
    assert Input.button_lines([:up, :b]) == 0x0D
  end
end
