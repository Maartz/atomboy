defmodule Atomboy.EchoRamTest do
  use ExUnit.Case, async: true

  alias Atomboy.CPU.CartLoop
  alias Atomboy.CPU.State

  defp run(code, budget) do
    rom = :binary.copy(<<0>>, 0x100) <> code
    rom = rom <> :binary.copy(<<0>>, 0x8000 - byte_size(rom))
    CartLoop.run(%State{pc: 0x100}, rom, %{}, budget)
  end

  test "written in WRAM, read back through the mirror" do
    # LD A,0x42 ; LD (0xC123),A ; LD A,(0xE123)
    code = <<0x3E, 0x42, 0xEA, 0x23, 0xC1, 0xFA, 0x23, 0xE1>>
    {state, _ram, _} = run(code, 36)
    assert state.a == 0x42
  end

  test "written through the mirror, the data lives at its real address" do
    # LD A,0x99 ; LD (0xE000),A ; LD A,(0xC000)
    code = <<0x3E, 0x99, 0xEA, 0x00, 0xE0, 0xFA, 0x00, 0xC0>>
    {state, ram, _} = run(code, 36)

    assert state.a == 0x99
    assert ram[0xC000] == 0x99
    refute Map.has_key?(ram, 0xE000)
  end

  test "the mirror stops at 0xFDFF — the OAM stays itself" do
    # LD A,0x55 ; LD (0xFE00),A ; LD A,(0xDE00)
    code = <<0x3E, 0x55, 0xEA, 0x00, 0xFE, 0xFA, 0x00, 0xDE>>
    {state, ram, _} = run(code, 36)

    assert ram[0xFE00] == 0x55
    assert state.a == 0xFF
  end
end
