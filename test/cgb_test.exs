defmodule Atomboy.CGBTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Atomboy.CPU.CartLoop
  alias Atomboy.CPU.State
  alias Atomboy.Screen

  defp header(rom, at, byte) do
    <<before::binary-size(at), _, rest::binary>> = rom
    before <> <<byte>> <> rest
  end

  defp run(code, budget, opts \\ []) do
    mbc = Keyword.get(opts, :mbc, 0x19)
    banked = for bank <- 2..127, into: <<>>, do: <<bank>> <> :binary.copy(<<0>>, 0x3FFF)
    bank0 = :binary.copy(<<0>>, 0x100) <> code
    bank0 = bank0 <> :binary.copy(<<0>>, 0x4000 - byte_size(bank0))
    bank0 = header(bank0, 0x147, mbc) |> header(0x143, 0x80)
    rom = bank0 <> :binary.copy(<<0x77>>, 0x4000) <> banked

    CartLoop.run(%State{pc: 0x100}, rom, Screen.boot_ram(rom), budget)
  end

  test "l'en-tête choisit le mode couleur et le MBC5" do
    rom = :binary.copy(<<0>>, 0x8000) |> header(0x143, 0x80) |> header(0x147, 0x19)
    assert Screen.boot_ram(rom).mbc == :mbc5
    assert Screen.boot_ram(rom)[:cgb] == true
    assert Screen.boot_state(rom).a == 0x11

    dmg = :binary.copy(<<0>>, 0x8000)
    refute Map.has_key?(Screen.boot_ram(dmg), :cgb)
    assert Screen.boot_state(dmg).a == 0x01
  end

  test "MBC5 : huit bits de banque, et la banque zéro est permise" do
    # LD A,66 ; LD (0x2000),A ; LD A,(0x4000) — la banque 66 se lit.
    code = <<0x3E, 66, 0xEA, 0x00, 0x20, 0xFA, 0x00, 0x40>>
    {state, _ram, _} = run(code, 36)
    assert state.a == 66

    # LD A,0 ; LD (0x2000),A ; LD A,(0x4100) — banque 0 dans la fenêtre
    # haute : relit le premier octet du code (0x3E).
    code = <<0x3E, 0x00, 0xEA, 0x00, 0x20, 0xFA, 0x00, 0x41>>
    {state, ram, _} = run(code, 36)
    assert ram[:rom_bank_base] == 0
    assert state.a == 0x3E
  end

  test "MBC5 : les banques de RAM cartouche vont jusqu'à quinze" do
    # Déverrouille ; banque 5 ; écrit 0x42 ; relit.
    code =
      <<0x3E, 0x0A, 0xEA, 0x00, 0x00, 0x3E, 0x05, 0xEA, 0x00, 0x40>> <>
        <<0x3E, 0x42, 0xEA, 0x00, 0xA0, 0xFA, 0x00, 0xA0>>

    {state, ram, _} = run(code, 100)
    assert state.a == 0x42
    assert ram[0xA000 + 5 * 0x10000] == 0x42
  end

  test "SVBK : la WRAM haute se banque, l'écho la traverse" do
    # Banque 2 ; écrit 0x11 à 0xD000 ; banque 1 ; écrit 0x22 ;
    # banque 2 ; relit par l'écho 0xF000.
    code =
      <<0x3E, 0x02, 0xE0, 0x70, 0x3E, 0x11, 0xEA, 0x00, 0xD0>> <>
        <<0x3E, 0x01, 0xE0, 0x70, 0x3E, 0x22, 0xEA, 0x00, 0xD0>> <>
        <<0x3E, 0x02, 0xE0, 0x70, 0xFA, 0x00, 0xF0>>

    {state, ram, _} = run(code, 120)
    assert state.a == 0x11
    assert ram[0xD000 + 0x10000] == 0x11
    assert ram[0xD000] == 0x22
  end

  test "VBK : la VRAM se banque" do
    # Banque 1 ; écrit 0x33 à 0x8800 ; banque 0 ; écrit 0x44 ; banque 1 ; relit.
    code =
      <<0x3E, 0x01, 0xE0, 0x4F, 0x3E, 0x33, 0xEA, 0x00, 0x88>> <>
        <<0x3E, 0x00, 0xE0, 0x4F, 0x3E, 0x44, 0xEA, 0x00, 0x88>> <>
        <<0x3E, 0x01, 0xE0, 0x4F, 0xFA, 0x00, 0x88>>

    {state, ram, _} = run(code, 120)
    assert state.a == 0x33
    assert ram[0x8800 + 0x10000] == 0x33
    assert ram[0x8800] == 0x44
  end

  test "KEY1 + STOP : la double vitesse bascule, et le budget suit" do
    # LD A,1 ; LDH (4D),A ; STOP ; puis des NOP à l'infini.
    code = <<0x3E, 0x01, 0xE0, 0x4D, 0x10>> <> :binary.copy(<<0x00>>, 0x1000)
    {_state, ram, _} = run(code, 40)

    assert ram[:speed] == 2
    assert ram[0xFF4D] == 0x80

    # Une scanline entière : en double vitesse, ~912 cycles consommés.
    rom = :binary.copy(<<0>>, 0x100) <> code
    rom = rom <> :binary.copy(<<0>>, 0x8000 - byte_size(rom))
    {_state, _ram, cycles} = CartLoop.run(%State{pc: 0x105}, rom, ram, 912)
    assert cycles >= 912
  end

  test "hors CGB, KEY1 reste inerte" do
    code = <<0x3E, 0x01, 0xE0, 0x4D, 0x10, 0x00>>
    rom = :binary.copy(<<0>>, 0x100) <> code
    rom = rom <> :binary.copy(<<0>>, 0x8000 - byte_size(rom))
    {_state, ram, _} = CartLoop.run(%State{pc: 0x100}, rom, Screen.boot_ram(rom), 40)

    refute Map.has_key?(ram, :speed)
  end

  test "GDMA : seize octets copiés de la WRAM vers la VRAM" do
    # Source 0xC100 remplie ; src/dst posés ; HDMA5 = 0 (un bloc).
    data = for i <- 0..15, into: %{}, do: {0xC100 + i, i + 0x30}

    code =
      <<0x3E, 0xC1, 0xE0, 0x51, 0x3E, 0x00, 0xE0, 0x52>> <>
        <<0x3E, 0x00, 0xE0, 0x53, 0x3E, 0x40, 0xE0, 0x54, 0x3E, 0x00, 0xE0, 0x55>>

    rom = :binary.copy(<<0>>, 0x100) <> code
    rom = rom <> :binary.copy(<<0>>, 0x8000 - byte_size(rom))
    rom = header(rom, 0x143, 0x80)
    ram = Map.merge(Screen.boot_ram(rom), data)

    {state, ram} = Screen.step_line(%State{pc: 0x100}, rom, ram, 0)
    _ = state

    assert ram[0x8040] == 0x30
    assert ram[0x804F] == 0x3F
    assert ram[0xFF55] == 0xFF
  end

  test "GDMA : la source peut être une banque ROM" do
    # Banque 66 (MBC5) ; source 0x4000 ; destination 0x8000 ; un bloc.
    code =
      <<0x3E, 66, 0xEA, 0x00, 0x20>> <>
        <<0x3E, 0x40, 0xE0, 0x51, 0x3E, 0x00, 0xE0, 0x52>> <>
        <<0x3E, 0x00, 0xE0, 0x53, 0x3E, 0x00, 0xE0, 0x54, 0x3E, 0x00, 0xE0, 0x55>>

    banked = for bank <- 2..127, into: <<>>, do: <<bank>> <> :binary.copy(<<0>>, 0x3FFF)
    bank0 = :binary.copy(<<0>>, 0x100) <> code
    bank0 = bank0 <> :binary.copy(<<0>>, 0x4000 - byte_size(bank0))
    bank0 = bank0 |> header(0x147, 0x19) |> header(0x143, 0x80)
    rom = bank0 <> :binary.copy(<<0x77>>, 0x4000) <> banked

    {_state, ram} = Screen.step_line(%State{pc: 0x100}, rom, Screen.boot_ram(rom), 0)

    # Le premier octet de la banque 66 est son numéro.
    assert ram[0x8000] == 66
  end

  test "HDMA : un bloc par scanline visible, VBK respecté" do
    data = for i <- 0..31, into: %{}, do: {0xC000 + i, i + 1}

    # VBK = 1 ; src 0xC000 ; dst 0x8000 ; HDMA5 = 0x81 (deux blocs, HBlank).
    code =
      <<0x3E, 0x01, 0xE0, 0x4F>> <>
        <<0x3E, 0xC0, 0xE0, 0x51, 0x3E, 0x00, 0xE0, 0x52>> <>
        <<0x3E, 0x00, 0xE0, 0x53, 0x3E, 0x00, 0xE0, 0x54, 0x3E, 0x81, 0xE0, 0x55>>

    rom = :binary.copy(<<0>>, 0x100) <> code
    rom = rom <> :binary.copy(<<0>>, 0x8000 - byte_size(rom))
    rom = header(rom, 0x143, 0x80)
    ram = Map.merge(Screen.boot_ram(rom), Map.put(data, 0xFF40, 0x91))

    {state, ram} = Screen.step_line(%State{pc: 0x100}, rom, ram, 0)
    assert ram[0x8000 + 0x10000] == 1
    assert ram[0x800F + 0x10000] == 16
    assert {_, _, 1} = ram[:hdma]

    {_state, ram} = Screen.step_line(state, rom, ram, 1)
    assert ram[0x801F + 0x10000] == 32
    refute Map.has_key?(ram, :hdma)
    assert ram[0xFF55] == 0xFF
  end

  test "les palettes couleur s'écrivent en auto-incrément et se relisent" do
    # BCPS = 0x80 (index 0, auto-inc) ; trois octets par BCPD ;
    # BCPS = 0x01 ; relit BCPD.
    code =
      <<0x3E, 0x80, 0xE0, 0x68, 0x3E, 0xAA, 0xE0, 0x69, 0x3E, 0xBB, 0xE0, 0x69>> <>
        <<0x3E, 0xCC, 0xE0, 0x69, 0x3E, 0x01, 0xE0, 0x68, 0xF0, 0x69>>

    {state, ram, _} = run(code, 130)
    assert ram[0x20000] == 0xAA
    assert ram[0x20001] == 0xBB
    assert ram[0x20002] == 0xCC
    assert (ram[0xFF68] &&& 0x3F) == 0x01
    assert state.a == 0xBB
  end
end
