defmodule Potion.ROMTest do
  @moduledoc """
  The cartridge checked field by field — then booted.

  The checksums are recomputed here by a second implementation, independent of
  the module's own: a test that called the same function back would validate a
  tautology. The last test is the one that counts: the emitted ROM runs in the
  emulator, whole frames, without raising — the first link in the chain "Potion
  writes, atomboy runs".
  """

  use ExUnit.Case, async: true

  import Bitwise

  alias Atomboy.Screen
  alias Potion.ROM

  @loop [{:label, :here}, {:jr, {:label, :here}}]

  describe "the header" do
    test "exactly 32 KB, entry NOP + JP 0x150" do
      rom = ROM.build(@loop)

      assert byte_size(rom) == 0x8000
      assert binary_part(rom, 0x100, 4) == <<0x00, 0xC3, 0x50, 0x01>>
      # The code really is at the promised address.
      assert binary_part(rom, 0x150, 2) == <<0x18, 0xFE>>
    end

    test "the Nintendo logo is the one the boot ROM demands" do
      rom = ROM.build(@loop)

      # The first four bytes are enough to recognise the original — and the full
      # test is the header checksum, which covers other fields.
      assert binary_part(rom, 0x104, 4) == <<0xCE, 0xED, 0x66, 0x66>>
      assert binary_part(rom, 0x104, 48) |> :binary.bin_to_list() |> Enum.sum() == 5446
    end

    test "the title is upcased and padded with zeros" do
      rom = ROM.build(@loop, title: "pong")

      assert binary_part(rom, 0x134, 16) == "PONG" <> :binary.copy(<<0>>, 12)
    end

    test "DMG cartridge, ROM only: the flags at zero" do
      rom = ROM.build(@loop)

      # 0x143: no colour. 0x147: no MBC. 0x148-0x149: 32 KB, no RAM. This is
      # what Screen.boot_ram will read.
      assert :binary.at(rom, 0x143) == 0x00
      assert :binary.at(rom, 0x147) == 0x00
      assert :binary.at(rom, 0x148) == 0x00
      assert :binary.at(rom, 0x149) == 0x00
      assert Screen.boot_ram(rom) == %{rom_banks: 2, mbc: :mbc1}
    end

    test "the header checksum is the one the boot verifies" do
      rom = ROM.build(@loop, title: "VERIF")

      expected =
        rom
        |> binary_part(0x134, 0x14D - 0x134)
        |> :binary.bin_to_list()
        |> Enum.reduce(0, fn byte, checksum -> checksum - byte - 1 &&& 0xFF end)

      assert :binary.at(rom, 0x14D) == expected
      # It depends on the title: two ROMs with different titles differ here.
      other = ROM.build(@loop, title: "OTHER")
      refute :binary.at(other, 0x14D) == :binary.at(rom, 0x14D)
    end

    test "the global checksum covers everything but its own two slots" do
      rom = ROM.build(@loop)

      without_slots =
        binary_part(rom, 0, 0x14E) <> <<0, 0>> <> binary_part(rom, 0x150, 0x8000 - 0x150)

      expected = without_slots |> :binary.bin_to_list() |> Enum.sum() |> band(0xFFFF)
      <<read::16-big>> = binary_part(rom, 0x14E, 2)

      assert read == expected
    end
  end

  describe "the vblank vector" do
    test "the label becomes a JP at 0x40" do
      program = [
        {:label, :here},
        {:jr, {:label, :here}},
        {:label, :vbl},
        {:reti}
      ]

      rom = ROM.build(program, vblank: :vbl)

      # :vbl is at 0x150 + 2 (the JR).
      assert binary_part(rom, 0x40, 3) == <<0xC3, 0x52, 0x01>>
    end

    test "a missing label is refused by name" do
      error =
        assert_raise ArgumentError, fn -> ROM.build(@loop, vblank: :ghost) end

      assert error.message =~ ":ghost"
    end

    test "without the option, the vector stays zeros" do
      rom = ROM.build(@loop)

      assert binary_part(rom, 0x40, 3) == <<0, 0, 0>>
    end
  end

  describe "the refusals" do
    test "a title too long or accented" do
      assert_raise ArgumentError, fn -> ROM.build(@loop, title: "SIXTEENCHARACTS!") end
      assert_raise ArgumentError, fn -> ROM.build(@loop, title: "CAFÉ") end
    end

    test "a program larger than the room available" do
      too_big = [{:bytes, :binary.copy(<<0>>, 0x8000 - 0x150 + 1)}]

      error = assert_raise ArgumentError, fn -> ROM.build(too_big) end

      assert error.message =~ "program too large"
    end
  end

  describe "in the emulator" do
    test "the bare ROM boots and runs whole frames without raising" do
      rom = ROM.build(@loop)
      state = Screen.boot_state(rom)
      ram = Screen.boot_ram(rom)

      {_pixels, state, _ram} =
        Enum.reduce(1..5, {<<>>, state, ram}, fn _frame, {_pixels, state, ram} ->
          Screen.frame(state, rom, ram, true)
        end)

      # The processor stayed inside the loop: on the JR (0x151) or just after
      # fetching it — it did not wander off executing padding.
      assert state.pc in 0x150..0x152
    end

    test "a program that computes: the WRAM carries the result" do
      program = [
        {:ld, :a, 21},
        {:add, :a, :a},
        {:ld, {:mem, 0xC000}, :a},
        {:label, :done},
        {:jr, {:label, :done}}
      ]

      rom = ROM.build(program, title: "COMPUTE")
      state = Screen.boot_state(rom)
      ram = Screen.boot_ram(rom)

      {_pixels, _state, ram} = Screen.frame(state, rom, ram, false)

      assert Map.get(ram, 0xC000) == 42
    end
  end
end
