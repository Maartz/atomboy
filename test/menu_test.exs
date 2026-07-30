defmodule Atomboy.MenuTest do
  use ExUnit.Case, async: true

  alias Atomboy.Menu

  test "navigation : le curseur descend, monte, et boucle" do
    menu = Menu.open(1, :dmg)
    assert menu.curseur == 0

    {menu, []} = Menu.press(menu, :down)
    assert menu.curseur == 1

    {menu, []} = Menu.press(menu, :up)
    {menu, []} = Menu.press(menu, :up)
    assert menu.curseur == 6

    {menu, []} = Menu.press(menu, :down)
    assert menu.curseur == 0
  end

  test "REPRENDRE ferme sans action ; B et Échap aussi" do
    assert {nil, []} = Menu.press(Menu.open(1, :dmg), :a)
    assert {nil, []} = Menu.press(Menu.open(1, :dmg), :b)
    assert {nil, []} = Menu.press(Menu.open(1, :dmg), :menu)
  end

  test "SAUVER et CHARGER ferment avec leur action" do
    menu = Menu.open(1, :dmg)
    {menu, []} = Menu.press(menu, :down)
    assert {nil, [:save_state]} = Menu.press(menu, :a)

    menu = Menu.open(1, :dmg)
    {menu, []} = Menu.press(menu, :down)
    {menu, []} = Menu.press(menu, :down)
    assert {nil, [:load_state]} = Menu.press(menu, :a)
  end

  test "la case d'état se règle aux flèches et boucle 9 → 1" do
    menu = %{Menu.open(9, :dmg) | curseur: 3}

    {menu, [{:slot, 1}]} = Menu.press(menu, :right)
    assert menu.slot == 1

    {menu, [{:slot, 9}]} = Menu.press(menu, :left)
    assert menu.slot == 9
  end

  test "la palette bascule verte/grise" do
    menu = %{Menu.open(1, :dmg) | curseur: 4}

    {menu, [{:palette, :gray}]} = Menu.press(menu, :right)
    {_menu, [{:palette, :dmg}]} = Menu.press(menu, :right)
  end

  test "QUITTER rend l'action quit" do
    menu = %{Menu.open(1, :dmg) | curseur: 6}
    assert {nil, [:quit]} = Menu.press(menu, :a)
  end

  test "en couleur, pas de ligne PALETTE — QUITTER remonte d'un cran" do
    menu = Menu.open(1, :dmg, true)

    {menu, []} = Menu.press(menu, :up)
    assert menu.curseur == 5

    assert {nil, [:quit]} = Menu.press(menu, :a)
  end

  test "la page MIXER : volume par pas de dix, borné, voix commutables" do
    menu = %{Menu.open(1, :dmg) | curseur: 5}
    {menu, []} = Menu.press(menu, :a)
    assert menu.page == :mixer

    # VOLUME : gauche baisse, borné à zéro.
    {menu, [{:mixer, %{volume: 90}}]} = Menu.press(menu, :left)
    menu = Enum.reduce(1..12, menu, fn _, m -> elem(Menu.press(m, :left), 0) end)
    assert menu.mixer.volume == 0
    {menu, [{:mixer, %{volume: 10}}]} = Menu.press(menu, :right)

    # PULSE 1 se coupe et se rouvre.
    {menu, []} = Menu.press(menu, :down)
    {menu, [{:mixer, %{voices: {false, true, true, true}}}]} = Menu.press(menu, :a)
    {menu, [{:mixer, %{voices: {true, true, true, true}}}]} = Menu.press(menu, :a)

    # B remonte à la racine ; RETOUR aussi.
    {menu, []} = Menu.press(menu, :b)
    assert menu.page == :principal
  end

  # La géométrie de la boîte : 7 lignes de 11 px + 2×8 de marge = 93 de
  # haut, centrée — coin haut-gauche en (24, 25). Le point « papier » vit à
  # droite du texte de la première ligne, loin du curseur.
  test "rendu DMG : bordure encrée, papier clair, dehors intact" do
    frame = :binary.copy(<<1>>, 160 * 144)
    composée = Menu.render(Menu.open(1, :dmg), frame)

    assert byte_size(composée) == 160 * 144
    # Dehors : la teinte d'origine.
    assert :binary.at(composée, 0) == 1
    assert :binary.at(composée, 143 * 160 + 159) == 1
    # La bordure est encrée, l'intérieur est du papier.
    assert :binary.at(composée, 25 * 160 + 24) == 3
    assert :binary.at(composée, 34 * 160 + 105) == 0
  end

  test "rendu CGB : mêmes points en RGB555" do
    frame = :binary.copy(<<0x33, 0x33>>, 160 * 144)
    composée = Menu.render(Menu.open(1, :dmg), frame)

    assert byte_size(composée) == 2 * 160 * 144
    assert binary_part(composée, 0, 2) == <<0x33, 0x33>>
    assert binary_part(composée, (25 * 160 + 24) * 2, 2) == <<0x00, 0x00>>
    assert binary_part(composée, (34 * 160 + 105) * 2, 2) == <<0xFF, 0x7F>>
  end

  test "le curseur s'affiche devant la ligne choisie" do
    frame = :binary.copy(<<0>>, 160 * 144)
    haut = Menu.render(Menu.open(1, :dmg), frame)
    bas = Menu.render(%{Menu.open(1, :dmg) | curseur: 5}, frame)

    # Le triangle du curseur encre la colonne du premier caractère de la
    # première ligne quand elle est choisie — et plus quand il descend.
    ligne1 = for x <- 30..35, y <- 39..45, do: :binary.at(haut, y * 160 + x)
    assert 3 in ligne1

    ligne1_bas = for x <- 30..35, y <- 39..45, do: :binary.at(bas, y * 160 + x)
    refute 3 in ligne1_bas
  end
end
