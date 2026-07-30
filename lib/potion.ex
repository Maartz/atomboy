defmodule Potion.ErreurCompilation do
  @moduledoc """
  Ce que le v0 ne sait pas compiler, dit à la compilation du module hôte.

  Cette exception est levée pendant l'expansion des macros de `Potion` —
  c'est-à-dire pendant que `mix compile` lit le fichier du jeu. Un jeu qui
  compile est donc un jeu dont chaque ligne a un équivalent en instructions
  SM83 ; il n'existe pas de « Potion qui plante à l'exécution » pour cette
  classe de fautes, parce qu'à l'exécution il n'y a plus qu'une cartouche.
  """

  defexception [:message]
end

defmodule Potion do
  @moduledoc """
  Un langage de jeu qui compile en cartouche.

  Potion est de l'Elixir. On écrit un module, on l'ajoute au projet, `mix
  compile` le lit — et il en sort 32 Ko d'octets qu'une Game Boy exécute :

      defmodule MonJeu do
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

      MonJeu.rom()        # la ROM, binaire, 32 768 octets
      MonJeu.programme()  # le programme assembleur, pour le lire
      MonJeu.adresses()   # où vivent x et y en WRAM

  Ces onze lignes font un carré noir au milieu de l'écran, qui se déplace au
  pouce. Elles ne font rien d'autre — et c'est tout l'objet du v0 : que la
  chaîne entière tienne debout, de la macro à l'OAM, avant de grossir.

  ## La surface est de l'Elixir, la sémantique est celle de la console

  C'est le seul contrat du langage, et il faut le prendre au mot. `x = x + 1`
  s'écrit comme en Elixir, se lit comme en Elixir, et ne veut pas dire la même
  chose :

    * `x` n'est pas une liaison, c'est **une cellule de WRAM**. Le compilateur
      lui donne une adresse dans la page que le noyau réserve à l'acteur, et
      `x = x + 1` compile en `LD A, (x)` / `ADD A, 1` / `LD (x), A`.
    * l'arithmétique est **sur huit bits, et elle enroule**. 255 + 1 fait 0, et
      aucun test ne le rattrape : il n'y a pas de place dans une frame pour
      vérifier ce que le silicium fait déjà.
    * une affectation est **un effet**, pas une nouvelle valeur. Deux `x = …`
      dans une frame écrivent deux fois la même cellule, et la seconde gagne.

  Rien de tout cela n'est un compromis regrettable. C'est ce qu'un jeu Game Boy
  *est*, et un langage qui prétendrait le contraire mentirait sur la machine
  qu'il pilote — au prix, tôt ou tard, d'une frame perdue à émuler une sémantique
  qui n'a pas cours.

  Ce qui ne se traduit pas se refuse, et se refuse **à la compilation** : `x = x
  * 2` fait échouer `mix compile` avec une `Potion.ErreurCompilation` qui montre
  l'AST rejeté et énumère ce que le v0 sait faire. Une ROM qui compile est une
  ROM dont chaque ligne existe en SM83.

  ## La filiation

  L'idée n'est pas neuve, et son précédent est glorieux : GOOL, le langage que
  Andy Gavin a écrit pour *Crash Bandicoot* — un Lisp compilé vers du bytecode
  pour la PlayStation, où chaque personnage était un acteur avec son état et son
  code de frame. Naughty Dog n'a pas écrit un moteur avec des scripts par-dessus
  ; ils ont écrit un langage dont les phrases *sont* le jeu, et un compilateur
  qui les fait tenir dans la console.

  Potion reprend la forme — l'acteur, l'état nommé, le code appelé une fois par
  frame — sur une machine cinquante fois plus petite, et depuis un hôte qui sait
  déjà lire des arbres : les macros d'Elixir font le travail que Gavin faisait
  avec les macros de son Lisp.

  ## L'acteur

  Un `defacteur` déclare trois choses, dont deux sont facultatives :

      defacteur :heros do
        variables x: 80, y: 72     # les cellules de WRAM, et leurs valeurs de départ
        chaque_frame do            # le code appelé une fois par frame, par le noyau
          …
        end
      end

  Les valeurs initiales ne sont pas posées « au démarrage » : un acteur n'a pas
  de démarrage, le noyau l'appelle une fois par frame et c'est tout. Le
  compilateur alloue donc une cellule de plus — le drapeau « installé », que le
  jeu ne déclare pas et ne voit jamais — et fait reconnaître à la première frame
  qu'elle est la première. `Potion.Compilo` détaille ce pattern.

  Le v0 n'accepte **qu'un acteur par module** : l'ordonnanceur du noyau n'a
  qu'un slot, et un second `defacteur` compilerait un jeu dont la moitié ne
  tournerait jamais. Le jour où l'ordonnanceur en aura plusieurs, la macro les
  acceptera sans que la surface change.

  ## Ce que le v0 compile

      x = 5                              une constante dans une cellule
      x = y                              une cellule dans une autre
      x = x + 1                          huit bits, qui enroulent
      x = y - 3

      si appuye?(touche), do: …          :droite :gauche :haut :bas :a :b :select :start
      si appuye?(:a) do                  un bloc, plusieurs énoncés
        x = x + 1
        y = y - 1
      end

      sprite(n, x: …, y: …, tuile: …)    l'entrée n de l'OAM miroir, n littéral de 0 à 39

  `sprite` écrit dans l'OAM miroir du noyau — jamais dans l'OAM réelle, qui
  n'est écrivable que pendant le vblank. Les décalages du matériel (Y+16, X+8)
  sont ajoutés par le compilateur : `sprite(0, x: 80, y: 72, …)` place le coin
  haut-gauche du sprite au pixel (80, 72) de l'écran, et non seize lignes plus
  bas. Les attributs sont mis à zéro.

  ## Les modules

    * `Potion.Compilo` — l'AST restreint vers le fragment assembleur, et tous
      les messages de refus.
    * `Potion.Noyau` — le runtime : l'init, le vblank, le DMA, le pad, la
      boucle qui appelle l'acteur.
    * `Potion.Assembleur` — les tuples vers les octets.
    * `Potion.ROM` — la cartouche de 32 Ko, en-tête et sommes comprises.
  """

  alias Potion.Assembleur
  alias Potion.Compilo
  alias Potion.ErreurCompilation
  alias Potion.Noyau

  # Quinze caractères, c'est ce que l'en-tête de cartouche loge.
  @titre_max 15

  @doc """
  Ouvre le langage dans le module hôte : `defacteur` et ses deux mots.
  """
  defmacro __using__(_opts) do
    quote do
      import Potion, only: [defacteur: 2, variables: 1, chaque_frame: 1]
    end
  end

  @doc """
  Déclare l'acteur du module, et lui donne `rom/0`, `programme/0`, `adresses/0`.

  Tout le travail se fait ici, pendant l'expansion : le corps est lu comme un
  arbre, les variables sont allouées, le corps de `chaque_frame` est compilé, et
  le programme complet est assemblé une fois pour vérifier qu'il tient. Ce qui
  survit à tout cela est une liste de tuples gravée dans le module — les
  fonctions engendrées ne compilent plus rien, elles rendent une valeur.
  """
  defmacro defacteur(nom, do: corps) do
    module = __CALLER__.module
    nom = nom!(nom, module)
    unique!(module, nom)

    {declarations, chaque_frame} = decoupe!(corps, nom)
    allocation = Compilo.alloue(declarations)
    fragment = Compilo.compile(chaque_frame, allocation)
    verifie!(fragment, nom)

    Module.put_attribute(module, :potion_acteur, nom)

    quote do
      @doc """
      Le programme assembleur complet — le noyau, puis l'acteur `#{inspect(unquote(nom))}`.

      Au format de `Potion.Assembleur` : une liste de tuples, qu'on peut lire,
      découper, ou passer à `Potion.Assembleur.adresses/2` pour savoir où tout
      est tombé.
      """
      def programme do
        Potion.Noyau.programme(unquote(Macro.escape(fragment)))
      end

      @doc """
      La ROM, 32 768 octets, prête à graver ou à donner à `Atomboy.Screen`.
      """
      def rom do
        Potion.ROM.construit(programme(),
          vblank: :vblank,
          titre: unquote(titre(module))
        )
      end

      @doc """
      Où vivent les variables du jeu, en WRAM.

      Un jeu Potion n'a pas de variables au sens du BEAM : il a des cellules.
      Les voici, pour qui veut les lire depuis l'extérieur — un émulateur, un
      test, un débogueur.
      """
      def adresses do
        unquote(Macro.escape(allocation.cellules))
      end
    end
  end

  @doc """
  Les cellules de WRAM du jeu et leurs valeurs de départ.

      variables x: 80, y: 72

  Ne s'emploie qu'à l'intérieur d'un `defacteur`, où elle n'est pas exécutée
  mais lue : `defacteur` prend l'arbre tel quel et le passe au compilateur.
  """
  defmacro variables(declarations) do
    hors_acteur!("variables", Macro.to_string({:variables, [], [declarations]}))
  end

  @doc """
  Le code appelé une fois par frame, par la boucle du noyau.

      chaque_frame do
        si appuye?(:droite), do: x = x + 1
        sprite(0, x: x, y: y, tuile: 0)
      end

  Ne s'emploie qu'à l'intérieur d'un `defacteur`. Voir `Potion` pour ce que le
  v0 accepte dedans.
  """
  defmacro chaque_frame(_blocs) do
    hors_acteur!("chaque_frame", "chaque_frame do … end")
  end

  # ══ La lecture de l'arbre de l'acteur ════════════════════════════════════════

  defp nom!(nom, _module) when is_atom(nom), do: nom

  defp nom!(autre, module) do
    raise ErreurCompilation, """
    nom d'acteur qui n'est pas un atome, dans #{inspect(module)} :

        #{Macro.to_string(autre)}

    AST refusé : #{inspect(autre)}

    La forme est `defacteur :heros do … end`. Le nom est écrit sur place, comme \
    celui d'une fonction — il ne se calcule pas.
    """
  end

  defp unique!(module, nom) do
    case Module.get_attribute(module, :potion_acteur) do
      nil ->
        :ok

      premier ->
        raise ErreurCompilation, """
        second acteur dans #{inspect(module)} : #{inspect(nom)}, après #{inspect(premier)}.

        L'ordonnanceur du v0 n'a qu'un slot — le noyau appelle un seul `CALL` par \
        frame, et #{inspect(premier)} l'occupe. #{inspect(nom)} ne tournerait \
        jamais, ce qui est la pire façon de ne pas marcher.

        En attendant un ordonnanceur à plusieurs slots : un acteur par module, et \
        une ROM par module.
        """
    end
  end

  # Le corps d'un `defacteur` : au plus un `variables`, exactement un
  # `chaque_frame`, et rien d'autre. Les deux ne sont pas expansés — ce sont des
  # formes que cette fonction reconnaît, pas du code qui tourne.
  defp decoupe!(corps, nom) do
    corps
    |> enonces()
    |> Enum.reduce({nil, nil}, fn enonce, {declarations, chaque_frame} ->
      case enonce do
        {:variables, _, _} when declarations != nil ->
          doublon!("variables", nom)

        {:chaque_frame, _, _} when chaque_frame != nil ->
          doublon!("chaque_frame", nom)

        {:variables, _, [decl]} ->
          {decl, chaque_frame}

        {:chaque_frame, _, [[do: bloc]]} ->
          {declarations, {:corps, bloc}}

        autre ->
          raise ErreurCompilation, """
          énoncé inconnu dans `defacteur #{inspect(nom)}` :

              #{Macro.to_string(autre)}

          AST refusé : #{inspect(autre)}

          Le corps d'un acteur ne contient que deux formes :

              variables x: 80, y: 72
              chaque_frame do … end

          Le code du jeu va dans `chaque_frame` ; c'est lui que le noyau appelle.
          """
      end
    end)
    |> case do
      {_declarations, nil} ->
        raise ErreurCompilation, """
        acteur sans `chaque_frame` : #{inspect(nom)}

        Un acteur est du code appelé une fois par frame. Sans `chaque_frame`, le \
        noyau appellerait un `RET` soixante fois par seconde et l'écran resterait \
        vide.

            defacteur #{inspect(nom)} do
              chaque_frame do
                sprite(0, x: 80, y: 72, tuile: 0)
              end
            end
        """

      {declarations, {:corps, bloc}} ->
        {declarations || [], bloc}
    end
  end

  defp enonces({:__block__, _, liste}), do: liste
  defp enonces(nil), do: []
  defp enonces(seul), do: [seul]

  defp doublon!(mot, nom) do
    raise ErreurCompilation, """
    `#{mot}` écrit deux fois dans `defacteur #{inspect(nom)}`.

    Un acteur a un seul état et un seul code de frame. Deux `#{mot}` ne diraient \
    pas lequel compte — et le v0 préfère refuser que choisir à votre place.
    """
  end

  # L'assemblage à blanc : le fragment est-il un programme ? Le noyau vérifie le
  # RET final, l'assembleur les étiquettes et les portées de saut. Le faire ici
  # plutôt qu'au premier appel de `rom/0` est tout le bénéfice d'un langage
  # compilé : un `si` dont le bloc dépasse la portée d'un JR se voit dans `mix
  # compile`, pas trois semaines plus tard sur une flashcart.
  defp verifie!(fragment, nom) do
    Assembleur.assemble(Noyau.programme(fragment), origine: 0x0150)
    :ok
  rescue
    erreur in ArgumentError ->
      reraise ErreurCompilation,
              [
                message: """
                l'acteur #{inspect(nom)} ne s'assemble pas.

                #{erreur.message}

                Le corps a été compilé, mais le fragment qui en sort n'est pas un \
                programme valide. Si le message parle d'un saut hors de portée, \
                c'est un bloc `si` trop gros : JR ne saute qu'à 127 octets, et le \
                v0 ne connaît que JR.
                """
              ],
              __STACKTRACE__
  end

  defp titre(module) do
    module
    |> Module.split()
    |> List.last()
    |> String.upcase()
    |> String.slice(0, @titre_max)
  end

  defp hors_acteur!(mot, forme) do
    raise ErreurCompilation, """
    `#{mot}` employé hors d'un `defacteur`.

    Cette forme n'est pas du code : c'est une partie de la déclaration d'un \
    acteur, que `defacteur` lit dans son arbre. Elle n'a de sens qu'ici :

        defacteur :heros do
          #{forme}
        end
    """
  end
end
