defmodule Atomboy.KittyGfxTest do
  use ExUnit.Case, async: true

  alias Atomboy.Play.Input
  alias Atomboy.Screen

  test "the terminal's APC answer decodes" do
    assert Input.decode("\e_Gi=31;OK\e\\") == {[{:graphics, true}], ""}
    assert Input.decode("\e_Gi=31;EBADPNG\e\\") == {[{:graphics, false}], ""}
  end

  test "a truncated APC answer waits for the rest" do
    assert Input.decode("\e_Gi=31;O") == {[], "\e_Gi=31;O"}
    assert Input.decode("\e_") == {[], "\e_"}

    assert Input.decode("x\e_Gi=31;OK\e\\\r") ==
             {[{:key, :a}, {:graphics, true}, {:key, :start}], ""}
  end

  test "to_kitty encodes the whole frame, recoverable pixel for pixel" do
    # A real frame: shades 0..3 in a checkerboard.
    frame = for i <- 0..(160 * 144 - 1), into: <<>>, do: <<rem(i, 4)>>
    out = Screen.to_kitty(frame, :dmg, 1, 40) |> IO.iodata_to_binary()

    assert String.starts_with?(out, "\e_Ga=T,i=1,f=24,s=160,v=144,o=z,q=2,C=1,r=40")

    # Glue the chunks back: everything after a ";" up to ESC \\.
    payload =
      Regex.scan(~r/;([A-Za-z0-9+\/=]*)\e\\/, out)
      |> Enum.map_join("", fn [_, b64] -> b64 end)

    rgb = payload |> Base.decode64!() |> :zlib.uncompress()
    assert byte_size(rgb) == 160 * 144 * 3

    # The first pixel is shade 0 of the DMG palette.
    assert binary_part(rgb, 0, 3) == <<0x9B, 0xBC, 0x0F>>
    # The fourth, shade 3.
    assert binary_part(rgb, 9, 3) == <<0x0F, 0x38, 0x0F>>
  end

  test "the chunks respect the 4096-byte cap" do
    frame =
      :crypto.strong_rand_bytes(160 * 144)
      |> :binary.bin_to_list()
      |> Enum.map(&rem(&1, 4))
      |> :binary.list_to_bin()

    out = Screen.to_kitty(frame, :gray, 2, 30) |> IO.iodata_to_binary()

    Regex.scan(~r/;([A-Za-z0-9+\/=]*)\e\\/, out)
    |> Enum.each(fn [_, b64] -> assert byte_size(b64) <= 4096 end)
  end
end
