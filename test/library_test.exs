defmodule Atomboy.LibraryTest do
  @moduledoc """
  The library, held to the spec's promises: identity from the cartridge
  header, adoption that copies and never moves, a single truth afterwards,
  states that carry their name, their time and their portrait.
  """

  use ExUnit.Case, async: true

  alias Atomboy.Library
  alias Atomboy.Save

  # A minimal cartridge: zeros, a title at 0x134, a checksum at 0x14E.
  defp rom(title, checksum \\ 0x91E2) do
    padded = title <> :binary.copy(<<0>>, 16 - byte_size(title))

    :binary.copy(<<0>>, 0x134) <>
      padded <>
      :binary.copy(<<0>>, 0x14E - 0x144) <>
      <<checksum::16>> <> :binary.copy(<<0>>, 0x8000 - 0x150)
  end

  defp payload, do: {Atomboy.Screen.boot_state(), %{0xFF40 => 0x91}, %Atomboy.APU{}}

  # A library opened on a fresh root, the ROM written where sidecars go.
  defp open(dir, opts \\ []) do
    rom = rom("CRYSTAL")
    rom_path = Path.join(dir, "crystal.gbc")
    File.write!(rom_path, rom)
    Library.open(rom, rom_path, Keyword.put(opts, :library, Path.join(dir, "library")))
  end

  describe "identity" do
    test "comes from the header, not the file" do
      assert Library.game_id(rom("POKEMON CRYSTAL")) == "POKEMON_CRYSTAL-91E2"
    end

    test "two revisions differ by checksum" do
      assert Library.game_id(rom("ZELDA", 0x0001)) != Library.game_id(rom("ZELDA", 0x0002))
    end

    test "a blank homebrew title becomes UNTITLED" do
      assert Library.game_id(rom("")) == "UNTITLED-91E2"
    end

    test "hostile titles fold to filesystem-safe names" do
      assert Library.game_id(rom("A/B..C")) == "A_B_C-91E2"
    end
  end

  describe "layout" do
    @tag :tmp_dir
    test "batteries are profiles, states live under them", %{tmp_dir: dir} do
      lib = open(dir)
      assert Path.basename(Library.sav_path(lib)) == "game.sav"

      nolan = Library.set_profile(lib, "nolan")
      assert Path.basename(Library.sav_path(nolan)) == "nolan.sav"

      assert Library.state_path(lib, "slot-3") =~ "/states/game/slot-3.state"
      assert Library.state_path(nolan, "before-boss") =~ "/states/nolan/before-boss.state"
    end

    @tag :tmp_dir
    test "names are sanitized on the way in", %{tmp_dir: dir} do
      lib = open(dir)
      refute Library.state_path(lib, "../../etc/passwd") =~ ".."
      assert Path.basename(Library.state_path(lib, "")) == "state.state"
    end
  end

  describe "named states" do
    @tag :tmp_dir
    test "save, list, load, delete — the full round trip", %{tmp_dir: dir} do
      lib = open(dir)
      rgb = :binary.copy(<<0x9B, 0xBC, 0x0F>>, 160 * 144)

      assert :ok = Library.save_state(lib, "before-boss", payload(), rgb)

      assert [%{name: "before-boss", at: at, png: png}] = Library.list(lib)
      assert {:ok, _, _} = DateTime.from_iso8601(at)
      assert File.exists?(png)

      assert {:ok, {%Atomboy.CPU.State{}, _ram, _apu}} = Library.load_state(lib, "before-boss")

      assert :ok = Library.delete_state(lib, "before-boss")
      assert Library.list(lib) == []
      refute File.exists?(png)
    end

    @tag :tmp_dir
    test "a state without metadata still lists, from the file itself", %{tmp_dir: dir} do
      lib = open(dir)
      Library.save_state(lib, "orphan", payload())
      File.rm!(Path.rootname(Library.state_path(lib, "orphan")) <> ".meta.json")

      assert [%{name: "orphan", at: at, png: nil}] = Library.list(lib)
      assert {:ok, _, _} = DateTime.from_iso8601(at)
    end

    @tag :tmp_dir
    test "profiles never see each other's states", %{tmp_dir: dir} do
      lib = open(dir)
      Library.save_state(lib, "mine", payload())

      nolan = Library.set_profile(lib, "nolan")
      assert Library.list(nolan) == []
    end
  end

  describe "adoption" do
    @tag :tmp_dir
    test "copies every sidecar shape in, originals untouched", %{tmp_dir: dir} do
      rom = rom("CRYSTAL")
      rom_path = Path.join(dir, "crystal.gbc")
      File.write!(rom_path, rom)

      # The four shapes the convention left behind.
      File.write!(Path.join(dir, "crystal.sav"), "battery")
      Save.write_state(Path.join(dir, "crystal.state"), payload())
      Save.write_state(Path.join(dir, "crystal.case4.state"), payload())
      File.write!(Path.join(dir, "crystal.nolan.sav"), "nolan-battery")

      lib = Library.open(rom, rom_path, library: Path.join(dir, "library"))

      assert File.read!(Library.sav_path(lib)) == "battery"
      assert {:ok, _} = Library.load_state(lib, "slot-1")
      assert {:ok, _} = Library.load_state(lib, "slot-4")
      assert File.read!(Library.sav_path(Library.set_profile(lib, "nolan"))) == "nolan-battery"

      # Adopted states list with metadata reconstructed from the files.
      names = lib |> Library.list() |> Enum.map(& &1.name) |> Enum.sort()
      assert names == ["slot-1", "slot-4"]

      # Copies, never moves.
      assert File.exists?(Path.join(dir, "crystal.sav"))
      assert File.exists?(Path.join(dir, "crystal.case4.state"))
    end

    @tag :tmp_dir
    test "runs once: the library is the single truth afterwards", %{tmp_dir: dir} do
      rom = rom("CRYSTAL")
      rom_path = Path.join(dir, "crystal.gbc")
      File.write!(rom_path, rom)
      File.write!(Path.join(dir, "crystal.sav"), "old")

      lib = Library.open(rom, rom_path, library: Path.join(dir, "library"))
      File.write!(Library.sav_path(lib), "library-truth")

      # The sidecar changes after adoption — and is ignored.
      File.write!(Path.join(dir, "crystal.sav"), "newer-sidecar")
      lib = Library.open(rom, rom_path, library: Path.join(dir, "library"))
      assert File.read!(Library.sav_path(lib)) == "library-truth"
    end
  end

  describe "export" do
    @tag :tmp_dir
    test "copies the battery back beside the ROM", %{tmp_dir: dir} do
      lib = open(dir)
      File.write!(Library.sav_path(lib), "travelling")

      assert :ok = Library.export(lib)
      assert File.read!(Path.join(dir, "crystal.sav")) == "travelling"
    end
  end

  describe "sidecar fallback" do
    @tag :tmp_dir
    test "an unwritable root degrades to the historical paths", %{tmp_dir: dir} do
      rom = rom("CRYSTAL")
      rom_path = Path.join(dir, "crystal.gbc")
      File.write!(rom_path, rom)

      blocked = Path.join(dir, "blocked")
      File.write!(blocked, "a file where a directory must go")

      lib =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          send(self(), Library.open(rom, rom_path, library: Path.join(blocked, "library")))
        end)
        |> then(fn _ ->
          receive do
            lib -> lib
          end
        end)

      assert lib.mode == :sidecar
      assert Library.sav_path(lib) == Path.join(dir, "crystal.sav")
      assert Library.state_path(lib, "slot-1") == Path.join(dir, "crystal.state")
      assert Library.state_path(lib, "slot-4") == Path.join(dir, "crystal.case4.state")
      assert Library.list(lib) == []
    end
  end

  describe "png" do
    test "writes a well-formed image any reader eats" do
      rgb = :binary.copy(<<10, 20, 30>>, 160 * 144)
      png = Library.png(rgb, 160, 144)

      # Signature, then IHDR with the dimensions.
      assert <<0x89, "PNG\r\n", 0x1A, "\n", _len::32, "IHDR", 160::32, 144::32, 8, 2, _::binary>> =
               png

      assert String.contains?(png, "IEND")

      # The decoder the project already owns reads it back.
      {width, height, _pixels} = decode(png)
      assert {width, height} == {160, 144}
    end

    defp decode(png) do
      %{width: w, height: h, pixels: p} = Potion.PNG.decode!(png)
      {w, h, p}
    end
  end
end
