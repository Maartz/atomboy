defmodule Potion.Compilo do
  @moduledoc """
  Le compilateur du v0 : d'un AST Elixir restreint à un fragment SM83.

  Ce module ne connaît aucune macro. Il reçoit l'AST que `Potion` a capturé,
  une allocation de cellules, et rend une liste d'éléments au format de
  `Potion.Assembleur`. C'est donc un compilateur qu'on peut appeler à la main,
  dans une console, sur un morceau de `quote` — et c'est voulu : un compilateur
  qui ne s'atteindrait qu'à travers `defmodule` ne se déboguerait qu'à travers
  `defmodule`.

  ## L'allocation

  Une variable du jeu est **une cellule de WRAM**, pas un registre et pas une
  liaison. Les cellules sont prises dans l'ordre de déclaration à partir de
  `Potion.Noyau.etat()` :

      variables x: 80, y: 72

      0xC100  x
      0xC101  y
      0xC102  le drapeau « installé »

  Le drapeau est la cellule que le jeu ne déclare pas et ne voit jamais. Il
  répond à un problème que le BEAM n'a pas : *où poser les valeurs initiales ?*
  Il n'y a pas de « démarrage » dans un acteur — le noyau l'appelle une fois
  par frame, un point c'est tout. La première frame doit donc se reconnaître
  elle-même, et le seul état sur lequel elle peut compter est le zéro que l'init
  a laissé dans la page. L'acteur lit le drapeau : à zéro, il pose les valeurs
  initiales et lève le drapeau ; ensuite il passe. C'est le pattern de l'acteur
  écrit à la main dans `Potion.NoyauTest`, généré.

  ## L'arithmétique

  Le v0 compile trois formes d'affectation, et rien d'autre :

      x = 5          LD A, 5        / LD (x), A
      x = y          LD A, (y)      / LD (x), A
      x = x + 1      LD A, (x)      / ADD A, 1 / LD (x), A
      x = y - 3      LD A, (y)      / SUB A, 3 / LD (x), A

  Ces quatre lignes disent toute la sémantique : un octet, qui enroule. `x = x
  + 1` sur 255 rend 0, parce que `ADD A, 1` sur 255 rend 0. Aucune vérification
  n'est émise — il n'y a pas de place pour en émettre, et un jeu Game Boy compte
  sur l'enroulement plus souvent qu'il ne s'en méfie.

  Tout le reste est refusé à la compilation du module hôte. `x = x * 2` ne
  compile pas parce que le SM83 n'a pas de multiplication ; `x = x + y` ne
  compile pas parce que l'addition mémoire-à-mémoire demande de sauver A ou
  d'utiliser HL, et que le v0 n'a pas de politique de registres. Le second
  reviendra ; le premier deviendra une boucle d'additions le jour où le langage
  saura en écrire une.

  ## Les étiquettes engendrées

  Toutes préfixées `potion_` et numérotées. Le noyau pose `:acteur` juste avant
  le fragment et n'y touche plus ; ce préfixe garde les deux espaces de noms
  disjoints, ce que l'assembleur vérifierait de toute façon — il refuse une
  étiquette dupliquée.
  """

  alias Potion.Assembleur
  alias Potion.ErreurCompilation
  alias Potion.Noyau

  @typedoc """
  Où vit l'état de l'acteur : une cellule par variable, plus le drapeau.
  """
  @type allocation :: %{
          cellules: %{atom() => non_neg_integer()},
          ordre: [atom()],
          initiales: %{atom() => byte()},
          installe: non_neg_integer()
        }

  # Les bits de la cellule du pad, tels que `Potion.Noyau.lire_pad/0` les range.
  # Cette liste est la seule traduction du langage vers le matériel qui ne soit
  # pas dérivée : le noyau documente les bits, on les nomme.
  @touches [right: 0, left: 1, up: 2, down: 3, a: 4, b: 5, select: 6, start: 7]

  # L'OAM en compte quarante, et le DMA les publie toutes.
  @entrees_oam 40

  # 0xC100-0xC1FF : la page que le noyau laisse à l'acteur.
  @page_etat 0x100

  # ══ L'allocation ═════════════════════════════════════════════════════════════

  @doc """
  Place les variables déclarées en WRAM, dans l'ordre où elles sont écrites.

  Le drapeau « installé » vient juste après la dernière, et c'est pour cela
  qu'il est calculé ici plutôt que posé à une adresse fixe : une adresse fixe
  serait un trou au milieu de la page de l'acteur, et le jour où le langage
  saura allouer autre chose que des octets, ce trou serait à contourner.

      iex> Potion.Compilo.alloue(x: 80, y: 72).cellules
      %{x: 0xC100, y: 0xC101}

      iex> Potion.Compilo.alloue(x: 80, y: 72).installe
      0xC102
  """
  @spec alloue(keyword()) :: allocation()
  def alloue(declarations) do
    liste = declarations!(declarations)
    noms = Keyword.keys(liste)

    doublons!(noms, declarations)
    capacite!(noms, declarations)

    cellules =
      noms
      |> Enum.with_index()
      |> Map.new(fn {nom, rang} -> {nom, Noyau.etat() + rang} end)

    %{
      cellules: cellules,
      ordre: noms,
      initiales: Map.new(liste),
      installe: Noyau.etat() + length(noms)
    }
  end

  defp declarations!(declarations) when is_list(declarations) do
    Enum.each(declarations, fn
      {nom, valeur} when is_atom(nom) and is_integer(valeur) and valeur in 0..255 ->
        :ok

      {nom, valeur} when is_atom(nom) ->
        raise ErreurCompilation, """
        valeur initiale hors d'un octet, dans `variables` : #{inspect(nom)}

            #{Macro.to_string(valeur)}

        AST refusé : #{inspect(valeur)}

        Une variable Potion est une cellule de WRAM : sa valeur initiale est un \
        littéral entier de 0 à 255. Elle est posée telle quelle au premier tour, \
        sans calcul — il n'y a personne pour calculer avant que l'acteur ne \
        tourne.
        """

      autre ->
        raise ErreurCompilation, """
        déclaration mal formée dans `variables` : #{inspect(autre)}

        `variables` attend une liste à mots-clés, chaque nom recevant un octet :

            variables x: 80, y: 72
        """
    end)

    declarations
  end

  defp declarations!(autre) do
    raise ErreurCompilation, """
    `variables` attend une liste à mots-clés, reçu :

        #{Macro.to_string(autre)}

    AST refusé : #{inspect(autre)}

    La forme est `variables x: 80, y: 72` — un nom, un octet, et une cellule de \
    WRAM par nom.
    """
  end

  defp doublons!(noms, declarations) do
    case noms -- Enum.uniq(noms) do
      [] ->
        :ok

      repetes ->
        raise ErreurCompilation, """
        variable déclarée deux fois : #{Enum.map_join(Enum.uniq(repetes), ", ", &inspect/1)}

            #{Macro.to_string(declarations)}

        Chaque nom vaut une cellule de WRAM, et deux déclarations du même nom \
        ne diraient pas laquelle porte la valeur initiale.
        """
    end
  end

  defp capacite!(noms, declarations) do
    if length(noms) + 1 > @page_etat do
      raise ErreurCompilation, """
      trop de variables : #{length(noms)} déclarées, #{@page_etat - 1} au plus.

          #{Macro.to_string(declarations)}

      Le noyau laisse à l'acteur la page 0x#{hexa(Noyau.etat())}-0x#{hexa(Noyau.etat() + @page_etat - 1)}, \
      soit #{@page_etat} cellules dont une pour le drapeau « installé ».
      """
    end
  end

  # ══ La compilation ═══════════════════════════════════════════════════════════

  @doc """
  L'AST du corps de `every_frame` et une allocation, en un fragment d'acteur.

  Le fragment finit par `{:ret}` : c'est un `CALL` qui l'atteint, une fois par
  frame, et `Potion.Noyau.programme/1` refuse un acteur qui ne rendrait pas la
  main.
  """
  @spec compile(Macro.t(), allocation()) :: [Assembleur.element()]
  def compile(corps, allocation) do
    {corps_compile, _compteur} = bloc(corps, allocation, 0)
    installation(allocation) ++ corps_compile ++ [{:ret}]
  end

  # Le premier tour : poser les valeurs initiales, puis ne plus jamais y revenir.
  # Sans variable il n'y a rien à installer, et le drapeau reste une cellule
  # inerte — on n'émet pas six octets pour garder un état dont personne ne veut.
  defp installation(%{ordre: []}), do: []

  defp installation(allocation) do
    [
      {:ld, :a, {:mem, allocation.installe}},
      {:and, :a, :a},
      {:jr, :nz, {:etiquette, :potion_installe}},
      {:ld, :a, 0x01},
      {:ld, {:mem, allocation.installe}, :a}
    ] ++
      Enum.flat_map(allocation.ordre, fn nom ->
        [
          {:ld, :a, allocation.initiales[nom]},
          {:ld, {:mem, allocation.cellules[nom]}, :a}
        ]
      end) ++
      [{:etiquette, :potion_installe}]
  end

  # Un bloc : les énoncés à la file, le compteur d'étiquettes passant de l'un à
  # l'autre. Il ressort du bloc parce que deux `if` frères ne peuvent pas
  # partager une étiquette de fin.
  defp bloc(corps, allocation, compteur) do
    corps
    |> enonces()
    |> Enum.reduce({[], compteur}, fn enonce, {acc, compteur} ->
      {elements, compteur} = enonce(enonce, allocation, compteur)
      {acc ++ elements, compteur}
    end)
  end

  defp enonces({:__block__, _, liste}), do: liste
  defp enonces(nil), do: []
  defp enonces(seul), do: [seul]

  # ── Une affectation ─────────────────────────────────────────────────────────

  defp enonce({:=, _, [cible, expression]} = enonce, allocation, compteur) do
    adresse = cellule!(cible, allocation, enonce)
    {charge(expression, allocation, enonce) ++ [{:ld, {:mem, adresse}, :a}], compteur}
  end

  # ── Une condition sur le pad ────────────────────────────────────────────────

  defp enonce({:if, _, [condition, blocs]} = enonce, allocation, compteur) do
    bit = touche!(condition, enonce)
    corps = corps_du_si!(blocs, enonce)
    fin = :"potion_fin_#{compteur}"
    {interieur, compteur} = bloc(corps, allocation, compteur + 1)

    elements =
      [
        {:ld, :a, {:mem, Noyau.pad()}},
        {:bit, bit, :a},
        {:jr, :z, {:etiquette, fin}}
      ] ++ interieur ++ [{:etiquette, fin}]

    {elements, compteur}
  end

  # ── Une entrée d'OAM ────────────────────────────────────────────────────────

  defp enonce({:sprite, _, [indice, champs]} = enonce, allocation, compteur) do
    base = Noyau.oam_miroir() + 4 * entree!(indice, enonce)
    {x, y, tuile} = champs!(champs, enonce)

    elements =
      champ(y, 16, base, allocation, enonce) ++
        champ(x, 8, base + 1, allocation, enonce) ++
        champ(tuile, 0, base + 2, allocation, enonce) ++
        [{:xor, :a, :a}, {:ld, {:mem, base + 3}, :a}]

    {elements, compteur}
  end

  defp enonce(autre, _allocation, _compteur), do: refus!(autre)

  # Un octet d'OAM : la valeur, décalée du décalage matériel. Sur un littéral le
  # décalage est fait ici — le processeur n'a pas à additionner ce que le
  # compilateur sait déjà. Sur une variable il coûte deux octets, et il enroule
  # comme le reste.
  defp champ(source, decalage, adresse, allocation, enonce) do
    charge = valeur_de_sprite(source, decalage, allocation, enonce)
    charge ++ [{:ld, {:mem, adresse}, :a}]
  end

  defp valeur_de_sprite(litteral, decalage, _allocation, _enonce) when is_integer(litteral) do
    [{:ld, :a, Integer.mod(litteral + decalage, 0x100)}]
  end

  defp valeur_de_sprite({nom, _, contexte}, decalage, allocation, enonce)
       when is_atom(nom) and is_atom(contexte) do
    charge = [{:ld, :a, {:mem, cellule!(nom, allocation, enonce)}}]
    if decalage == 0, do: charge, else: charge ++ [{:add, :a, decalage}]
  end

  defp valeur_de_sprite(autre, _decalage, _allocation, enonce) do
    raise ErreurCompilation, """
    champ de `sprite` hors du sous-ensemble du v0 :

        #{Macro.to_string(autre)}

    AST refusé : #{inspect(autre)}

    Dans #{souligne(enonce)}, `x:`, `y:` et `tile:` prennent une variable \
    déclarée ou un littéral de 0 à 255. Un calcul se fait avant, dans une \
    variable.
    """
  end

  # ── Le côté droit d'une affectation ─────────────────────────────────────────

  defp charge(litteral, _allocation, enonce) when is_integer(litteral) do
    [{:ld, :a, octet!(litteral, enonce)}]
  end

  defp charge({nom, _, contexte}, allocation, enonce) when is_atom(nom) and is_atom(contexte) do
    [{:ld, :a, {:mem, cellule!(nom, allocation, enonce)}}]
  end

  defp charge({operateur, _, [gauche, droite]}, allocation, enonce)
       when operateur in [:+, :-] do
    charge(gauche, allocation, enonce) ++
      [{arithmetique(operateur), :a, octet!(droite, enonce)}]
  end

  defp charge(autre, _allocation, _enonce), do: refus!(autre)

  defp arithmetique(:+), do: :add
  defp arithmetique(:-), do: :sub

  # Le terme de droite d'un `+` ou d'un `-` : un littéral, jamais une variable.
  # Une addition mémoire-à-mémoire demanderait de garder un opérande quelque
  # part pendant qu'on charge l'autre, donc une politique de registres, donc un
  # compilateur d'un autre calibre.
  defp octet!(valeur, _enonce) when is_integer(valeur) and valeur in 0..255, do: valeur

  defp octet!(autre, enonce) do
    raise ErreurCompilation, """
    opérande hors du sous-ensemble du v0 :

        #{Macro.to_string(autre)}

    AST refusé : #{inspect(autre)}

    Dans #{souligne(enonce)}, seul un littéral entier de 0 à 255 est accepté à \
    cette place. Le v0 compile `x = 5`, `x = y`, `x = x + 1` et `x = y - 3` — \
    une variable, un signe, une constante.
    """
  end

  # ── La cellule d'une variable ───────────────────────────────────────────────

  defp cellule!({nom, _, contexte}, allocation, enonce)
       when is_atom(nom) and is_atom(contexte) do
    cellule!(nom, allocation, enonce)
  end

  defp cellule!(nom, allocation, enonce) when is_atom(nom) do
    case allocation.cellules do
      %{^nom => adresse} ->
        adresse

      _ ->
        raise ErreurCompilation, """
        variable non déclarée : #{inspect(nom)}, dans #{souligne(enonce)}

        #{declarees(allocation)}

        Une variable Potion n'apparaît pas en s'écrivant : elle est une cellule \
        de WRAM, et c'est `variables` qui décide où. Ajoutez-la :

            variables #{nom}: 0
        """
    end
  end

  defp cellule!(autre, _allocation, enonce) do
    raise ErreurCompilation, """
    cible d'affectation qui n'est pas une variable :

        #{Macro.to_string(autre)}

    AST refusé : #{inspect(autre)}

    Dans #{souligne(enonce)}, le côté gauche d'un `=` doit être le nom d'une \
    variable déclarée par `variables`. Le v0 n'a ni filtrage, ni structure, ni \
    liaison — un `=` est une écriture dans une cellule.
    """
  end

  defp declarees(%{ordre: []}), do: "Ce jeu ne déclare aucune variable."

  defp declarees(%{ordre: noms, cellules: cellules}) do
    "Déclarées : " <>
      Enum.map_join(noms, ", ", fn nom -> "#{inspect(nom)} (0x#{hexa(cellules[nom])})" end)
  end

  # ── La touche d'un `if` ─────────────────────────────────────────────────────

  defp touche!({:pressed?, _, [touche]}, enonce) when is_atom(touche) do
    case Keyword.fetch(@touches, touche) do
      {:ok, bit} ->
        bit

      :error ->
        raise ErreurCompilation, """
        touche inconnue : #{inspect(touche)}, dans #{souligne(enonce)}

        Le pad d'une Game Boy en a huit, et le noyau les range dans un octet :
        #{Enum.map_join(@touches, "\n", fn {nom, bit} -> "  #{inspect(nom)} — bit #{bit}" end)}
        """
    end
  end

  defp touche!(condition, enonce) do
    raise ErreurCompilation, """
    condition hors du sous-ensemble du v0 :

        #{Macro.to_string(condition)}

    AST refusé : #{inspect(condition)}

    Dans #{souligne(enonce)}, `if` ne teste qu'une touche du pad, sous la forme \
    `if pressed?(:right), do: ...`. Le v0 n'a pas de comparaison ; le pad est le \
    seul monde extérieur qu'un acteur puisse interroger.
    """
  end

  defp corps_du_si!(blocs, enonce) do
    case blocs do
      [do: corps] ->
        corps

      autres when is_list(autres) ->
        raise ErreurCompilation, """
        branche que le v0 ne compile pas : \
        #{Enum.map_join(Keyword.keys(autres) -- [:do], ", ", &inspect/1)}

            #{souligne(enonce)}

        Un `if` du v0 n'a qu'un `do:` — pas de `else:`. Le contraire \
        s'écrit avec un second `if` sur une autre touche, en attendant que le \
        langage sache sauter par-dessus deux blocs.
        """

      autre ->
        raise ErreurCompilation, """
        `if` mal formé :

            #{Macro.to_string(autre)}

        AST refusé : #{inspect(autre)}

        La forme est `if pressed?(:right), do: x = x + 1`, ou la même avec un \
        bloc `do ... end`.
        """
    end
  end

  # ── L'entrée d'OAM et ses champs ────────────────────────────────────────────

  defp entree!(indice, _enonce) when is_integer(indice) and indice in 0..(@entrees_oam - 1)//1 do
    indice
  end

  defp entree!(indice, enonce) when is_integer(indice) do
    raise ErreurCompilation, """
    entrée d'OAM hors plage : #{indice}, dans #{souligne(enonce)}

    L'OAM d'une Game Boy compte #{@entrees_oam} entrées, numérotées de 0 à \
    #{@entrees_oam - 1} — quatre octets chacune, de \
    0x#{hexa(Noyau.oam_miroir())} à \
    0x#{hexa(Noyau.oam_miroir() + 4 * @entrees_oam - 1)} dans le miroir du noyau.

    L'entrée #{indice} tomberait hors de cette plage, et le DMA ne la publierait \
    donc jamais : elle écraserait les cellules du noyau — la cellule du pad est \
    à 0x#{hexa(Noyau.pad())} — ou l'état de l'acteur.
    """
  end

  defp entree!(autre, enonce) do
    raise ErreurCompilation, """
    numéro de sprite qui n'est pas un littéral :

        #{Macro.to_string(autre)}

    AST refusé : #{inspect(autre)}

    Dans #{souligne(enonce)}, le premier argument de `sprite` doit être un \
    entier écrit sur place, de 0 à #{@entrees_oam - 1} : c'est lui qui donne \
    l'adresse de l'entrée dans le miroir, et cette adresse est décidée à la \
    compilation. Un sprite choisi à l'exécution demanderait une indexation que \
    le v0 n'a pas.
    """
  end

  @champs [:x, :y, :tile]

  defp champs!(champs, enonce) when is_list(champs) do
    with true <- Keyword.keyword?(champs),
         [] <- Enum.sort(Keyword.keys(champs)) -- Enum.sort(@champs),
         [] <- Enum.sort(@champs) -- Enum.sort(Keyword.keys(champs)),
         [] <- Keyword.keys(champs) -- Enum.uniq(Keyword.keys(champs)) do
      {champs[:x], champs[:y], champs[:tile]}
    else
      _ -> champs_refuses!(champs, enonce)
    end
  end

  defp champs!(champs, enonce), do: champs_refuses!(champs, enonce)

  defp champs_refuses!(champs, enonce) do
    raise ErreurCompilation, """
    champs de `sprite` mal formés :

        #{Macro.to_string(champs)}

    AST refusé : #{inspect(champs)}

    Dans #{souligne(enonce)}, `sprite` attend exactement `x:`, `y:` et `tile:` \
    — chacun une fois. Les attributs sont mis à zéro par le compilateur : le v0 \
    n'a qu'une palette d'objets, et ni miroir ni priorité.
    """
  end

  # ── Le refus général ────────────────────────────────────────────────────────

  defp refus!(enonce) do
    raise ErreurCompilation, """
    énoncé hors du sous-ensemble du v0 :

        #{Macro.to_string(enonce)}

    AST refusé : #{inspect(enonce)}

    Dans `every_frame`, le v0 compile exactement ceci :

        x = 5              une constante dans une cellule
        x = y              une cellule dans une autre
        x = x + 1          arithmétique 8 bits qui enroule
        x = y - 3          la même, dans l'autre sens

        if pressed?(:right), do: x = x + 1
        if pressed?(:a) do
          x = x + 1
          y = y - 1
        end

        sprite(0, x: x, y: y, tile: 0)

    La surface est de l'Elixir ; la sémantique est celle de la console. Ce qui \
    ne se traduit pas en quelques instructions SM83 ne se compile pas — pas \
    encore.
    """
  end

  # L'énoncé fautif, ramené à une ligne : dans un `if` déplié sur cinq lignes,
  # le message tiendrait la moitié de l'écran.
  defp souligne(enonce) do
    enonce
    |> Macro.to_string()
    |> String.split("\n")
    |> case do
      [seul] -> "`#{seul}`"
      [premiere | _] -> "`#{premiere} …`"
    end
  end

  defp hexa(valeur), do: valeur |> Integer.to_string(16) |> String.pad_leading(4, "0")
end
