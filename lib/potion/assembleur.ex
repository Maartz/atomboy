defmodule Potion.Assembleur do
  @moduledoc """
  La table d'instructions du SM83, lue à l'envers.

  ## Pourquoi il n'y a aucun encodage dans ce fichier

  `Atomboy.CPU.Table` décrit les 500 instructions du processeur : pour chacune,
  son opcode, son préfixe et la forme de ses opérandes. Le décodeur en dérive des
  clauses de fonction ; cet assembleur en dérive un **index inversé** — de
  `{mnémonique, condition, forme des opérandes}` vers `{préfixe, opcode}`.

  C'est le seul choix qui garantisse ce dont Potion a besoin. Un assembleur qui
  recopierait les encodages à la main serait une seconde table, à maintenir en
  accord avec la première ; et la divergence ne se manifesterait pas par une
  erreur de compilation mais par une ROM qui *tourne* en faisant autre chose que
  ce qui est écrit. En dérivant, l'accord est structurel : toute instruction
  décodable est assemblable, avec les mêmes octets, et le test aller-retour le
  vérifie sur les 500.

  La clé de l'index *est* la liste des gabarits d'opérandes — il n'y a pas de
  normalisation intermédiaire. Ce qui reste à faire, et c'est tout le travail de
  ce module, est de passer de la syntaxe source (`{:ld, :a, {:mem, :hl}}`, écrite
  pour la main humaine) à cette forme-là (`[{:reg, :a}, :hl_ind]`, écrite pour le
  silicium).

  ## Deux passes, et pourquoi elles suffisent

  Sur SM83 aucune taille d'instruction ne dépend d'une distance : un opcode, plus
  éventuellement l'octet de préfixe, plus ses immédiats, tous de largeur fixe.
  Chaque élément connaît donc sa taille avant qu'aucune adresse ne soit résolue.

  La passe 1 parcourt le programme en sommant les tailles et note où tombe chaque
  étiquette ; la passe 2 repasse et émet les octets, les cibles étant désormais
  connues. Sans cette propriété il faudrait un point fixe — un branchement
  lointain occupe plus de place, ce qui éloigne les cibles suivantes, ce qui
  allonge d'autres branchements. Le SM83 nous l'épargne.

  L'invariant qui verrouille les deux passes — *le nombre d'octets émis en passe
  2 est exactement la taille annoncée en passe 1* — est vérifié à chaque
  assemblage, pas seulement dans les tests : une ROM d'une longueur inattendue
  s'exécute quand même, et donne de mauvais résultats.

  ## Le format source

  Un programme est une liste. Trois sortes d'éléments :

      {:etiquette, :boucle}      taille nulle ; nomme l'adresse courante
      {:octets, <<1, 2, 3>>}     des octets bruts — données, tuiles
      {:ld, :a, {:mem, :hl}}     une instruction

  Une instruction est un tuple dont la tête est le mnémonique **exactement** tel
  que la table le nomme (`:ld`, `:ldh`, `:add_sp`, `:jr`, `:rst`, `:bit`…). Pour
  les formes conditionnelles la condition s'insère en premier : `{:jr, :nz,
  {:etiquette, :fin}}`, `{:ret, :c}`.

  Les opérandes :

      :a … :l                  un registre 8 bits
      :bc :de :hl :sp :af      une paire 16 bits
      0x12 / 0x1234            un immédiat, largeur déduite de la table
      {:mem, :hl}              l'octet à l'adresse HL
      {:mem, :bc | :de | :hl_inc | :hl_dec}
      {:mem, 0xC000}           l'octet à une adresse absolue
      {:mem, {:etiquette, :n}} idem, l'adresse venant d'une étiquette
      {:haut, 0x44}            la page haute : 0xFF00 + 0x44
      {:haut, :c}              la page haute via C
      {:etiquette, :n}         la cible d'un saut ou d'un appel

  L'accumulateur est **explicite** dans les opérations arithmétiques, comme dans
  la table : `{:add, :a, :b}`, `{:sub, :a, 0x10}`, `{:cp, :a, {:mem, :hl}}`. La
  table décrit A parce que le processeur le lit et l'écrit ; l'assembleur
  classique l'omet (`SUB B`), et c'est l'assembleur classique qui est irrégulier.

  ## Ce que l'assembleur déduit, et ce qu'il exige

  La largeur d'un immédiat n'est jamais écrite : `{:ld, :a, 0x12}` est un octet,
  `{:ld, :hl, 0x1234}` un mot, parce que la table ne connaît qu'une forme dans
  chaque cas. C'est l'index qui tranche, et il ne peut pas se tromper — s'il
  existait deux formes concurrentes pour un même mnémonique, le test aller-retour
  échouerait.

  En revanche la valeur est vérifiée : hors plage, l'assemblage s'arrête. Une
  troncature silencieuse produirait une ROM plausible et fausse, ce qui coûte
  bien plus cher qu'un message d'erreur.
  """

  import Bitwise

  alias Atomboy.CPU.Insn
  alias Atomboy.CPU.Table

  @typedoc """
  Un opérande source, dans la syntaxe lisible par la main humaine.
  """
  @type operande ::
          atom()
          | integer()
          | {:mem, atom() | non_neg_integer() | {:etiquette, atom()}}
          | {:haut, :c | non_neg_integer() | {:etiquette, atom()}}
          | {:etiquette, atom()}

  @typedoc """
  Un élément de programme : une étiquette, des octets bruts, ou une instruction.
  """
  @type element :: {:etiquette, atom()} | {:octets, binary()} | tuple()

  # 0x0150 : la première adresse libre après l'en-tête de cartouche. C'est là que
  # le point d'entrée saute, et donc l'origine par défaut d'un programme Potion.
  @origine_defaut 0x0150

  # L'index inversé, construit à la compilation depuis la table. Clé : la forme
  # de l'instruction telle que la table la décrit. Valeur : de quoi l'écrire.
  # Les gabarits d'opérandes ne sont pas stockés en valeur — ils sont déjà dans
  # la clé, et deux copies d'une même vérité sont une de trop.
  @index (for %Insn{} = insn <- Table.all(), into: %{} do
            {{insn.mnemonic, insn.condition, insn.operands}, {insn.prefix, insn.opcode}}
          end)

  # Si deux instructions partageaient une clé, `into: %{}` en perdrait une
  # silencieusement et l'encodage correspondant deviendrait inatteignable. Le
  # jour où la table gagne une famille, c'est ici que ça casse — à la
  # compilation, pas dans une ROM.
  if map_size(@index) != length(Table.all()) do
    raise "index inversé dégénéré : #{length(Table.all())} instructions pour " <>
            "#{map_size(@index)} clés {mnémonique, condition, opérandes}"
  end

  @mnemoniques Table.all() |> Enum.map(& &1.mnemonic) |> Enum.uniq() |> Enum.sort()

  # Les deux seuls mnémoniques dont l'immédiat 8 bits est signé : JR compte une
  # distance, ADD SP un déplacement de pile. Partout ailleurs un octet est un
  # octet.
  @relatifs [:jr, :add_sp]

  @doc """
  Assemble un programme en octets.

  `opts[:origine]` est l'adresse de la première instruction — nécessaire pour
  résoudre les étiquettes, qui nomment des adresses absolues et non des
  décalages. Par défaut 0x0150.

      iex> Potion.Assembleur.assemble([{:ld, :a, 0x05}, {:add, :a, :b}])
      <<0x3E, 0x05, 0x80>>
  """
  @spec assemble([element()], keyword()) :: binary()
  def assemble(programme, opts \\ []) do
    origine = Keyword.get(opts, :origine, @origine_defaut)
    {plan, etiquettes, taille} = mesurer(programme, origine)
    octets = plan |> Enum.map(&emettre(&1, etiquettes)) |> IO.iodata_to_binary()

    if byte_size(octets) != taille do
      raise "assemblage incohérent : la passe 1 annonce #{taille} octets, " <>
              "la passe 2 en a émis #{byte_size(octets)}"
    end

    octets
  end

  @doc """
  Les adresses des étiquettes d'un programme, sans émettre les octets.

  La passe 1 les calcule de toute façon ; les exposer évite à l'appelant de
  compter les instructions à la main pour savoir où son point d'entrée est
  tombé. C'est ce dont le noyau aura besoin pour écrire l'en-tête de cartouche.
  """
  @spec adresses([element()], keyword()) :: %{atom() => non_neg_integer()}
  def adresses(programme, opts \\ []) do
    origine = Keyword.get(opts, :origine, @origine_defaut)
    {_plan, etiquettes, _taille} = mesurer(programme, origine)
    etiquettes
  end

  # ══ Passe 1 : les tailles et les étiquettes ══════════════════════════════════

  defp mesurer(programme, origine) do
    {plan, etiquettes, adresse} =
      programme
      |> Enum.with_index()
      |> Enum.reduce({[], %{}, origine}, &mesurer_element/2)

    {Enum.reverse(plan), etiquettes, adresse - origine}
  end

  defp mesurer_element({{:etiquette, nom}, indice}, {plan, etiquettes, adresse})
       when is_atom(nom) do
    case etiquettes do
      %{^nom => precedente} ->
        raise ArgumentError, """
        étiquette dupliquée : #{inspect(nom)}, à l'élément ##{indice}.

        Elle est déjà posée à 0x#{hexa(precedente)} et le serait de nouveau à \
        0x#{hexa(adresse)} — une cible de saut ne peut pas désigner deux adresses.
        """

      _ ->
        {plan, Map.put(etiquettes, nom, adresse), adresse}
    end
  end

  defp mesurer_element({{:octets, octets}, _indice}, {plan, etiquettes, adresse})
       when is_binary(octets) do
    {[{:octets, octets} | plan], etiquettes, adresse + byte_size(octets)}
  end

  defp mesurer_element({{:etiquette, autre}, indice}, _acc) do
    raise ArgumentError,
          "étiquette mal formée à l'élément ##{indice} : le nom doit être un atome, " <>
            "reçu #{inspect(autre)}"
  end

  defp mesurer_element({{:octets, autre}, indice}, _acc) do
    raise ArgumentError,
          "octets mal formés à l'élément ##{indice} : attendu un binaire, " <>
            "reçu #{inspect(autre)}"
  end

  defp mesurer_element({source, indice}, {plan, etiquettes, adresse})
       when is_tuple(source) and tuple_size(source) > 0 do
    insn = preparer(source, indice, adresse)
    {[{:instruction, insn} | plan], etiquettes, adresse + insn.taille}
  end

  defp mesurer_element({autre, indice}, _acc) do
    raise ArgumentError, """
    élément de programme inconnu à l'élément ##{indice} : #{inspect(autre)}

    Un programme est une liste de `{:etiquette, nom}`, `{:octets, binaire}` et \
    d'instructions — ces dernières étant des tuples dont la tête est un mnémonique.
    """
  end

  # ── La résolution d'une instruction ─────────────────────────────────────────

  defp preparer(source, indice, adresse) do
    [mnemonique | arguments] = Tuple.to_list(source)

    unless is_atom(mnemonique) do
      raise ArgumentError, """
      instruction mal formée à l'élément ##{indice} (0x#{hexa(adresse)}) : \
      #{inspect(source)}

      La tête du tuple doit être un mnémonique de la table, pas #{inspect(mnemonique)}.
      """
    end

    {prefixe, opcode, paires} =
      case resoudre(mnemonique, arguments) do
        nil ->
          raise ArgumentError, message_inconnue(source, mnemonique, arguments, indice, adresse)

        trouve ->
          trouve
      end

    immediats = for {gabarit, operande} <- paires, largeur(gabarit) > 0, do: {gabarit, operande}
    corps = Enum.sum(Enum.map(immediats, fn {gabarit, _} -> largeur(gabarit) end))

    %{
      source: source,
      indice: indice,
      adresse: adresse,
      taille: 1 + if(prefixe, do: 1, else: 0) + corps,
      mnemonique: mnemonique,
      prefixe: prefixe,
      opcode: opcode,
      immediats: immediats
    }
  end

  # Un mnémonique et des arguments source ; en sortie l'encodage et l'appariement
  # des opérandes avec les gabarits de la table, ou `nil`.
  #
  # Le procédé est une recherche, pas une traduction : certains opérandes source
  # ont plusieurs formes possibles (un entier peut être un immédiat 8 bits, 16
  # bits, une cible de RST, un numéro de bit) et c'est l'index qui départage. Le
  # produit cartésien reste minuscule — au plus seize combinaisons — et l'unicité
  # des clés fait qu'au plus une aboutit.
  defp resoudre(mnemonique, arguments) do
    Enum.find_value(decoupes(arguments), fn {condition, operandes} ->
      operandes
      |> Enum.map(&formes/1)
      |> produit()
      |> Enum.find_value(fn gabarits ->
        case Map.fetch(@index, {mnemonique, condition, gabarits}) do
          {:ok, {prefixe, opcode}} -> {prefixe, opcode, Enum.zip(gabarits, operandes)}
          :error -> nil
        end
      end)
    end)
  end

  # `:c` est à la fois un registre et une condition — `{:inc, :c}` incrémente C,
  # `{:ret, :c}` retourne si carry. Aucune règle syntaxique ne les distingue,
  # alors on essaie les deux lectures et l'index tranche : une seule des deux
  # correspond à une instruction existante. L'inconditionnelle d'abord, pour que
  # `{:inc, :c}` ne soit jamais lu comme une condition.
  defp decoupes([tete | reste]) when tete in [:nz, :z, :nc, :c] do
    [{nil, [tete | reste]}, {tete, reste}]
  end

  defp decoupes(arguments), do: [{nil, arguments}]

  defp produit([]), do: [[]]

  defp produit([formes | reste]) do
    for forme <- formes, suite <- produit(reste), do: [forme | suite]
  end

  # Les formes de table qu'un opérande source peut prendre. Plusieurs quand la
  # syntaxe est ambiguë, aucune quand l'opérande n'a pas de sens.
  defp formes(registre) when registre in [:a, :b, :c, :d, :e, :h, :l], do: [{:reg, registre}]
  defp formes(paire) when paire in [:bc, :de, :hl, :sp, :af], do: [{:pair, paire}]

  # Un entier : immédiat de l'une des deux largeurs, ou valeur encodée dans
  # l'opcode même (la cible d'un RST, le numéro de bit d'un BIT/RES/SET).
  defp formes(entier) when is_integer(entier) do
    [{:imm, 8}, {:imm, 16}, {:rst, entier}, {:bit, entier}]
  end

  # Une étiquette est une adresse : 16 bits pour JP et CALL, 8 bits signés pour
  # le seul JR — l'index choisit, et `immediat/4` refuse le cas où un 8 bits
  # tomberait ailleurs que dans un saut relatif.
  defp formes({:etiquette, nom}) when is_atom(nom), do: [{:imm, 16}, {:imm, 8}]

  defp formes({:mem, :hl}), do: [:hl_ind]
  defp formes({:mem, paire}) when paire in [:bc, :de, :hl_inc, :hl_dec], do: [{:ind, paire}]
  defp formes({:mem, adresse}) when is_integer(adresse), do: [:a16_ind]
  defp formes({:mem, {:etiquette, nom}}) when is_atom(nom), do: [:a16_ind]
  defp formes({:haut, :c}), do: [:c_ind]
  defp formes({:haut, octet}) when is_integer(octet), do: [:a8_ind]
  defp formes({:haut, {:etiquette, nom}}) when is_atom(nom), do: [:a8_ind]
  defp formes(_autre), do: []

  defp largeur({:imm, 8}), do: 1
  defp largeur({:imm, 16}), do: 2
  defp largeur(:a8_ind), do: 1
  defp largeur(:a16_ind), do: 2
  defp largeur(_encode_dans_l_opcode), do: 0

  # ══ Passe 2 : les octets ═════════════════════════════════════════════════════

  defp emettre({:octets, octets}, _etiquettes), do: octets

  defp emettre({:instruction, insn}, etiquettes) do
    entete =
      case insn.prefixe do
        nil -> <<insn.opcode>>
        :cb -> <<0xCB, insn.opcode>>
      end

    Enum.reduce(insn.immediats, entete, fn {gabarit, operande}, octets ->
      valeur = immediat(gabarit, operande, insn, etiquettes)
      octets <> encoder(gabarit, valeur)
    end)
  end

  defp encoder({:imm, 8}, valeur), do: <<valeur>>
  defp encoder(:a8_ind, valeur), do: <<valeur>>
  defp encoder({:imm, 16}, valeur), do: <<valeur::16-little>>
  defp encoder(:a16_ind, valeur), do: <<valeur::16-little>>

  # ── La valeur d'un immédiat ─────────────────────────────────────────────────

  defp immediat({:imm, 8}, {:etiquette, nom}, insn, etiquettes) do
    cible = resoudre_etiquette!(nom, insn, etiquettes)

    unless insn.mnemonique == :jr do
      raise ArgumentError, """
      étiquette là où #{Atom.to_string(insn.mnemonique) |> String.upcase()} attend \
      un octet, à l'élément ##{insn.indice} (0x#{hexa(insn.adresse)}) : \
      #{inspect(insn.source)}

      Une étiquette ne devient un immédiat 8 bits que pour un saut relatif JR, \
      où elle désigne une distance. Ailleurs, elle ne pourrait tenir dans un \
      octet qu'en perdant la moitié de son adresse.
      """
    end

    # PC est déjà avancé quand le processeur ajoute le déplacement : l'origine du
    # saut est l'adresse *après* l'instruction, pas la sienne.
    apres = insn.adresse + insn.taille
    ecart = cible - apres

    if ecart < -128 or ecart > 127 do
      raise ArgumentError, """
      saut relatif hors de portée à l'élément ##{insn.indice} \
      (0x#{hexa(insn.adresse)}) : #{inspect(insn.source)}

      L'écart est de #{ecart} octets — de 0x#{hexa(apres)} (l'adresse après le JR) \
      vers 0x#{hexa(cible)} (l'étiquette #{inspect(nom)}) — et JR n'encode qu'un \
      déplacement de -128 à 127. Il faut un JP, dont la cible est absolue.
      """
    end

    ecart &&& 0xFF
  end

  defp immediat({:imm, 8}, entier, insn, _etiquettes) when is_integer(entier) do
    # Les deux mnémoniques relatifs acceptent aussi un entier négatif, encodé en
    # complément à deux ; ailleurs l'octet n'est jamais signé.
    if insn.mnemonique in @relatifs do
      plage!(entier, -128, 0xFF, "un octet signé", insn) &&& 0xFF
    else
      plage!(entier, 0, 0xFF, "un octet", insn)
    end
  end

  defp immediat({:imm, 16}, {:etiquette, nom}, insn, etiquettes) do
    nom |> resoudre_etiquette!(insn, etiquettes) |> plage!(0, 0xFFFF, "une adresse", insn)
  end

  defp immediat({:imm, 16}, entier, insn, _etiquettes) when is_integer(entier) do
    plage!(entier, 0, 0xFFFF, "un mot", insn)
  end

  defp immediat(:a16_ind, {:mem, {:etiquette, nom}}, insn, etiquettes) do
    nom |> resoudre_etiquette!(insn, etiquettes) |> plage!(0, 0xFFFF, "une adresse", insn)
  end

  defp immediat(:a16_ind, {:mem, adresse}, insn, _etiquettes) do
    plage!(adresse, 0, 0xFFFF, "une adresse", insn)
  end

  # La page haute n'encode que l'octet bas : 0xFF00 + n. Une étiquette y est
  # acceptée si — et seulement si — elle est tombée dans cette page.
  defp immediat(:a8_ind, {:haut, {:etiquette, nom}}, insn, etiquettes) do
    cible = resoudre_etiquette!(nom, insn, etiquettes)

    if cible < 0xFF00 or cible > 0xFFFF do
      raise ArgumentError, """
      étiquette hors de la page haute à l'élément ##{insn.indice} \
      (0x#{hexa(insn.adresse)}) : #{inspect(insn.source)}

      #{inspect(nom)} est à 0x#{hexa(cible)}, or LDH n'atteint que \
      0xFF00 à 0xFFFF : il n'encode que l'octet bas de l'adresse.
      """
    end

    cible &&& 0xFF
  end

  defp immediat(:a8_ind, {:haut, octet}, insn, _etiquettes) do
    plage!(octet, 0, 0xFF, "un décalage dans la page haute", insn)
  end

  defp resoudre_etiquette!(nom, insn, etiquettes) do
    case etiquettes do
      %{^nom => adresse} ->
        adresse

      _ ->
        connues =
          case Map.keys(etiquettes) do
            [] -> "aucune étiquette n'est définie dans ce programme"
            noms -> "définies : " <> Enum.map_join(Enum.sort(noms), ", ", &inspect/1)
          end

        raise ArgumentError, """
        étiquette inconnue : #{inspect(nom)}, à l'élément ##{insn.indice} \
        (0x#{hexa(insn.adresse)}) — #{connues}.
        """
    end
  end

  defp plage!(valeur, bas, haut, quoi, insn) when is_integer(valeur) do
    if valeur < bas or valeur > haut do
      raise ArgumentError, """
      immédiat hors plage à l'élément ##{insn.indice} (0x#{hexa(insn.adresse)}) : \
      #{inspect(insn.source)}

      #{inspect(valeur)} ne tient pas dans #{quoi} : attendu #{bas}..#{haut}.
      """
    end

    valeur
  end

  defp plage!(valeur, _bas, _haut, quoi, insn) do
    raise ArgumentError, """
    opérande non numérique à l'élément ##{insn.indice} (0x#{hexa(insn.adresse)}) : \
    #{inspect(insn.source)}

    #{inspect(valeur)} devrait être #{quoi}.
    """
  end

  # ══ Les messages d'échec ═════════════════════════════════════════════════════

  defp message_inconnue(source, mnemonique, arguments, indice, adresse) do
    situation = "à l'élément ##{indice} (0x#{hexa(adresse)}) : #{inspect(source)}"
    orphelins = orphelins(arguments)

    cond do
      orphelins != [] ->
        """
        opérande de forme inconnue #{situation}

        #{Enum.map_join(orphelins, "\n", &"  #{inspect(&1)} ne correspond à aucune forme d'opérande.")}

        Les formes reconnues sont : un registre (:a … :l), une paire (:bc, :de, \
        :hl, :sp, :af), un entier, {:mem, …}, {:haut, …} et {:etiquette, nom}.
        """

      mnemonique in @mnemoniques ->
        """
        instruction inconnue #{situation}

        Le mnémonique #{inspect(mnemonique)} existe, mais pas avec ces opérandes.
        #{formes_connues(mnemonique, arguments)}
        """

      true ->
        """
        mnémonique inconnu #{situation}

        #{inspect(mnemonique)} n'est pas dans la table du SM83.#{suggestion(mnemonique)}
        """
    end
  end

  defp orphelins(arguments) do
    # Une condition en tête n'est pas un opérande : la retirer avant de chercher
    # les fautives, sinon `{:jr, :nz, cible}` accuserait `:nz`.
    arguments
    |> case do
      [tete | reste] when tete in [:nz, :z, :nc, :c] -> reste
      tous -> tous
    end
    |> Enum.filter(&(formes(&1) == []))
  end

  # Les formes réellement existantes, en syntaxe assembleur. `:ld` en compte
  # quatre-vingt-sept : les lister toutes n'aide personne. On montre celles qui
  # ressemblent le plus à ce qui a été écrit — d'abord le nombre d'opérandes qui
  # tombent juste, ensuite l'écart d'arité. Sur `{:ld, :a, :bc}`, la faute étant
  # dans le second opérande, ce sont les formes en A qui remontent.
  @plafond_formes 12

  defp formes_connues(mnemonique, arguments) do
    labels =
      Table.all()
      |> Enum.filter(&(&1.mnemonic == mnemonique))
      |> Enum.sort_by(&{-concordance(&1, arguments), ecart_arite(&1, arguments)})
      |> Enum.map(&Insn.label/1)
      |> Enum.uniq()

    {montrees, reste} = Enum.split(labels, @plafond_formes)

    debut = "Formes connues :\n" <> Enum.map_join(montrees, "\n", &"  #{&1}")

    case reste do
      [] -> debut
      autres -> debut <> "\n  … et #{length(autres)} autres."
    end
  end

  # Le nombre d'opérandes de la table qu'un opérande source écrit à la même place
  # pourrait effectivement désigner.
  defp concordance(insn, arguments) do
    ecrits =
      case arguments do
        [tete | reste] when tete in [:nz, :z, :nc, :c] and insn.condition != nil -> reste
        tous -> tous
      end

    insn.operands
    |> Enum.zip(ecrits)
    |> Enum.count(fn {gabarit, ecrit} -> gabarit in formes(ecrit) end)
  end

  defp ecart_arite(insn, arguments) do
    arite = length(insn.operands) + if(insn.condition, do: 1, else: 0)
    abs(arite - length(arguments))
  end

  defp suggestion(mnemonique) do
    ecrit = Atom.to_string(mnemonique)

    proches =
      @mnemoniques
      |> Enum.map(&{String.jaro_distance(ecrit, Atom.to_string(&1)), &1})
      # 0,65 et non 0,8 : les mnémoniques du SM83 font deux ou trois lettres, où
      # une seule faute de frappe fait déjà tomber la distance de Jaro à 0,67.
      |> Enum.filter(fn {score, _} -> score >= 0.65 end)
      |> Enum.sort(:desc)
      |> Enum.take(3)
      |> Enum.map(fn {_, nom} -> inspect(nom) end)

    case proches do
      [] -> ""
      [seul] -> " Vouliez-vous dire #{seul} ?"
      plusieurs -> " Vouliez-vous dire #{Enum.join(plusieurs, ", ")} ?"
    end
  end

  defp hexa(valeur), do: valeur |> Integer.to_string(16) |> String.pad_leading(4, "0")
end
