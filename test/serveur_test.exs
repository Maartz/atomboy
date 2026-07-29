defmodule Atomboy.ServeurTest do
  use ExUnit.Case

  import ExUnit.CaptureIO

  # Une ROM qui boucle sur place : JR -2 à l'entrée 0x100.
  defp rom_tournante(dir) do
    rom = :binary.copy(<<0>>, 0x100) <> <<0x18, 0xFE>> <> :binary.copy(<<0>>, 0x8000 - 0x102)
    path = Path.join(dir, "boucle.gb")
    File.write!(path, rom)
    path
  end

  defp découpe(<<?F, rgb::binary-size(160 * 144 * 3), rest::binary>>, frames, pcm),
    do: découpe(rest, frames + 1, pcm)

  defp découpe(<<?A, n::16-big, bloc::binary-size(n), rest::binary>>, frames, pcm),
    do: découpe(rest, frames, pcm + byte_size(bloc))

  defp découpe(<<>>, frames, pcm), do: {frames, pcm}

  @tag :tmp_dir
  test "le flux serveur : des frames RGB24 et du PCM, rien d'autre", %{tmp_dir: dir} do
    rom = rom_tournante(dir)

    flux =
      capture_io([encoding: :latin1], fn ->
        assert :ok = Atomboy.Serveur.run(rom, frames: 3)
      end)

    {frames, pcm} = découpe(flux, 0, 0)
    assert frames == 3
    # La cadence murale démarre avec son avance (~2048 échantillons × 4).
    assert pcm >= 8192
    # s16le stéréo : toujours un multiple de 4.
    assert rem(pcm, 4) == 0
  end
end
