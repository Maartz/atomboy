defmodule Potion.DSLTest do
  @moduledoc """
  Le langage, vérifié aux deux bouts : dans l'émulateur, et dans `mix compile`.

  Un DSL qui compile vers du matériel a deux façons de mentir. La première est
  d'émettre des octets qui ne font pas ce que le jeu dit : le seul juge en est
  la console, donc les jeux de ce fichier sont *joués* — bootés dans
  `Atomboy.Screen`, frames déroulées, pad simulé, pixels relus. La seconde est
  d'accepter une phrase qu'il ne sait pas traduire, et de la traduire quand
  même, ou à moitié : le seul juge en est le compilateur, donc les refus sont
  testés en compilant vraiment des modules — `Code.compile_string`, pas un appel
  direct au compilo — parce que c'est là que le programmeur les rencontrera.

  Le jeu `Heros` est mot pour mot celui du moduledoc de `Potion`. C'est
  volontaire : la vitrine du langage est aussi son test principal, et elle ne
  peut donc pas pourrir.

  Le calendrier du démarrage est celui du noyau (voir `Potion.NoyauTest`) :
  l'init prend deux frames, l'acteur tourne pour la première fois au vblank de
  la troisième, et le DMA publie son OAM à la suivante. On déroule cinq frames
  avant de regarder l'état, six avant de regarder l'écran.
  """

  use ExUnit.Case, async: true

  alias Atomboy.Joypad
  alias Atomboy.Screen
  alias Potion.Assembleur

  doctest Potion.Compilo

  # Les nappes du joypad, telles que `Atomboy.Joypad.set/3` les veut : un
  # quartet par nappe, à 1 = relâché. Le matériel est actif à zéro, et c'est le
  # noyau qui remet les touches à l'endroit dans sa cellule de pad.
  @relache 0x0F
  @droite 0x0F - 0x01
  @gauche 0x0F - 0x02
  @haut 0x0F - 0x04
  @bas 0x0F - 0x08

  @depart_x 80
  @depart_y 72

  # ── Le jeu de la surface fixée ──────────────────────────────────────────────

  defmodule Heros do
    @moduledoc false
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

  # Un second jeu, pour les formes que le héros n'exerce pas : une affectation
  # sèche, un littéral et une variable mélangés dans un même `sprite`, une
  # entrée d'OAM autre que la première, et un bloc `si` à plusieurs énoncés.
  defmodule Melange do
    @moduledoc false
    use Potion

    defacteur :melange do
      variables largeur: 10, hauteur: 20

      chaque_frame do
        largeur = 5

        si appuye?(:a) do
          largeur = largeur + 1
          hauteur = hauteur + 2
        end

        sprite(1, x: largeur, y: 40, tuile: 3)
        sprite(2, x: 100, y: hauteur, tuile: 0)
      end
    end
  end

  describe "le jeu de la surface fixée" do
    test "la ROM boote et le sprite est un carré au centre de l'écran" do
      {pixels, _state, _ram} = deroule(Heros, 6, render: true)

      assert byte_size(pixels) == 160 * 144

      # Un carré de huit sur huit, dont le coin haut-gauche est exactement à la
      # position écrite dans le jeu — c'est le décalage matériel de l'OAM que le
      # compilateur a payé pour nous.
      assert non_blancs(pixels) == boite(@depart_x, @depart_y)
      # Couleur 3 par OBP0 : la plus sombre des quatre.
      assert :binary.at(pixels, @depart_y * 160 + @depart_x) == 3
    end

    test "Droite déplace le sprite, et l'OAM suit" do
      {_pixels, state, ram} = deroule(Heros, 5)
      adresses = Heros.adresses()

      {_state, ram} = frames(Heros, state, Joypad.set(ram, @droite, @relache), 4)

      assert Map.get(ram, adresses.x) == @depart_x + 4
      assert Map.get(ram, adresses.y) == @depart_y

      # L'OAM réelle est d'une frame en retard : le DMA publie au vblank ce que
      # l'acteur a écrit dans le miroir au vblank précédent.
      assert Map.get(ram, 0xFE01) == @depart_x + 3 + 8
      assert Map.get(ram, 0xFE00) == @depart_y + 16
    end

    test "Gauche, Haut et Bas déplacent le sprite dans leur sens" do
      {_pixels, state, ram} = deroule(Heros, 5)
      adresses = Heros.adresses()

      {state, ram} = frames(Heros, state, Joypad.set(ram, @gauche, @relache), 3)
      assert position(ram, adresses) == {@depart_x - 3, @depart_y}

      {state, ram} = frames(Heros, state, Joypad.set(ram, @haut, @relache), 5)
      assert position(ram, adresses) == {@depart_x - 3, @depart_y - 5}

      {state, ram} = frames(Heros, state, Joypad.set(ram, @bas, @relache), 2)
      assert position(ram, adresses) == {@depart_x - 3, @depart_y - 3}

      # Relâché, plus rien ne bouge : chaque `si` est un JR par-dessus son bloc,
      # pas un état retenu.
      {_state, ram} = frames(Heros, state, Joypad.set(ram, @relache, @relache), 4)
      assert position(ram, adresses) == {@depart_x - 3, @depart_y - 3}
    end

    test "le sprite déplacé est là où le pad l'a mis, à l'écran" do
      {_pixels, state, ram} = deroule(Heros, 5)

      {state, ram} = frames(Heros, state, Joypad.set(ram, @droite, @relache), 6)
      {state, ram} = frames(Heros, state, Joypad.set(ram, @bas, @relache), 3)

      # Touches relâchées, une frame de battement : ce que l'écran montre est en
      # retard de deux vblanks sur l'acteur — le DMA publie au vblank ce que
      # l'acteur avait écrit au vblank précédent, et les lignes visibles d'une
      # frame précèdent son vblank. Sur un sprite immobile ça ne se voit pas ;
      # sur un sprite qui vient de bouger, il faut laisser le tuyau se vider.
      {state, ram} = frames(Heros, state, Joypad.set(ram, @relache, @relache), 1)
      {pixels, _state, _ram} = Screen.frame(state, Heros.rom(), ram, true)

      assert non_blancs(pixels) == boite(@depart_x + 6, @depart_y + 3)
    end
  end

  describe "les valeurs initiales" do
    test "les cellules allouées portent 80 et 72, sans que rien ne soit touché" do
      {_pixels, state, ram} = deroule(Heros, 5)
      adresses = Heros.adresses()

      assert Map.get(ram, adresses.x) == @depart_x
      assert Map.get(ram, adresses.y) == @depart_y

      # Et elles y restent : le drapeau « installé » a été levé au premier tour,
      # donc les valeurs de départ ne sont pas reposées à chaque frame — sans
      # quoi aucun jeu ne pourrait bouger.
      {_state, ram} = frames(Heros, state, ram, 10)

      assert Map.get(ram, adresses.x) == @depart_x
      assert Map.get(ram, adresses.y) == @depart_y
    end

    test "l'allocation est celle que le compilateur promet" do
      # Dans l'ordre de déclaration, à partir de la première adresse que le
      # noyau laisse à l'acteur.
      assert Heros.adresses() == %{x: Potion.Noyau.etat(), y: Potion.Noyau.etat() + 1}

      # Le drapeau vient après, et le jeu ne le voit pas : il n'est pas dans
      # `adresses/0`, mais il est bien à 0xC102 et il est levé.
      {_pixels, _state, ram} = deroule(Heros, 5)
      assert Map.get(ram, Potion.Noyau.etat() + 2) == 0x01
    end
  end

  describe "le programme engendré" do
    test "il est inspectable, et le noyau y a nommé l'acteur" do
      programme = Heros.programme()

      assert is_list(programme)
      assert {:etiquette, :acteur} in programme

      adresses = Assembleur.adresses(programme, origine: 0x0150)

      assert adresses.init == 0x0150
      assert Map.has_key?(adresses, :acteur)
      assert adresses.acteur > adresses.boucle

      # Les étiquettes du compilateur, toutes préfixées : une par `si`, plus
      # celle de l'installation.
      assert Map.has_key?(adresses, :potion_installe)

      for n <- 0..3, do: assert(Map.has_key?(adresses, :"potion_fin_#{n}"))

      # Et le fragment finit par le RET que le noyau exige.
      assert List.last(programme) == {:ret}
    end

    test "la ROM fait 32 Ko et porte le nom du module" do
      rom = Heros.rom()

      assert byte_size(rom) == 0x8000
      assert binary_part(rom, 0x134, 5) == "HEROS"
    end
  end

  describe "un littéral et une variable dans le même sprite" do
    test "les deux entrées d'OAM portent ce que le jeu a écrit" do
      {_pixels, state, ram} = deroule(Melange, 5)
      adresses = Melange.adresses()

      # `largeur = 5` est une affectation sèche : elle écrase la valeur
      # initiale, à chaque frame.
      assert Map.get(ram, adresses.largeur) == 5
      assert Map.get(ram, adresses.hauteur) == 20

      # L'entrée 1 : x par variable, y et tuile par littéraux. Les décalages du
      # matériel sont là, calculés à la compilation pour les littéraux et à
      # l'exécution pour les variables.
      assert oam(ram, 1) == [40 + 16, 5 + 8, 3, 0]
      # L'entrée 2 : l'inverse — x littéral, y par variable.
      assert oam(ram, 2) == [20 + 16, 100 + 8, 0, 0]
      # Et l'entrée 0, que ce jeu n'écrit pas, est restée le zéro de l'init.
      assert oam(ram, 0) == [0, 0, 0, 0]

      # Un bloc `si` à deux énoncés : les deux passent, ou aucun.
      {_state, ram} = frames(Melange, state, Joypad.set(ram, @relache, @relache - 0x01), 3)

      assert Map.get(ram, adresses.largeur) == 6
      assert Map.get(ram, adresses.hauteur) == 20 + 6
    end
  end

  # ══ Les refus, à la compilation ══════════════════════════════════════════════

  describe "ce que le v0 refuse de compiler" do
    test "une expression hors du sous-ensemble" do
      message = refuse!("Refus.Multiplication", "variables x: 1", "x = x * 2")

      assert message =~ "hors du sous-ensemble du v0"
      assert message =~ "x * 2"
      assert message =~ "x = x + 1"
    end

    test "une addition de deux variables — le v0 n'a pas de politique de registres" do
      message = refuse!("Refus.DeuxVariables", "variables x: 1, y: 2", "x = x + y")

      assert message =~ "hors du sous-ensemble du v0"
      assert message =~ "littéral entier de 0 à 255"
    end

    test "une touche inconnue" do
      message =
        refuse!("Refus.Touche", "variables x: 1", "si appuye?(:turbo), do: x = x + 1")

      assert message =~ "touche inconnue : :turbo"
      assert message =~ ":select"
    end

    test "une variable non déclarée" do
      message = refuse!("Refus.Fantome", "variables x: 1", "y = y + 1")

      assert message =~ "variable non déclarée : :y"
      assert message =~ "Déclarées : :x (0xC100)"
      assert message =~ "variables y: 0"
    end

    test "une variable non déclarée dans un sprite" do
      message =
        refuse!("Refus.SpriteFantome", "variables x: 1", "sprite(0, x: x, y: z, tuile: 0)")

      assert message =~ "variable non déclarée : :z"
    end

    test "deux acteurs dans le même module" do
      source = """
      defmodule Refus.DeuxActeurs do
        use Potion

        defacteur :premier do
          chaque_frame do
            sprite(0, x: 10, y: 10, tuile: 0)
          end
        end

        defacteur :second do
          chaque_frame do
            sprite(1, x: 20, y: 20, tuile: 0)
          end
        end
      end
      """

      message = compile_refusee!(source)

      assert message =~ "second acteur"
      assert message =~ ":second"
      assert message =~ "n'a qu'un slot"
    end

    test "un numéro de sprite hors des quarante entrées de l'OAM" do
      message = refuse!("Refus.Oam", "variables x: 1", "sprite(40, x: x, y: 10, tuile: 0)")

      assert message =~ "entrée d'OAM hors plage : 40"
      assert message =~ "0 à 39"
    end

    test "un numéro de sprite qui n'est pas un littéral" do
      message =
        refuse!("Refus.OamVariable", "variables n: 1", "sprite(n, x: 10, y: 10, tuile: 0)")

      assert message =~ "n'est pas un littéral"
    end

    test "un `si` avec une branche que le v0 ne compile pas" do
      message =
        refuse!(
          "Refus.Sinon",
          "variables x: 1",
          "si appuye?(:a), do: x = x + 1, sinon: x = x - 1"
        )

      assert message =~ "branche que le v0 ne compile pas"
      assert message =~ "sinon"
    end

    test "un acteur sans chaque_frame" do
      source = """
      defmodule Refus.SansFrame do
        use Potion

        defacteur :inerte do
          variables x: 1
        end
      end
      """

      assert compile_refusee!(source) =~ "acteur sans `chaque_frame`"
    end

    test "une valeur initiale qui ne tient pas dans un octet" do
      message = refuse!("Refus.Trop", "variables x: 300", "x = x + 1")

      assert message =~ "valeur initiale hors d'un octet"
    end

    test "un énoncé inconnu dans le corps de l'acteur" do
      source = """
      defmodule Refus.Enonce do
        use Potion

        defacteur :bavard do
          IO.puts("bonjour")

          chaque_frame do
            sprite(0, x: 10, y: 10, tuile: 0)
          end
        end
      end
      """

      assert compile_refusee!(source) =~ "énoncé inconnu"
    end

    test "`variables` employé hors d'un defacteur" do
      source = """
      defmodule Refus.Egare do
        use Potion
        variables x: 1
      end
      """

      assert compile_refusee!(source) =~ "hors d'un `defacteur`"
    end
  end

  # ══ Le harnais ═══════════════════════════════════════════════════════════════

  # `nombre` frames depuis le boot ; la dernière rendue si demandé.
  defp deroule(jeu, nombre, opts \\ []) do
    rom = jeu.rom()
    render? = Keyword.get(opts, :render, false)

    Enum.reduce(1..nombre, {<<>>, Screen.boot_state(rom), Screen.boot_ram(rom)}, fn n,
                                                                                    {_pixels,
                                                                                     state,
                                                                                     ram} ->
      Screen.frame(state, rom, ram, render? and n == nombre)
    end)
  end

  # Des frames de plus, depuis un état en vol et une RAM que le monde extérieur
  # vient éventuellement de toucher.
  defp frames(jeu, state, ram, nombre) do
    rom = jeu.rom()

    Enum.reduce(1..nombre, {state, ram}, fn _n, {state, ram} ->
      {_pixels, state, ram} = Screen.frame(state, rom, ram, false)
      {state, ram}
    end)
  end

  defp position(ram, adresses), do: {Map.get(ram, adresses.x), Map.get(ram, adresses.y)}

  defp oam(ram, entree), do: for(i <- 0..3, do: Map.get(ram, 0xFE00 + 4 * entree + i))

  defp non_blancs(pixels) do
    for i <- 0..(byte_size(pixels) - 1),
        :binary.at(pixels, i) != 0,
        into: MapSet.new(),
        do: {rem(i, 160), div(i, 160)}
  end

  defp boite(x, y) do
    for ligne <- y..(y + 7), colonne <- x..(x + 7), into: MapSet.new(), do: {colonne, ligne}
  end

  # ── Compiler un jeu pour de vrai, et attendre qu'il soit refusé ─────────────

  # Le refus se joue à la compilation du module hôte : ces tests compilent donc
  # du texte, comme `mix compile` le ferait. Un appel direct à `Potion.Compilo`
  # testerait la même exception, mais pas le chemin par lequel un programmeur la
  # rencontre — et c'est ce chemin qui est la promesse du langage.
  defp refuse!(module, declarations, enonce) do
    compile_refusee!("""
    defmodule #{module} do
      use Potion

      defacteur :fautif do
        #{declarations}

        chaque_frame do
          #{enonce}
        end
      end
    end
    """)
  end

  defp compile_refusee!(source) do
    erreur =
      assert_raise Potion.ErreurCompilation, fn ->
        ExUnit.CaptureIO.capture_io(:stderr, fn -> Code.compile_string(source) end)
      end

    erreur.message
  end
end
