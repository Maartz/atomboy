defmodule Atomboy.SaveTest do
  use ExUnit.Case, async: true

  alias Atomboy.CPU.CartLoop
  alias Atomboy.CPU.State
  alias Atomboy.Save

  @moduletag :tmp_dir

  test "the .sav path replaces the ROM's extension" do
    assert Save.path("roms/zelda.gb") == "roms/zelda.sav"
  end

  test "the profile slots in — two players, one ROM" do
    assert Save.path("roms/silver.gbc", "p1") == "roms/silver.p1.sav"
    assert Save.state_path("roms/silver.gbc", "p1") == "roms/silver.p1.state"
    assert Save.state_path("roms/silver.gbc", "p1", 3) == "roms/silver.p1.case3.state"
    assert Save.state_path("roms/silver.gbc", nil, 1) == "roms/silver.state"
    assert Save.state_path("roms/silver.gbc", nil, 7) == "roms/silver.case7.state"
  end

  test "round trip: what the game writes reloads identically", %{tmp_dir: dir} do
    sav = Path.join(dir, "game.sav")

    ram = %{:cram_enabled => true, :cram_dirty => true, 0xA000 => 0x42, 0xBFFF => 0x99}
    ram = Save.flush(ram, sav)

    refute Map.has_key?(ram, :cram_dirty)
    assert File.exists?(sav)
    assert byte_size(File.read!(sav)) == 0x2000

    reloaded = Save.load(%{}, sav)
    assert reloaded[0xA000] == 0x42
    assert reloaded[0xBFFF] == 0x99
    # A byte never written reloads as zero — not as open bus.
    assert reloaded[0xA001] == 0
  end

  test "with no write from the game, flush creates nothing", %{tmp_dir: dir} do
    sav = Path.join(dir, "nothing.sav")
    ram = Save.flush(%{0xA000 => 0x42}, sav)

    refute File.exists?(sav)
    assert ram[0xA000] == 0x42
  end

  test "with no file, load returns the map as it is" do
    assert Save.load(%{a: 1}, "/nowhere/at/all.sav") == %{a: 1}
  end

  test "a .sav that is too long is truncated to the SRAM's 8 KB", %{tmp_dir: dir} do
    sav = Path.join(dir, "long.sav")
    File.write!(sav, :binary.copy(<<0x11>>, 0x3000))

    ram = Save.load(%{}, sav)
    assert ram[0xBFFF] == 0x11
    refute Map.has_key?(ram, 0xC000)
  end

  test "a snapshot freezes and revives the whole machine", %{tmp_dir: dir} do
    path = Path.join(dir, "boss.state")
    state = %State{pc: 0x1234, a: 0x42}
    ram = %{0xC000 => 7, :rom_banks => 2}
    apu = %Atomboy.APU{seq_step: 3}

    Save.write_state(path, {state, ram, apu})
    assert {:ok, {^state, ^ram, ^apu}} = Save.read_state(path)
  end

  test "a snapshot from an older release loads onto today's structs", %{tmp_dir: dir} do
    # Yesterday's code had fewer fields: simulate its file by freezing the
    # structs with one field missing and one that no longer exists.
    old_state =
      %State{pc: 0x1234}
      |> Map.from_struct()
      |> Map.delete(:sp)
      |> Map.put(:removed_long_ago, :whatever)
      |> Map.put(:__struct__, State)

    old_apu =
      %Atomboy.APU{}
      |> Map.from_struct()
      |> Map.delete(:seq_step)
      |> Map.put(:__struct__, Atomboy.APU)

    path = Path.join(dir, "vintage.state")
    File.write!(path, :erlang.term_to_binary({:atomboy_state, 1, old_state, %{}, old_apu}))

    # The missing fields get today's defaults, the dead one is dropped —
    # a KeyError here would cost every state the library keeps.
    assert {:ok, {%State{} = state, %{}, %Atomboy.APU{} = apu}} = Save.read_state(path)
    assert state.pc == 0x1234
    assert state.sp == %State{}.sp
    refute Map.has_key?(state, :removed_long_ago)
    assert apu.seq_step == %Atomboy.APU{}.seq_step
  end

  test "a snapshot that is missing or corrupt returns :error", %{tmp_dir: dir} do
    assert Save.read_state(Path.join(dir, "missing.state")) == :error

    corrupt = Path.join(dir, "corrupt.state")
    File.write!(corrupt, "not an erlang term")
    assert Save.read_state(corrupt) == :error
  end

  test "a game writing its SRAM marks the map as needing a save" do
    # LD A,0x0A ; LD (0x0000),A — unlocks the cartridge RAM.
    # LD A,0x42 ; LD (0xA000),A — writes one byte of save data.
    rom =
      <<0x3E, 0x0A, 0xEA, 0x00, 0x00, 0x3E, 0x42, 0xEA, 0x00, 0xA0>> <>
        :binary.copy(<<0>>, 0x8000 - 10)

    {_state, ram, _cycles} = CartLoop.run(%State{pc: 0}, rom, %{}, 40)

    assert ram[:cram_dirty] == true
    assert ram[0xA000] == 0x42
  end

  test "MBC3: the save is 32 KB, four banks one after another" do
    ram = %{
      :mbc => :mbc3,
      :cram_dirty => true,
      0xA000 => 0x11,
      (0xA000 + 0x10000) => 0x22,
      (0xA000 + 0x30000) => 0x44
    }

    dir = System.tmp_dir!()
    sav = Path.join(dir, "silver-#{System.unique_integer([:positive])}.sav")
    Save.flush(ram, sav)

    data = File.read!(sav)
    assert byte_size(data) == 0x8000
    assert :binary.at(data, 0) == 0x11
    assert :binary.at(data, 0x2000) == 0x22
    assert :binary.at(data, 0x6000) == 0x44

    reloaded = Save.load(%{mbc: :mbc3}, sav)
    assert reloaded[0xA000 + 0x10000] == 0x22
    File.rm(sav)
  end

  test "locked SRAM ignores the write, and marks nothing" do
    # LD A,0x42 ; LD (0xA000),A — with no prior unlock.
    rom = <<0x3E, 0x42, 0xEA, 0x00, 0xA0>> <> :binary.copy(<<0>>, 0x8000 - 5)
    {_state, ram, _cycles} = CartLoop.run(%State{pc: 0}, rom, %{}, 24)

    refute Map.has_key?(ram, :cram_dirty)
    refute Map.has_key?(ram, 0xA000)
  end
end
