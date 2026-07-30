defmodule Atomboy.Native.Banc do
  @moduledoc """
  Le test différentiel des drapeaux : `Atomboy.Native.ALU` contre
  `Atomboy.CPU.ALU`, sur l'espace d'entrée entier.

  ## Pourquoi exhaustif plutôt que par l'exemple

  La demi-retenue d'`ADC` a un cas fautif quand la somme des quartets bas tombe
  pile sur `0xF` et que la retenue entre à 1 : un cas sur 4 096. `DAA` a des
  coins que personne ne devine. Une poignée d'exemples laisse passer ces
  bugs-là, et ils ne se manifestent que des mois plus tard, très loin de leur
  cause. Comparer les deux implémentations sur **toutes** les entrées enlève la
  question du tableau.

  ## La comparaison se fait dans l'invité

  Un million de cas à deux octets font deux mégaoctets à faire passer par un
  port série émulé, un octet à la fois. L'image embarque donc les résultats
  attendus, calculés en Elixir par `Atomboy.CPU.ALU`, et l'invité ne renvoie que
  les **écarts** : dix octets par divergence, deux octets quand tout va bien.
  L'image grossit, ce qui ne coûte rien ; la sortie maigrit, ce qui coûtait tout.

  Un écart nomme la routine, l'index du cas, ce qui a été produit et ce qui
  était attendu — assez pour reconstituer l'entrée sans relancer quoi que ce
  soit.

  ## Ce qui est exhaustif, et ce qui ne l'est pas

  Exhaustif : les opérations sur deux octets (65 536 cas), celles sur un octet
  et F (4 096 cas), les huit `BIT n`. `ADC` et `SBC` sont balayés deux fois, sur
  tout `(a, v)`, avec F à `0x00` puis à `0xF0` — les deux états de la retenue,
  et de quoi attraper une routine qui lirait N, H ou Z par mégarde.

  Balayés, pas exhaustifs : `ADD HL, rr` et `ADD SP, r8`, dont l'espace fait
  2³² entrées. Le second opérande y est dérivé du premier par un mélange de
  décalages et de ou-exclusifs, ce qui couvre 65 536 couples bien répartis. Les
  vecteurs SM83 les reprendront à l'étape 5.
  """

  import Bitwise

  alias Atomboy.CPU.ALU, as: Oracle
  alias Atomboy.Native.ALU
  alias Atomboy.Native.Asm
  alias Atomboy.Native.Image
  alias Atomboy.Native.Qemu
  alias Atomboy.Native.RV32

  @magic_ecart 0xE7
  @fin 0xFF
  @ecarts_max 16
  @taille_ecart 10

  # ══ Les balayages ════════════════════════════════════════════════════════════

  @octet_et_f 4096
  @deux_octets 65536

  @doc """
  Les balayages, en donnée — nom, routine visée, forme d'appel, nombre de cas.

  L'ordre compte : il est l'index que l'invité renvoie dans un écart.
  """
  @spec balayages() :: [map()]
  def balayages do
    acc = [:add, :sub, :cp, :bit_and, :bit_xor, :bit_or]
    octet = [:inc, :dec, :rlc, :rrc, :rl, :rr, :sla, :sra, :swap, :srl]
    accumulateur = [:rlca, :rrca, :rla, :rra, :daa, :cpl, :scf, :ccf]

    for(nom <- acc, do: %{nom: nom, forme: :acc, f: 0x00, cas: @deux_octets}) ++
      for(
        nom <- [:adc, :sbc],
        f <- [0x00, 0xF0],
        do: %{nom: nom, forme: :acc, f: f, cas: @deux_octets}
      ) ++
      for(nom <- octet, do: %{nom: nom, forme: :octet, cas: @octet_et_f}) ++
      for(nom <- accumulateur, do: %{nom: nom, forme: :accumulateur, cas: @octet_et_f}) ++
      for(n <- 0..7, do: %{nom: :"bit_#{n}", bit: n, forme: :octet, cas: @octet_et_f}) ++
      [
        %{nom: :add16, forme: :mot16, cas: @deux_octets},
        %{nom: :add_sp, forme: :add_sp, cas: @deux_octets}
      ]
  end

  @doc "L'étiquette de la routine visée par un balayage."
  @spec etiquette(map()) :: atom()
  def etiquette(%{bit: n}), do: ALU.etiquette_bit(n)
  def etiquette(%{nom: nom}), do: ALU.etiquette(nom)

  # ══ Ce que l'oracle attend ═══════════════════════════════════════════════════

  @doc """
  Les entrées d'un cas, dérivées de son index.

  Les mêmes formules que le code émis pour l'invité — c'est le seul endroit du
  banc où une divergence entre les deux serait invisible, d'où un test dédié.
  """
  @spec entrees(map(), non_neg_integer()) :: map()
  def entrees(%{forme: :acc, f: f}, i), do: %{a: i >>> 8, v: i &&& 0xFF, f: f}

  def entrees(%{forme: forme}, i) when forme in [:octet, :accumulateur],
    do: %{v: i >>> 4, f: (i &&& 0x0F) <<< 4}

  def entrees(%{forme: :mot16}, i),
    do: %{hl: i, v: melange16(i), f: (i &&& 0x0F) <<< 4}

  def entrees(%{forme: :add_sp}, i), do: %{sp: i, v: melange8(i), f: 0}

  @doc "Le mélange qui fabrique le second opérande 16 bits d'`ADD HL, rr`."
  @spec melange16(non_neg_integer()) :: 0..0xFFFF
  def melange16(i), do: bxor(bxor(i <<< 7, i >>> 3), 0x5A5A) &&& 0xFFFF

  @doc "Le mélange qui fabrique l'offset d'`ADD SP, r8`."
  @spec melange8(non_neg_integer()) :: 0..0xFF
  def melange8(i), do: bxor(i <<< 3, i >>> 5) &&& 0xFF

  @doc """
  Le résultat attendu d'un cas : `{valeur, drapeaux}`.

  La valeur est celle qu'on relira dans le registre après l'appel — donc la
  valeur d'entrée inchangée pour `CP`, `BIT` et `SCF`, qui n'écrivent que F.
  """
  @spec attendu(map(), non_neg_integer()) :: {non_neg_integer(), 0..0xFF}
  def attendu(%{nom: :cp} = b, i) do
    %{a: a, v: v} = entrees(b, i)
    {a, Oracle.cp(a, v)}
  end

  def attendu(%{bit: n} = b, i) do
    %{v: v, f: f} = entrees(b, i)
    {v, Oracle.bit_test(n, v, f)}
  end

  def attendu(%{forme: :acc, nom: nom} = b, i) do
    %{a: a, v: v, f: f} = entrees(b, i)

    case nom do
      n when n in [:adc, :sbc] -> apply(Oracle, n, [a, f, v])
      n -> apply(Oracle, n, [a, v])
    end
  end

  def attendu(%{forme: forme, nom: nom} = b, i) when forme in [:octet, :accumulateur] do
    %{v: v, f: f} = entrees(b, i)
    apply(Oracle, nom, [v, f])
  end

  def attendu(%{forme: :mot16} = b, i) do
    %{hl: hl, v: v, f: f} = entrees(b, i)
    Oracle.add16(hl, v, f)
  end

  def attendu(%{forme: :add_sp} = b, i) do
    %{sp: sp, v: v} = entrees(b, i)
    Oracle.add_sp(sp, v)
  end

  @doc "Les octets attendus d'un balayage entier — deux par cas, trois en 16 bits."
  @spec attendus(map()) :: binary()
  def attendus(balayage) do
    large? = balayage.forme in [:mot16, :add_sp]

    0..(balayage.cas - 1)
    |> Enum.map(fn i ->
      {valeur, f} = attendu(balayage, i)
      if large?, do: <<valeur::16-little, f>>, else: <<valeur, f>>
    end)
    |> IO.iodata_to_binary()
  end

  # ══ L'exécution ══════════════════════════════════════════════════════════════

  @doc """
  Construit et exécute le banc ; rend la liste des écarts.

  Une liste vide veut dire que les deux implémentations sont indiscernables sur
  tout ce qui a été balayé.
  """
  @spec executer(keyword()) :: {:ok, [map()]} | {:error, term()}
  def executer(opts \\ []) do
    image = image()

    case Qemu.run(image.code, Keyword.put_new(opts, :timeout, 120_000)) do
      %{status: :timeout, duration_us: us} -> {:error, {:timeout, us}}
      %{status: :ok, serial: serial} -> decoder(serial)
    end
  end

  @doc "L'image du banc : les routines, les pilotes de balayage, et les attendus."
  @spec image() :: Asm.assembled()
  def image do
    balayages = balayages()

    Image.build(
      [
        preambule(),
        balayages |> Enum.with_index() |> Enum.map(&pilote/1),
        Asm.label(:banc_fin),
        RV32.li(:a0, @fin),
        Asm.call(:putc),
        RV32.mv(:a0, :s10),
        Asm.call(:putc),
        Asm.j(:poweroff),
        ALU.routines()
      ],
      donnees(balayages)
    )
  end

  defp preambule do
    [
      RV32.li(:s8, 0xFFFF),
      Asm.la(:s9, :attendus),
      RV32.li(:s10, 0)
    ]
  end

  # ══ Un pilote de balayage ════════════════════════════════════════════════════

  defp pilote({balayage, index}) do
    boucle = :"balayage_#{index}_boucle"
    ecart = :"balayage_#{index}_ecart"
    suite = :"balayage_#{index}_suite"
    large? = balayage.forme in [:mot16, :add_sp]

    [
      RV32.li(:t6, 0),
      RV32.li(:s2, balayage.cas),
      Asm.label(boucle),
      entree(balayage),
      Asm.call(etiquette(balayage)),
      RV32.mv(:t4, resultat(balayage.forme)),
      lire_attendu(large?),
      Asm.bne(:t4, :t2, ecart),
      Asm.bne(:s1, :t3, ecart),
      Asm.j(suite),
      Asm.label(ecart),
      rapporter(index),
      RV32.addi(:s10, :s10, 1),
      RV32.li(:t0, @ecarts_max),
      Asm.blt(:s10, :t0, suite),
      Asm.j(:banc_fin),
      Asm.label(suite),
      RV32.addi(:t6, :t6, 1),
      Asm.bne(:t6, :s2, boucle)
    ]
  end

  # Les entrées, dérivées de t6 — le miroir exact d'`entrees/2`. Que les deux
  # dérivations s'accordent n'a pas besoin d'un test à part : l'attendu est
  # calculé depuis celle d'Elixir et le résultat produit depuis celle-ci, donc
  # un désaccord fait diverger les deux. Y compris pour les opérations qui
  # ignorent leur opérande — `SCF` rend A inchangé, donc A est comparé quand
  # même.
  defp entree(%{forme: :acc, f: f}) do
    [
      RV32.srli(:s0, :t6, 8),
      RV32.andi(:a0, :t6, 0xFF),
      RV32.li(:s1, f)
    ]
  end

  defp entree(%{forme: :octet}) do
    [
      RV32.srli(:a0, :t6, 4),
      RV32.andi(:s1, :t6, 0x0F),
      RV32.slli(:s1, :s1, 4)
    ]
  end

  defp entree(%{forme: :accumulateur}) do
    [
      RV32.srli(:s0, :t6, 4),
      RV32.andi(:s1, :t6, 0x0F),
      RV32.slli(:s1, :s1, 4)
    ]
  end

  defp entree(%{forme: :mot16}) do
    [
      RV32.mv(:a2, :t6),
      melange(7, 3, 0x5A5A),
      RV32.and_(:a0, :t0, :s8),
      RV32.andi(:s1, :t6, 0x0F),
      RV32.slli(:s1, :s1, 4)
    ]
  end

  defp entree(%{forme: :add_sp}) do
    [
      RV32.mv(:a0, :t6),
      melange(3, 5, nil),
      RV32.andi(:a1, :t0, 0xFF),
      RV32.li(:s1, 0)
    ]
  end

  defp melange(gauche, droite, sel) do
    [
      RV32.slli(:t0, :t6, gauche),
      RV32.srli(:t1, :t6, droite),
      RV32.xor_(:t0, :t0, :t1),
      if sel do
        [RV32.li(:t1, sel), RV32.xor_(:t0, :t0, :t1)]
      else
        []
      end
    ]
  end

  defp resultat(:acc), do: :s0
  defp resultat(:accumulateur), do: :s0
  defp resultat(:octet), do: :a0
  defp resultat(:mot16), do: :a2
  defp resultat(:add_sp), do: :a0

  defp lire_attendu(false) do
    [
      RV32.lbu(:t2, :s9, 0),
      RV32.lbu(:t3, :s9, 1),
      RV32.addi(:s9, :s9, 2)
    ]
  end

  defp lire_attendu(true) do
    [
      RV32.lbu(:t2, :s9, 0),
      RV32.lbu(:t5, :s9, 1),
      RV32.slli(:t5, :t5, 8),
      RV32.or_(:t2, :t2, :t5),
      RV32.lbu(:t3, :s9, 2),
      RV32.addi(:s9, :s9, 3)
    ]
  end

  # `putc` n'écrase que t0, t1 et a0 : t2, t3, t4, t6 et s1 traversent le
  # rapport intacts, ce qui évite de les sauvegarder sur la pile.
  defp rapporter(index) do
    [
      octet(RV32.li(:a0, @magic_ecart)),
      octet(RV32.li(:a0, index)),
      octet(RV32.mv(:a0, :t6)),
      octet(RV32.srli(:a0, :t6, 8)),
      octet(RV32.mv(:a0, :t4)),
      octet(RV32.srli(:a0, :t4, 8)),
      octet(RV32.mv(:a0, :s1)),
      octet(RV32.mv(:a0, :t2)),
      octet(RV32.srli(:a0, :t2, 8)),
      octet(RV32.mv(:a0, :t3))
    ]
  end

  defp octet(charge), do: [charge, Asm.call(:putc)]

  # ══ Les données ══════════════════════════════════════════════════════════════

  defp donnees(balayages) do
    [
      {:align, 4},
      Asm.label(:attendus),
      Enum.map(balayages, &attendus/1)
    ]
  end

  # ══ Le décodage ══════════════════════════════════════════════════════════════

  defp decoder(serial) do
    balayages = balayages()
    lire_ecarts(serial, balayages, [])
  end

  defp lire_ecarts(<<@fin, _compte, _reste::binary>>, _balayages, acc),
    do: {:ok, Enum.reverse(acc)}

  defp lire_ecarts(
         <<@magic_ecart, index, cas::16-little, obtenu::16-little, drapeaux, attendu::16-little,
           drapeaux_attendus, reste::binary>>,
         balayages,
         acc
       ) do
    balayage = Enum.at(balayages, index)

    ecart = %{
      balayage: balayage.nom,
      cas: cas,
      entrees: entrees(balayage, cas),
      obtenu: {obtenu, drapeaux},
      attendu: {attendu, drapeaux_attendus}
    }

    lire_ecarts(reste, balayages, [ecart | acc])
  end

  defp lire_ecarts(autre, _balayages, _acc) do
    {:error,
     {:flux_illisible, byte_size(autre), binary_part(autre, 0, min(32, byte_size(autre)))}}
  end

  @doc "La taille d'un enregistrement d'écart, pour les tests du protocole."
  @spec taille_ecart() :: pos_integer()
  def taille_ecart, do: @taille_ecart
end
