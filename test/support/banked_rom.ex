defmodule Atomboy.BankedROM do
  @moduledoc """
  Synthetic MBC1 cartridge ROM builder for testing bank switching.

  Generates a complete MBC1 cartridge with configurable bank count, fills each
  bank with an identifying byte pattern, and places a small test program in bank 0
  that exercises the bank-switching hardware. Useful for validating ROM bank
  selection against the emulator's oracle.
  """

  import Bitwise

  alias Potion.Assembler

  # The Nintendo logo, bit for bit — the boot ROM's legal lock.
  @logo <<0xCE, 0xED, 0x66, 0x66, 0xCC, 0x0D, 0x00, 0x0B, 0x03, 0x73, 0x00, 0x83, 0x00, 0x0C,
          0x00, 0x0D, 0x00, 0x08, 0x11, 0x1F, 0x88, 0x89, 0x00, 0x0E, 0xDC, 0xCC, 0x6E, 0xE6,
          0xDD, 0xDD, 0xD9, 0x99, 0xBB, 0xBB, 0x67, 0x63, 0x6E, 0x0E, 0xEC, 0xCC, 0xDD, 0xDC,
          0x99, 0x9F, 0xBB, 0xB9, 0x33, 0x3E>>

  @bank_size 0x4000
  @origin 0x0150

  @doc """
  Builds a synthetic MBC1 cartridge whose banks are told apart by sight.

  Bank N is 16 KB of the byte N, so a program that selects a bank and reads one
  byte of it learns which bank actually answered. Bank 0 carries the header and
  the program instead, and is never the one read.

  Options:

    * `:banks` -- how many, a power of two, at least two. Four by default.
    * `:selects` -- the bank numbers the program asks for, in order. Every bank
      but the zeroth by default. Pass values the MBC has to correct -- `0`, or a
      number past the last bank -- to exercise the clamps.

  Returns `{rom, expectations}`, where `expectations` maps each WRAM cell the
  program fills to the bank that must have answered: index I of `:selects` lands
  at `0xC000 + I`, and holds the *clamped* bank, not the one asked for.
  """
  @spec build(keyword()) :: {binary(), %{non_neg_integer() => byte()}}
  def build(opts \\ []) do
    banks = Keyword.get(opts, :banks, 4)

    if banks < 2 or (banks &&& banks - 1) != 0 do
      raise ArgumentError, "#{banks} banks: a cartridge carries a power of two, at least two"
    end

    selects = Keyword.get(opts, :selects, Enum.to_list(1..(banks - 1)//1))
    code = Assembler.assemble(test_program(selects), origin: @origin)

    bank0 = build_bank0(rom_size_code(banks), code)
    others = for bank <- 1..(banks - 1)//1, do: :binary.copy(<<bank::8>>, @bank_size)

    expectations =
      selects
      |> Enum.with_index()
      |> Map.new(fn {select, index} -> {0xC000 + index, clamp(select, banks)} end)

    {bank0 <> IO.iodata_to_binary(others), expectations}
  end

  @doc """
  The bank MBC1 actually maps when a program asks for `value`.

  `Atomboy.CPU.CartLoop`'s formula, kept here so a test can state what it
  expects without deriving it from the thing under test. The two clamps are not
  one: the first is the hardware refusing to put bank 0 at 0x4000, the second
  catches the zero the mask can produce on a small cartridge.
  """
  @spec clamp(byte(), pos_integer()) :: pos_integer()
  def clamp(value, banks), do: max(max(value &&& 0x1F, 1) &&& banks - 1, 1)

  # Build bank 0: vectors, entry point, logo, title, header, checksums, and program
  defp build_bank0(rom_size_byte, code) do
    # 0x00-0xFF: interrupt vectors (all zeros for this test)
    vectors = :binary.copy(<<0x00>>, 0x100)

    # 0x100-0x103: entry point (NOP then JP 0x150)
    entry_point = <<0x00, 0xC3, @origin::16-little>>

    # 0x104-0x133: Nintendo logo (required by boot ROM)
    # 0x134-0x143: Title (16 bytes: "BANKED" + 10 zeros makes 16)
    title = "BANKED" <> :binary.copy(<<0x00>>, 10)

    # 0x144-0x14C: cartridge-specific fields
    # Build the cartridge fields section:
    #   0x144-0x146: Padding/SGB flag/etc (zeros)
    #   0x147: Cartridge type (0x01 for MBC1)
    #   0x148: ROM size
    #   0x149: RAM size (0x00 for none)
    #   0x14A-0x14C: Padding (zeros)
    # Total: 9 bytes (0x14D - 0x144)
    cartridge_fields =
      :binary.copy(<<0x00>>, 3) <> <<0x01, rom_size_byte, 0x00>> <> :binary.copy(<<0x00>>, 3)

    # Build header body (0x00 to 0x14C, inclusive)
    header_body = vectors <> entry_point <> @logo <> title <> cartridge_fields

    # 0x14D: Header checksum (the boot ROM verifies this)
    header_checksum_value = compute_header_checksum(header_body)
    header = header_body <> <<header_checksum_value>>

    # 0x14E-0x14F: Global checksum (placeholder, will recompute)
    partial = header <> <<0x00, 0x00>> <> code

    # Pad to full bank size (0x4000 bytes)
    padding_size = @bank_size - byte_size(partial)

    if padding_size < 0 do
      raise ArgumentError,
            "program too large: #{byte_size(code)} bytes; " <>
              "maximum #{@bank_size - @origin} bytes available in bank 0"
    end

    padded = partial <> :binary.copy(<<0x00>>, padding_size)

    # Compute the global checksum (sum of all bytes)
    global_checksum_value = compute_global_checksum(padded)

    # Assemble: header + global checksum + program + padding
    binary_part(padded, 0, 0x14E) <>
      <<global_checksum_value::16-big>> <>
      binary_part(padded, 0x150, byte_size(padded) - 0x150)
  end

  # Header checksum: x = x - byte - 1 over bytes 0x134-0x14C
  defp compute_header_checksum(header_body) do
    header_body
    |> binary_part(0x134, 0x14D - 0x134)
    |> :binary.bin_to_list()
    |> Enum.reduce(0, fn byte, checksum -> checksum - byte - 1 &&& 0xFF end)
  end

  # Global checksum: sum of all bytes (except 0x14E-0x14F at computation time)
  defp compute_global_checksum(rom) do
    rom |> :binary.bin_to_list() |> Enum.sum() |> band(0xFFFF)
  end

  # Map bank count to ROM size byte (header byte 0x148)
  defp rom_size_code(banks) do
    case banks do
      # 32 KB (2 banks × 16 KB)
      2 -> 0x00
      # 64 KB (4 banks × 16 KB)
      4 -> 0x01
      # 128 KB
      8 -> 0x02
      # 256 KB
      16 -> 0x03
      # 512 KB
      32 -> 0x04
      # 1 MB
      64 -> 0x05
      # 2 MB
      128 -> 0x06
      # 4 MB
      256 -> 0x07
      _ -> raise ArgumentError, "unsupported bank count: #{banks}"
    end
  end

  # For each bank asked for: select it at 0x2000, read the first byte of the
  # window at 0x4000, and drop it in WRAM. Then stop moving, so the frame ends
  # somewhere predictable.
  defp test_program(selects) do
    body =
      selects
      |> Enum.with_index()
      |> Enum.flat_map(fn {select, index} ->
        [
          {:ld, :a, select},
          {:ld, {:mem, 0x2000}, :a},
          {:ld, :a, {:mem, 0x4000}},
          {:ld, {:mem, 0xC000 + index}, :a}
        ]
      end)

    body ++ [{:label, :settled}, {:jr, {:label, :settled}}]
  end
end
