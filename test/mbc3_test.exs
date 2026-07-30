defmodule Atomboy.MBC3Test do
  use ExUnit.Case, async: true

  alias Atomboy.CPU.CartLoop
  alias Atomboy.CPU.State
  alias Atomboy.Screen

  # An SM83 program laid at 0x0100, inside a fake 2 MB MBC3 ROM whose every
  # bank carries its own number as its first byte.
  defp run(code, budget) do
    banked =
      for bank <- 2..127, into: <<>> do
        <<bank>> <> :binary.copy(<<0>>, 0x4000 - 1)
      end

    header = :binary.copy(<<0>>, 0x100) <> code
    bank0 = header <> :binary.copy(<<0>>, 0x4000 - byte_size(header))
    bank0 = put_in_binary(bank0, 0x147, 0x10)
    rom = bank0 <> :binary.copy(<<0x77>>, 0x4000) <> banked

    CartLoop.run(%State{pc: 0x100}, rom, Screen.boot_ram(rom), budget)
  end

  defp put_in_binary(bin, at, byte) do
    <<before::binary-size(at), _, rest::binary>> = bin
    before <> <<byte>> <> rest
  end

  test "the 0x10 header is detected as MBC3" do
    rom = put_in_binary(:binary.copy(<<0>>, 0x8000), 0x147, 0x10)
    assert Screen.boot_ram(rom).mbc == :mbc3
    assert Screen.boot_ram(:binary.copy(<<0>>, 0x8000)).mbc == :mbc1
  end

  test "ROM bank 65 is addressable — seven bits, not five" do
    # LD A,65 ; LD (0x2000),A ; LD A,(0x4000) — reads the bank's first byte.
    code = <<0x3E, 65, 0xEA, 0x00, 0x20, 0xFA, 0x00, 0x40>>
    {state, ram, _} = run(code, 36)

    assert ram[:rom_bank_base] == 65 * 0x4000
    assert state.a == 65
  end

  test "the cartridge RAM banks are distinct" do
    # Unlock; bank 2; write 0x11 at 0xA000; bank 0; write 0x22; bank 2;
    # read back.
    code =
      <<0x3E, 0x0A, 0xEA, 0x00, 0x00>> <>
        <<0x3E, 0x02, 0xEA, 0x00, 0x40, 0x3E, 0x11, 0xEA, 0x00, 0xA0>> <>
        <<0x3E, 0x00, 0xEA, 0x00, 0x40, 0x3E, 0x22, 0xEA, 0x00, 0xA0>> <>
        <<0x3E, 0x02, 0xEA, 0x00, 0x40, 0xFA, 0x00, 0xA0>>

    {state, ram, _} = run(code, 200)

    assert state.a == 0x11
    assert ram[0xA000 + 2 * 0x10000] == 0x11
    assert ram[0xA000] == 0x22
    assert ram[:cram_dirty] == true
  end

  test "the latched clock serves plausible seconds" do
    # Unlock; select the seconds register (0x08); latch 0 then 1; read 0xA000.
    code =
      <<0x3E, 0x0A, 0xEA, 0x00, 0x00, 0x3E, 0x08, 0xEA, 0x00, 0x40>> <>
        <<0x3E, 0x00, 0xEA, 0x00, 0x60, 0x3E, 0x01, 0xEA, 0x00, 0x60, 0xFA, 0x00, 0xA0>>

    {state, ram, _} = run(code, 200)

    assert state.a in 0..59
    assert is_map(ram[:rtc_latch])
    # Writing an RTC register marks nothing as needing a save.
    refute Map.has_key?(ram, :cram_dirty)
  end
end
