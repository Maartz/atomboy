defmodule Atomboy.Save do
  @moduledoc """
  The cartridge's battery: the RAM at 0xA000-0xBFFF, persisted as a `.sav`.

  On the real cartridge a coin cell keeps the SRAM alive — that is where
  Zelda files your saved games. Here, the same byte for the same byte in a
  `.sav` file next to the ROM, the convention emulators share: a file from
  elsewhere loads here, ours reads elsewhere.

  The cycle: `load/2` reloads the file at startup (all of it — a zero byte
  that was loaded must read zero, not "open bus"); the game's writes mark the
  map `:cram_dirty` (CartLoop); `flush/2` only writes the file if the mark is
  there, then erases it — the periodic autosave and the exit path both call
  it without ever writing for nothing.

  8 KB on MBC1 (Link's Awakening), 32 KB in four banks on MBC3 (Pokémon) —
  the banks follow one another in the file, as everywhere, and in the map
  each bank lives at `addr + bank × 0x10000` (bank 0 keeps its bare keys).
  """

  @sram_base 0xA000
  @sram_size 0x2000

  @doc """
  The .sav path of a ROM: same name, .sav extension. With a profile — two
  players, two saved games, a single ROM file — the name slots in:
  `zelda.player1.sav`.
  """
  @spec path(Path.t(), String.t() | nil) :: Path.t()
  def path(rom_path, profile \\ nil)
  def path(rom_path, nil), do: Path.rootname(rom_path) <> ".sav"
  def path(rom_path, profile), do: Path.rootname(rom_path) <> ".#{profile}.sav"

  @doc "Reloads a .sav into the memory map — with no file, the map as it is."
  @spec load(map(), Path.t()) :: map()
  def load(ram, sav_path) do
    case File.read(sav_path) do
      {:ok, data} ->
        limit = banks(ram) * @sram_size

        data
        |> binary_part(0, min(byte_size(data), limit))
        |> :binary.bin_to_list()
        |> Enum.with_index()
        |> Enum.reduce(ram, fn {byte, i}, ram -> Map.put(ram, key(i), byte) end)

      _ ->
        ram
    end
  end

  @doc """
  Writes the .sav if the SRAM has changed since last time, and erases the
  mark. With no change, touches nothing.
  """
  @spec flush(map(), Path.t()) :: map()
  def flush(ram, sav_path) do
    if Map.get(ram, :cram_dirty, false) do
      File.write!(sav_path, snapshot(ram))
      Map.delete(ram, :cram_dirty)
    else
      ram
    end
  end

  defp snapshot(ram) do
    for i <- 0..(banks(ram) * @sram_size - 1), into: <<>> do
      <<Map.get(ram, key(i), 0)>>
    end
  end

  # Byte i of the file lives in bank div(i, 8 KB) — bare keys in bank 0.
  defp key(i), do: @sram_base + rem(i, @sram_size) + div(i, @sram_size) * 0x10000

  defp banks(ram), do: if(Map.get(ram, :mbc) == :mbc3, do: 4, else: 1)

  # ── Machine snapshots ───────────────────────────────────────────────────────

  @doc """
  The path of a snapshot: slot 1 is the historical file (`zelda.state`), slots
  2-9 add themselves alongside it (`zelda.case3.state` — the `case` in the
  name is kept as it is so that snapshots already on disk keep loading) — and
  the profile slots in as it does for the .sav.
  """
  @spec state_path(Path.t(), String.t() | nil, 1..9) :: Path.t()
  def state_path(rom_path, profile \\ nil, slot \\ 1) do
    base = Path.rootname(path(rom_path, profile))
    if slot == 1, do: base <> ".state", else: base <> ".case#{slot}.state"
  end

  @doc """
  Freezes the whole machine — CPU, memory, sound — into a file. Everything is
  immutable: three values are enough, term_to_binary does the rest.
  """
  @spec write_state(Path.t(), {struct(), map(), struct()}) :: :ok
  def write_state(path, {state, ram, apu}) do
    File.write!(path, :erlang.term_to_binary({:atomboy_state, 1, state, ram, apu}, [:compressed]))
  end

  @doc "Revives a snapshot. `:error` with no file, or a file of another format."
  @spec read_state(Path.t()) :: {:ok, {struct(), map(), struct()}} | :error
  def read_state(path) do
    with {:ok, data} <- File.read(path),
         {:atomboy_state, 1, state, ram, apu} <- :erlang.binary_to_term(data) do
      {:ok, {rehydrate(state), ram, rehydrate(apu)}}
    else
      _ -> :error
    end
  rescue
    ArgumentError -> :error
  end

  # A state file freezes yesterday's structs: `binary_to_term` hands back a
  # map wearing a `__struct__` tag, with exactly the fields the code had on
  # the day it was written. Passed through `struct/2`, the frozen fields
  # land on TODAY's definition — a field added since gets its default
  # instead of a KeyError seconds after loading, a field removed since is
  # quietly dropped. The library made states worth keeping; this keeps them
  # loadable across releases.
  defp rehydrate(%{__struct__: module} = frozen),
    do: struct(module, Map.delete(frozen, :__struct__))
end
