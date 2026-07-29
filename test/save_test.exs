defmodule Atomboy.SaveTest do
  use ExUnit.Case, async: true

  alias Atomboy.CPU.CartLoop
  alias Atomboy.CPU.State
  alias Atomboy.Save

  @moduletag :tmp_dir

  test "le chemin du .sav remplace l'extension de la ROM" do
    assert Save.path("roms/zelda.gb") == "roms/zelda.sav"
  end

  test "le profil s'intercale — deux joueurs, une ROM" do
    assert Save.path("roms/argent.gbc", "j1") == "roms/argent.j1.sav"
    assert Save.state_path("roms/argent.gbc", "j1") == "roms/argent.j1.state"
    assert Save.state_path("roms/argent.gbc", "j1", 3) == "roms/argent.j1.case3.state"
    assert Save.state_path("roms/argent.gbc", nil, 1) == "roms/argent.state"
    assert Save.state_path("roms/argent.gbc", nil, 7) == "roms/argent.case7.state"
  end

  test "aller-retour : ce que le jeu écrit se recharge à l'identique", %{tmp_dir: dir} do
    sav = Path.join(dir, "partie.sav")

    ram = %{:cram_enabled => true, :cram_dirty => true, 0xA000 => 0x42, 0xBFFF => 0x99}
    ram = Save.flush(ram, sav)

    refute Map.has_key?(ram, :cram_dirty)
    assert File.exists?(sav)
    assert byte_size(File.read!(sav)) == 0x2000

    recharge = Save.load(%{}, sav)
    assert recharge[0xA000] == 0x42
    assert recharge[0xBFFF] == 0x99
    # Un octet jamais écrit se recharge à zéro — pas en bus ouvert.
    assert recharge[0xA001] == 0
  end

  test "sans écriture du jeu, flush ne crée rien", %{tmp_dir: dir} do
    sav = Path.join(dir, "rien.sav")
    ram = Save.flush(%{0xA000 => 0x42}, sav)

    refute File.exists?(sav)
    assert ram[0xA000] == 0x42
  end

  test "sans fichier, load rend la map telle quelle" do
    assert Save.load(%{a: 1}, "/nulle/part.sav") == %{a: 1}
  end

  test "un .sav trop long est tronqué aux 8 Ko de la SRAM", %{tmp_dir: dir} do
    sav = Path.join(dir, "long.sav")
    File.write!(sav, :binary.copy(<<0x11>>, 0x3000))

    ram = Save.load(%{}, sav)
    assert ram[0xBFFF] == 0x11
    refute Map.has_key?(ram, 0xC000)
  end

  test "un instantané fige et ranime la machine entière", %{tmp_dir: dir} do
    path = Path.join(dir, "boss.state")
    state = %State{pc: 0x1234, a: 0x42}
    ram = %{0xC000 => 7, :rom_banks => 2}
    apu = %Atomboy.APU{seq_step: 3}

    Save.write_state(path, {state, ram, apu})
    assert {:ok, {^state, ^ram, ^apu}} = Save.read_state(path)
  end

  test "un instantané absent ou corrompu rend :error", %{tmp_dir: dir} do
    assert Save.read_state(Path.join(dir, "absent.state")) == :error

    corrompu = Path.join(dir, "corrompu.state")
    File.write!(corrompu, "pas un terme erlang")
    assert Save.read_state(corrompu) == :error
  end

  test "le jeu qui écrit sa SRAM marque la map à sauver" do
    # LD A,0x0A ; LD (0x0000),A — déverrouille la RAM cartouche.
    # LD A,0x42 ; LD (0xA000),A — écrit un octet de sauvegarde.
    rom =
      <<0x3E, 0x0A, 0xEA, 0x00, 0x00, 0x3E, 0x42, 0xEA, 0x00, 0xA0>> <>
        :binary.copy(<<0>>, 0x8000 - 10)

    {_state, ram, _cycles} = CartLoop.run(%State{pc: 0}, rom, %{}, 40)

    assert ram[:cram_dirty] == true
    assert ram[0xA000] == 0x42
  end

  test "MBC3 : la sauvegarde fait 32 Ko, quatre banques qui se suivent" do
    ram = %{
      :mbc => :mbc3,
      :cram_dirty => true,
      0xA000 => 0x11,
      0xA000 + 0x10000 => 0x22,
      0xA000 + 0x30000 => 0x44
    }

    dir = System.tmp_dir!()
    sav = Path.join(dir, "argent-#{System.unique_integer([:positive])}.sav")
    Save.flush(ram, sav)

    data = File.read!(sav)
    assert byte_size(data) == 0x8000
    assert :binary.at(data, 0) == 0x11
    assert :binary.at(data, 0x2000) == 0x22
    assert :binary.at(data, 0x6000) == 0x44

    recharge = Save.load(%{mbc: :mbc3}, sav)
    assert recharge[0xA000 + 0x10000] == 0x22
    File.rm(sav)
  end

  test "la SRAM verrouillée ignore l'écriture, sans marque" do
    # LD A,0x42 ; LD (0xA000),A — sans déverrouillage préalable.
    rom = <<0x3E, 0x42, 0xEA, 0x00, 0xA0>> <> :binary.copy(<<0>>, 0x8000 - 5)
    {_state, ram, _cycles} = CartLoop.run(%State{pc: 0}, rom, %{}, 24)

    refute Map.has_key?(ram, :cram_dirty)
    refute Map.has_key?(ram, 0xA000)
  end
end
