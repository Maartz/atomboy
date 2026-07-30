defmodule Potion.NoyauTest do
  @moduledoc """
  Le noyau v0, vérifié là où ça compte : dans l'émulateur, frames déroulées.

  Aucun test ne relit les octets que le noyau émet — un assembleur qui se
  relit lui-même ne prouve rien de plus que sa propre cohérence, et
  `Potion.AssembleurTest` s'en charge déjà sur les 500 instructions. Ici, la
  seule question est : la ROM tourne-t-elle, et fait-elle ce qu'un jeu attend
  d'un runtime ? L'écran s'allume, l'OAM se publie, un sprite apparaît à la
  bonne place, le pad le déplace, et l'acteur tourne exactement une fois par
  frame.

  L'acteur de test tient tout entier dans `acteur/0` : il compte les frames,
  se place au centre, avance à droite quand on le lui demande, et publie son
  entrée d'OAM dans le miroir. C'est le jeu que le DSL v0 devra savoir écrire.

  ## Le calendrier du démarrage

  L'init n'est pas instantané : attendre le vblank prend jusqu'à une frame,
  effacer la VRAM en prend une autre. L'écran s'allume donc dans la troisième
  frame, et l'acteur tourne pour la première fois à son vblank. Le sprite,
  publié par le DMA de la frame suivante, devient visible à la cinquième. Les
  tests laissent de la marge, et ceux qui comptent les tours de l'acteur le
  font en écart sur une fenêtre — pas en valeur absolue depuis le boot.
  """

  use ExUnit.Case, async: true

  alias Atomboy.Joypad
  alias Atomboy.Screen
  alias Potion.Noyau
  alias Potion.ROM

  # L'état de l'acteur de test, dans la page que le noyau lui laisse.
  @compteur 0xC100
  @sprite_x 0xC101
  @installe 0xC102
  @sprite_y 0xC103

  # Le sprite de départ, en coordonnées écran — le noyau ne connaît que
  # l'OAM, où la même position s'écrit décalée de 16 en Y et de 8 en X.
  @depart_x 80
  @depart_y 72

  describe "le programme" do
    test "l'acteur est encadré par le noyau, et nommé par lui" do
      adresses = Potion.Assembleur.adresses(Noyau.programme(acteur()), origine: 0x0150)

      # Le point d'entrée de la cartouche tombe sur l'init.
      assert adresses.init == 0x0150
      # Les deux étiquettes que le reste du monde connaît.
      assert Map.has_key?(adresses, :vblank)
      assert Map.has_key?(adresses, :acteur)
      # L'acteur est le dernier venu : tout le noyau le précède.
      assert adresses.acteur > adresses.boucle
      # Et l'état de l'acteur de test tient dans la page que le noyau promet.
      assert @compteur == Noyau.etat()
    end

    test "un acteur sans RET est refusé à l'assemblage, pas à l'exécution" do
      erreur =
        assert_raise ArgumentError, fn ->
          Noyau.programme([{:ld, :a, 0x01}, {:ld, {:mem, 0xC000}, :a}])
        end

      assert erreur.message =~ "ne finit pas par un RET"
    end

    test "la routine DMA est celle du matériel, assemblée à son adresse" do
      # LD A, 0xC0 / LDH (0x46), A / LD A, 40 / DEC A / JR NZ, -3 / RET —
      # la routine canonique, dix octets, écrite par l'assembleur et non à la
      # main.
      assert Noyau.octets_dma() == <<0x3E, 0xC0, 0xE0, 0x46, 0x3E, 0x28, 0x3D, 0x20, 0xFD, 0xC9>>
    end
  end

  describe "l'init" do
    test "l'écran s'allume, les palettes et l'interruption sont posées" do
      {_pixels, _state, ram} = deroule(6)

      assert Map.get(ram, 0xFF40) == 0x93
      assert Map.get(ram, 0xFFFF) == 0x01
      assert Map.get(ram, 0xFF47) == 0xE4
      assert Map.get(ram, 0xFF48) == 0xE4
      # Le fond est recentré : un SCX oublié décalerait toute la carte.
      assert Map.get(ram, 0xFF42) == 0x00
      assert Map.get(ram, 0xFF43) == 0x00
    end

    test "la VRAM est effacée, la tuile 0 pleine, la carte de fond vide" do
      {_pixels, _state, ram} = deroule(6)

      # Les seize octets de la tuile 0 : le carré plein.
      assert for(i <- 0..15, do: Map.get(ram, 0x8000 + i)) == List.duplicate(0xFF, 16)
      # La tuile 1 est restée celle que l'effacement a laissée — c'est elle
      # que la carte de fond désigne, et c'est ce qui rend le sprite visible.
      assert for(i <- 0..15, do: Map.get(ram, 0x8010 + i)) == List.duplicate(0x00, 16)
      # La carte de fond, d'un bout à l'autre.
      assert Map.get(ram, 0x9800) == 0x01
      assert Map.get(ram, 0x9BFF) == 0x01
      # Et la fin de la VRAM, que rien n'a écrite depuis.
      assert Map.get(ram, 0x9FFF) == 0x00
    end

    test "la routine DMA a bien été recopiée en HRAM" do
      {_pixels, _state, ram} = deroule(6)

      copiee =
        for i <- 0..(byte_size(Noyau.octets_dma()) - 1),
            into: <<>>,
            do: <<Map.get(ram, 0xFF80 + i)>>

      assert copiee == Noyau.octets_dma()
    end
  end

  describe "le DMA" do
    test "l'OAM réelle reflète le miroir après un vblank" do
      {_pixels, _state, ram} = deroule(6)

      miroir = for i <- 0..3, do: Map.get(ram, Noyau.oam_miroir() + i)

      assert miroir == [@depart_y + 16, @depart_x + 8, 0x00, 0x00]
      assert for(i <- 0..3, do: Map.get(ram, 0xFE00 + i)) == miroir
    end

    test "les 39 autres entrées sont publiées aussi, et hors écran" do
      {_pixels, _state, ram} = deroule(6)

      # L'acteur n'a écrit que l'entrée 0 ; le reste du miroir est le zéro
      # posé par l'init, et un Y de zéro place le sprite à -16 — invisible.
      # Le DMA copie les 160 octets, pas seulement ceux qui ont changé.
      assert for(i <- 4..159, do: Map.get(ram, 0xFE00 + i)) == List.duplicate(0x00, 156)
    end
  end

  describe "l'écran" do
    test "le sprite est un carré de huit sur huit, à sa place, sur un fond blanc" do
      {pixels, _state, _ram} = deroule(6, render: true)

      assert byte_size(pixels) == 160 * 144

      # La boîte des pixels non blancs est exactement celle du sprite.
      attendue =
        for y <- @depart_y..(@depart_y + 7),
            x <- @depart_x..(@depart_x + 7),
            into: MapSet.new() do
          {x, y}
        end

      assert non_blancs(pixels) == attendue

      # Et la teinte est celle de la couleur 3 par OBP0 : la plus sombre.
      assert :binary.at(pixels, @depart_y * 160 + @depart_x) == 3
    end
  end

  describe "le pad" do
    test "Droite appuyée fait avancer le sprite, relâchée l'arrête" do
      {_pixels, state, ram} = deroule(5)

      assert Map.get(ram, @sprite_x) == @depart_x

      # Droite seule : les nappes sont actives à zéro côté matériel, c'est
      # Joypad.set qui parle ce langage-là.
      {state, ram} = frames(state, Joypad.set(ram, 0x0F - 0x01, 0x0F), 4)

      assert Map.get(ram, @sprite_x) == @depart_x + 4
      # L'OAM suit — d'une frame en retard, le DMA publiant ce que l'acteur a
      # écrit au vblank précédent.
      assert Map.get(ram, 0xFE01) == @depart_x + 3 + 8

      # Relâchée : la position se fige.
      {_state, ram} = frames(state, Joypad.set(ram, 0x0F, 0x0F), 4)

      assert Map.get(ram, @sprite_x) == @depart_x + 4
      assert Map.get(ram, 0xFE01) == @depart_x + 4 + 8
    end

    test "l'octet d'état est à l'endroit : d-pad en bas, boutons en haut" do
      {_pixels, state, ram} = deroule(5)

      assert Map.get(ram, Noyau.pad()) == 0x00

      # Start est le bit 3 de la nappe des boutons, donc le bit 7 de l'octet
      # recomposé.
      {state, ram} = frames(state, Joypad.set(ram, 0x0F, 0x0F - 0x08), 2)
      assert Map.get(ram, Noyau.pad()) == 0x80

      # Haut et A ensemble : une touche par nappe, deux quartets.
      {state, ram} = frames(state, Joypad.set(ram, 0x0F - 0x04, 0x0F - 0x01), 2)
      assert Map.get(ram, Noyau.pad()) == 0x14

      {_state, ram} = frames(state, Joypad.set(ram, 0x0F, 0x0F), 2)
      assert Map.get(ram, Noyau.pad()) == 0x00
      # Le noyau repose les deux nappes : le registre relit tout relâché.
      assert Map.get(ram, 0xFF00) == 0xFF
    end
  end

  describe "le battement" do
    test "l'acteur tourne exactement une fois par frame" do
      {_pixels, state, ram} = deroule(5)

      avant = Map.get(ram, @compteur)
      {_state, ram} = frames(state, ram, 7)

      assert Map.get(ram, @compteur) == avant + 7
    end

    test "le drapeau se lève au vblank et la boucle le consomme" do
      {_pixels, state, ram} = deroule(5)

      assert Map.get(ram, Noyau.drapeau()) == 0x00
      compteur = Map.get(ram, @compteur)

      # Une frame déroulée à la scanline, pour surprendre le noyau au travail.
      # À la ligne 144 l'interruption est partie, le handler a levé le drapeau
      # et lancé le DMA — mais la boucle principale, encore dans le RETI, ne
      # l'a pas consommé.
      {state, ram} =
        Enum.reduce(0..144, {state, ram}, fn ly, {state, ram} ->
          Screen.step_line(state, rom(), ram, ly)
        end)

      assert Map.get(ram, Noyau.drapeau()) == 0x01
      assert Map.get(ram, @compteur) == compteur

      # Le reste du vblank : la boucle se réveille, consomme le drapeau et
      # appelle l'acteur — une fois.
      {_state, ram} =
        Enum.reduce(145..153, {state, ram}, fn ly, {state, ram} ->
          Screen.step_line(state, rom(), ram, ly)
        end)

      assert Map.get(ram, Noyau.drapeau()) == 0x00
      assert Map.get(ram, @compteur) == compteur + 1
    end

    test "le processeur dort entre deux frames au lieu de brûler la boucle" do
      {_pixels, state, ram} = deroule(6)

      # Une frame de plus s'arrête forcément dans le HALT : la boucle
      # principale ne tient que quelques centaines de cycles, la frame en
      # compte 70 000. Le PC est donc juste après le HALT, et l'état halted
      # est celui d'un processeur qui attend le vblank.
      {_pixels, state, _ram} = Screen.frame(state, rom(), ram, false)

      assert state.halted
      assert state.ime == 1
    end
  end

  # ══ Le harnais ═══════════════════════════════════════════════════════════════

  # La ROM du noyau et de l'acteur de test.
  defp rom, do: ROM.construit(Noyau.programme(acteur()), vblank: :vblank, titre: "NOYAU")

  # `frames` frames depuis le boot ; la dernière rendue si demandé.
  defp deroule(nombre, opts \\ []) do
    rom = rom()
    render? = Keyword.get(opts, :render, false)

    Enum.reduce(1..nombre, {<<>>, Screen.boot_state(rom), Screen.boot_ram(rom)}, fn n,
                                                                                    {_p, state,
                                                                                     ram} ->
      Screen.frame(state, rom, ram, render? and n == nombre)
    end)
  end

  # Des frames de plus depuis un état en vol. La map passée est celle que le
  # monde extérieur vient éventuellement de toucher — les touches, ici.
  defp frames(state, ram, nombre) do
    rom = rom()

    Enum.reduce(1..nombre, {state, ram}, fn _n, {state, ram} ->
      {_pixels, state, ram} = Screen.frame(state, rom, ram, false)
      {state, ram}
    end)
  end

  defp non_blancs(pixels) do
    for i <- 0..(byte_size(pixels) - 1),
        :binary.at(pixels, i) != 0,
        into: MapSet.new(),
        do: {rem(i, 160), div(i, 160)}
  end

  # ── L'acteur de test ────────────────────────────────────────────────────────

  # Un jeu de trente instructions : compter les frames, se placer au premier
  # tour, avancer à droite sous la touche, publier son sprite dans le miroir.
  # Il tient dans la page 0xC100 que le noyau lui laisse — et compte sur le
  # zéro que l'init y a posé pour savoir qu'il n'est pas encore installé.
  defp acteur do
    oam = Noyau.oam_miroir()

    [
      {:ld, :a, {:mem, @compteur}},
      {:inc, :a},
      {:ld, {:mem, @compteur}, :a},
      {:ld, :a, {:mem, @installe}},
      {:and, :a, :a},
      {:jr, :nz, {:etiquette, :acteur_maj}},
      {:ld, :a, 0x01},
      {:ld, {:mem, @installe}, :a},
      {:ld, :a, @depart_x},
      {:ld, {:mem, @sprite_x}, :a},
      {:ld, :a, @depart_y},
      {:ld, {:mem, @sprite_y}, :a},
      {:etiquette, :acteur_maj},
      {:ld, :a, {:mem, Noyau.pad()}},
      {:bit, 0, :a},
      {:jr, :z, {:etiquette, :acteur_publie}},
      {:ld, :a, {:mem, @sprite_x}},
      {:inc, :a},
      {:ld, {:mem, @sprite_x}, :a},
      # L'entrée 0 de l'OAM miroir : le décalage matériel est du ressort de
      # l'acteur, le noyau ne connaît que des octets d'OAM.
      {:etiquette, :acteur_publie},
      {:ld, :a, {:mem, @sprite_y}},
      {:add, :a, 16},
      {:ld, {:mem, oam}, :a},
      {:ld, :a, {:mem, @sprite_x}},
      {:add, :a, 8},
      {:ld, {:mem, oam + 1}, :a},
      {:xor, :a, :a},
      {:ld, {:mem, oam + 2}, :a},
      {:ld, {:mem, oam + 3}, :a},
      {:ret}
    ]
  end
end
