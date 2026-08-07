defmodule Atomboy.ServerTest do
  use ExUnit.Case

  import ExUnit.CaptureIO

  # A ROM that spins in place: JR -2 at the 0x100 entry point.
  defp spinning_rom(dir) do
    rom = :binary.copy(<<0>>, 0x100) <> <<0x18, 0xFE>> <> :binary.copy(<<0>>, 0x8000 - 0x102)
    path = Path.join(dir, "loop.gb")
    File.write!(path, rom)
    path
  end

  defp split(<<?F, rgb::binary-size(160 * 144 * 3), rest::binary>>, frames, pcm, panels),
    do: split(rest, frames + 1, pcm, panels)

  defp split(<<?A, n::16-big, block::binary-size(n), rest::binary>>, frames, pcm, panels),
    do: split(rest, frames, pcm + byte_size(block), panels)

  defp split(<<?P, preset, rest::binary>>, frames, pcm, panels),
    do: split(rest, frames, pcm, panels ++ [preset])

  defp split(<<>>, frames, pcm, panels), do: {frames, pcm, panels}

  @tag :tmp_dir
  test "the server stream: RGB24 frames, PCM and the panel, nothing else", %{tmp_dir: dir} do
    rom = spinning_rom(dir)

    stream =
      capture_io([encoding: :latin1], fn ->
        assert :ok = Atomboy.Server.run(rom, frames: 3)
      end)

    {frames, pcm, panels} = split(stream, 0, 0, [])
    assert frames == 3
    # The wall-clock pacing starts with its lead (~2048 samples × 4).
    assert pcm >= 8192
    # s16le stereo: always a multiple of 4.
    assert rem(pcm, 4) == 0
    # The panel announced once, before anything else: raw is index 0.
    assert panels == [0]
    assert :binary.first(stream) == ?P
  end

  @tag :tmp_dir
  test "--panel travels down the wire as its preset index", %{tmp_dir: dir} do
    rom = spinning_rom(dir)

    stream =
      capture_io([encoding: :latin1], fn ->
        assert :ok = Atomboy.Server.run(rom, frames: 1, panel: :pocket)
      end)

    {_frames, _pcm, panels} = split(stream, 0, 0, [])
    assert panels == [Enum.find_index(Atomboy.LCD.presets(), &(&1 == :pocket))]
  end
end
