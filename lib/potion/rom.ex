defmodule Potion.ROM do
  @moduledoc """
  Assembling the cartridge: from a program to a ROM the hardware would accept.

  ## What the boot demands

  The DMG boot ROM trusts nothing: it copies the Nintendo logo out of the header
  (0x104-0x133), compares it with its own, checks the checksum of bytes
  0x134-0x14C — and freezes the machine if either one lies. Atomboy, for its
  part, skips the boot ROM and demands none of that; but Potion aims at the real
  Game Boy through a flashcart, and a ROM that only passed in our own emulator
  would be proof on the cheap. So we write the full header, checksums included,
  from the very first ROM.

  The global checksum (0x14E-0x14F, big-endian — the only big-endian value in
  the whole console) is verified by nothing, not even the hardware. We compute it
  all the same: it is the integrity hash that third-party tools display, and a
  wrong field shows.

  ## The map of the cartridge

      0x0000-0x00FF   RST and interrupt vectors — zeros, except the vblank
                      vector (0x40) if the program provides one
      0x0100          the entry point: NOP then JP 0x150
      0x0104-0x0133   the Nintendo logo, bit for bit
      0x0134-0x0143   the title, uppercase ASCII; 0x143 stays 0x00 — a Potion
                      ROM is DMG, colour will wait until the language stands
                      on its own feet
      0x0147-0x0149   type 0x00 (ROM only, no MBC), 32 KB, no RAM
      0x014D          the header checksum the boot verifies
      0x014E-0x014F   the global checksum
      0x0150-0x7FFF   the program, assembled by `Potion.Assembler`,
                      then padding

  32 KB without an MBC: the smallest format there is, and `Atomboy.Screen`
  derives two flat banks from it — no bank register to emulate for the
  language's first ROMs.
  """

  import Bitwise

  alias Potion.Assembler

  # The 48 bytes the boot ROM compares with its own. They draw the word
  # "Nintendo" — it was the console's legal lock: burning them into a pirate
  # cartridge meant counterfeiting the trademark.
  @logo <<0xCE, 0xED, 0x66, 0x66, 0xCC, 0x0D, 0x00, 0x0B, 0x03, 0x73, 0x00, 0x83, 0x00, 0x0C,
          0x00, 0x0D, 0x00, 0x08, 0x11, 0x1F, 0x88, 0x89, 0x00, 0x0E, 0xDC, 0xCC, 0x6E, 0xE6,
          0xDD, 0xDD, 0xD9, 0x99, 0xBB, 0xBB, 0x67, 0x63, 0x6E, 0x0E, 0xEC, 0xCC, 0xDD, 0xDC,
          0x99, 0x9F, 0xBB, 0xB9, 0x33, 0x3E>>

  @size 0x8000
  @origin 0x0150
  @room @size - @origin

  @doc """
  Builds a 32 KB ROM around a `Potion.Assembler` program.

  Options:

    * `:title` — the name in the header, fifteen ASCII characters at most,
      upcased. Defaults to `"POTION"`.
    * `:vblank` — the name of a label in the program; vector 0x40 becomes a
      `JP` to it. Without it, an armed vblank interrupt would execute zeros —
      that is, `NOP`s until it derailed.
  """
  @spec build([Assembler.element()], keyword()) :: binary()
  def build(program, opts \\ []) do
    title = opts |> Keyword.get(:title, "POTION") |> title!()
    code = Assembler.assemble(program, origin: @origin)

    if byte_size(code) > @room do
      raise ArgumentError,
            "program too large: #{byte_size(code)} bytes for #{@room} " <>
              "available between 0x0150 and 0x7FFF — MBC banks remain to be written"
    end

    vectors = vectors(program, Keyword.get(opts, :vblank))

    body =
      vectors <>
        <<0x00, 0xC3, @origin::16-little>> <>
        @logo <>
        title <>
        :binary.copy(<<0x00>>, 0x14D - 0x144)

    header = body <> <<header_checksum(body)>>
    padded = header <> <<0, 0>> <> code <> :binary.copy(<<0x00>>, @room - byte_size(code))

    checksum = global_checksum(padded)
    binary_part(padded, 0, 0x14E) <> <<checksum::16-big>> <> binary_part(padded, 0x150, @room)
  end

  # The first 256 bytes: zeros, except the requested vblank vector. The zeros
  # are harmless NOPs as long as no interrupt is armed.
  defp vectors(_program, nil), do: :binary.copy(<<0x00>>, 0x100)

  defp vectors(program, label) do
    addresses = Assembler.addresses(program, origin: @origin)

    target =
      case addresses do
        %{^label => address} ->
          address

        _ ->
          raise ArgumentError,
                "vblank vector: the label #{inspect(label)} does not exist " <>
                  "in the program"
      end

    :binary.copy(<<0x00>>, 0x40) <>
      <<0xC3, target::16-little>> <>
      :binary.copy(<<0x00>>, 0x100 - 0x43)
  end

  defp title!(title) do
    upcased = String.upcase(title)

    cond do
      byte_size(upcased) > 15 ->
        raise ArgumentError,
              "title too long: #{inspect(title)} is #{byte_size(title)} characters, " <>
                "the header holds only fifteen"

      not (upcased |> String.to_charlist() |> Enum.all?(&(&1 in 0x20..0x7E))) ->
        raise ArgumentError,
              "title outside ASCII: #{inspect(title)} — a cartridge header does " <>
                "not know accents"

      true ->
        upcased <> :binary.copy(<<0x00>>, 16 - byte_size(upcased))
    end
  end

  # The checksum the boot ROM verifies: x = x - byte - 1 over 0x134-0x14C.
  # `body` stops just before 0x14D, so its tail IS the summed range.
  defp header_checksum(body) do
    body
    |> binary_part(0x134, 0x14D - 0x134)
    |> :binary.bin_to_list()
    |> Enum.reduce(0, fn byte, checksum -> checksum - byte - 1 &&& 0xFF end)
  end

  # The sum of every byte, except its own two slots (still zero at this point,
  # so summing everything comes to the same thing).
  defp global_checksum(rom) do
    rom |> :binary.bin_to_list() |> Enum.sum() |> band(0xFFFF)
  end
end
