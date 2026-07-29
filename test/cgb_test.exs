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
