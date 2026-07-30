# Le premier jeu Potion : un héros carré qui marche au pouce.
#
#     mix run jeux/heros.exs
#
# écrit `jeux/heros.gb` — une vraie cartouche de 32 Ko, à ouvrir dans
# Atomboy.app, dans le terminal (`bin/play jeux/heros.gb`), ou à graver sur
# une flashcart. Modifier ce fichier et relancer la commande suffit : le
# compilateur refuse à la compilation ce que la console ne sait pas faire.

defmodule Heros do
  use Potion

  defacteur :heros do
    variables x: 80, y: 72

    chaque_frame do
      si appuye?(:droite), do: x = x + 1
      si appuye?(:gauche), do: x = x - 1
      si appuye?(:haut), do: y = y - 1
      si appuye?(:bas), do: y = y + 1
      sprite(0, x: x, y: y, tuile: 0)
    end
  end
end

chemin = Path.join(__DIR__, "heros.gb")
File.write!(chemin, Heros.rom())
IO.puts("#{chemin} — #{byte_size(Heros.rom())} octets, prêt à jouer.")
