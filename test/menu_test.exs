defmodule Atomboy.MenuTest do
  use ExUnit.Case, async: true

  alias Atomboy.Menu

  test "navigation: the cursor goes down, up, and wraps around" do
    menu = Menu.open(1, :dmg)
    assert menu.cursor == 0

    {menu, []} = Menu.press(menu, :down)
    assert menu.cursor == 1

    {menu, []} = Menu.press(menu, :up)
    {menu, []} = Menu.press(menu, :up)
    assert menu.cursor == 6

    {menu, []} = Menu.press(menu, :down)
    assert menu.cursor == 0
  end

  test "RESUME closes with no action; so do B and Escape" do
    assert {nil, []} = Menu.press(Menu.open(1, :dmg), :a)
    assert {nil, []} = Menu.press(Menu.open(1, :dmg), :b)
    assert {nil, []} = Menu.press(Menu.open(1, :dmg), :menu)
  end

  test "SAVE STATE and LOAD STATE close with their action" do
    menu = Menu.open(1, :dmg)
    {menu, []} = Menu.press(menu, :down)
    assert {nil, [:save_state]} = Menu.press(menu, :a)

    menu = Menu.open(1, :dmg)
    {menu, []} = Menu.press(menu, :down)
    {menu, []} = Menu.press(menu, :down)
    assert {nil, [:load_state]} = Menu.press(menu, :a)
  end

  test "the state slot is set with the arrows and wraps 9 → 1" do
    menu = %{Menu.open(9, :dmg) | cursor: 3}

    {menu, [{:slot, 1}]} = Menu.press(menu, :right)
    assert menu.slot == 1

    {menu, [{:slot, 9}]} = Menu.press(menu, :left)
    assert menu.slot == 9
  end

  test "the palette toggles green/gray" do
    menu = %{Menu.open(1, :dmg) | cursor: 4}

    {menu, [{:palette, :gray}]} = Menu.press(menu, :right)
    {_menu, [{:palette, :dmg}]} = Menu.press(menu, :right)
  end

  test "QUIT returns the quit action" do
    menu = %{Menu.open(1, :dmg) | cursor: 6}
    assert {nil, [:quit]} = Menu.press(menu, :a)
  end

  test "in color, no PALETTE row — QUIT moves up one notch" do
    menu = Menu.open(1, :dmg, true)

    {menu, []} = Menu.press(menu, :up)
    assert menu.cursor == 5

    assert {nil, [:quit]} = Menu.press(menu, :a)
  end

  test "the MIXER page: volume in steps of ten, clamped, voices switchable" do
    menu = %{Menu.open(1, :dmg) | cursor: 5}
    {menu, []} = Menu.press(menu, :a)
    assert menu.page == :mixer

    # VOLUME: left lowers it, clamped at zero.
    {menu, [{:mixer, %{volume: 90}}]} = Menu.press(menu, :left)
    menu = Enum.reduce(1..12, menu, fn _, m -> elem(Menu.press(m, :left), 0) end)
    assert menu.mixer.volume == 0
    {menu, [{:mixer, %{volume: 10}}]} = Menu.press(menu, :right)

    # PULSE 1 switches off and back on.
    {menu, []} = Menu.press(menu, :down)
    {menu, [{:mixer, %{voices: {false, true, true, true}}}]} = Menu.press(menu, :a)
    {menu, [{:mixer, %{voices: {true, true, true, true}}}]} = Menu.press(menu, :a)

    # B goes back to the root; so does BACK.
    {menu, []} = Menu.press(menu, :b)
    assert menu.page == :main
  end

  # The geometry of the box: 7 rows of 11 px + 2×8 of margin = 93 high,
  # centred — top-left corner at (24, 25). The "paper" point sits to the
  # right of the first row's text, far from the cursor.
  test "DMG rendering: inked border, light paper, outside untouched" do
    frame = :binary.copy(<<1>>, 160 * 144)
    composed = Menu.render(Menu.open(1, :dmg), frame)

    assert byte_size(composed) == 160 * 144
    # Outside: the original shade.
    assert :binary.at(composed, 0) == 1
    assert :binary.at(composed, 143 * 160 + 159) == 1
    # The border is inked, the inside is paper.
    assert :binary.at(composed, 25 * 160 + 24) == 3
    assert :binary.at(composed, 34 * 160 + 105) == 0
  end

  test "CGB rendering: same points in RGB555" do
    frame = :binary.copy(<<0x33, 0x33>>, 160 * 144)
    composed = Menu.render(Menu.open(1, :dmg), frame)

    assert byte_size(composed) == 2 * 160 * 144
    assert binary_part(composed, 0, 2) == <<0x33, 0x33>>
    assert binary_part(composed, (25 * 160 + 24) * 2, 2) == <<0x00, 0x00>>
    assert binary_part(composed, (34 * 160 + 105) * 2, 2) == <<0xFF, 0x7F>>
  end

  test "the cursor shows in front of the selected row" do
    frame = :binary.copy(<<0>>, 160 * 144)
    top = Menu.render(Menu.open(1, :dmg), frame)
    bottom = Menu.render(%{Menu.open(1, :dmg) | cursor: 5}, frame)

    # The cursor triangle inks the column of the first character of the
    # first row when that row is selected — and no longer once it moves on.
    row1 = for x <- 30..35, y <- 39..45, do: :binary.at(top, y * 160 + x)
    assert 3 in row1

    row1_moved = for x <- 30..35, y <- 39..45, do: :binary.at(bottom, y * 160 + x)
    refute 3 in row1_moved
  end
end
