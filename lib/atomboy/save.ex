defmodule Atomboy.Save do
  @moduledoc """
  La pile de la cartouche : la RAM 0xA000-0xBFFF, persistée en `.sav`.

  Sur la vraie cartouche, une pile bouton garde la SRAM en vie — c'est là
  que Zelda range tes fichiers de partie. Ici, le même octet pour le même
  octet dans un fichier `.sav` à côté de la ROM, la convention que les
  émulateurs partagent : un fichier venu d'ailleurs se charge, le nôtre se
  lit ailleurs.

  Le cycle : `load/2` recharge le fichier au lancement (tout entier — un
  octet à zéro chargé doit se lire zéro, pas « bus ouvert ») ; les
  écritures du jeu marquent la map `:cram_dirty` (CartLoop) ; `flush/2`
  n'écrit le fichier que si la marque est là, puis l'efface — l'autosauve
  périodique et la sortie l'appellent sans jamais écrire pour rien.

  8 Ko sur MBC1 (Link's Awakening), 32 Ko en quatre banques sur MBC3
  (Pokémon) — les banques se suivent dans le fichier, comme partout, et
  dans la map chaque banque vit à `addr + banque × 0x10000` (la banque 0
  garde ses clés nues).
  """

  @sram_base 0xA000
  @sram_size 0x2000

  @doc "Le chemin du .sav d'une ROM : même nom, extension .sav."
  @spec path(Path.t()) :: Path.t()
  def path(rom_path), do: Path.rootname(rom_path) <> ".sav"

  @doc "Recharge un .sav dans la map mémoire — sans fichier, la map telle quelle."
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
  Écrit le .sav si la SRAM a changé depuis la dernière fois, et efface la
  marque. Sans changement, ne touche à rien.
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

  # L'octet i du fichier vit en banque div(i, 8 Ko) — clés nues en banque 0.
  defp key(i), do: @sram_base + rem(i, @sram_size) + div(i, @sram_size) * 0x10000

  defp banks(ram), do: if(Map.get(ram, :mbc) == :mbc3, do: 4, else: 1)
end
