# Le premier jeu Potion : un héros carré qui marche au pouce.
#
#     mix run jeux/hero.exs
#
# écrit `jeux/hero.gb` — une vraie cartouche de 32 Ko, à ouvrir dans
# Atomboy.app, dans le terminal (`bin/play jeux/hero.gb`), ou à graver sur
# une flashcart. Modifier ce fichier et relancer la commande suffit : le
# compilateur refuse à la compilation ce que la console ne sait pas faire.

defmodule Hero do
  use Potion

  defactor :hero do
    variables x: 80, y: 72

    every_frame do
      if pressed?(:right), do: x = x + 1
      if pressed?(:left), do: x = x - 1
      if pressed?(:up), do: y = y - 1
      if pressed?(:down), do: y = y + 1
      sprite(0, x: x, y: y, tile: 0)
    end
  end
end

chemin = Path.join(__DIR__, "hero.gb")
File.write!(chemin, Hero.rom())
IO.puts("#{chemin} — #{byte_size(Hero.rom())} octets, prêt à jouer.")
