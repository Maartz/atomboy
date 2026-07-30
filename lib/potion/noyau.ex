defmodule Potion.Noyau do
  @moduledoc """
  Le runtime SM83 de Potion, écrit comme donnée.

  Un jeu Potion n'est pas un programme qui s'exécuterait tout seul : c'est un
  *acteur* — quelques dizaines d'octets qui lisent un pad et déplacent un
  sprite. Tout ce qui sépare ces octets d'une console qui affiche quelque chose
  est ici : allumer l'écran, tenir l'OAM, battre au rythme du vblank, appeler
  l'acteur une fois par frame.

  Ce module n'émet aucun octet. Il retourne des **fragments de programme** au
  format de `Potion.Assembleur` — des listes de tuples. Le noyau est donc une
  valeur, qu'on peut concaténer, inspecter, découper, et dont une partie se
  fait assembler séparément pour être recopiée ailleurs en mémoire (la routine
  DMA, plus bas). Un noyau écrit en octets à la main n'aurait aucune de ces
  propriétés.

  ## La carte mémoire

      0xC000-0xC09F   l'OAM miroir — les 40 entrées de sprites, en WRAM
      0xC0A0          l'état du pad, recomposé chaque frame
      0xC0A1          le drapeau « frame prête »
      0xC0A2-0xC0FF   réservé au noyau
      0xC100-0xC1FF   l'état de l'acteur — effacé au démarrage, libre ensuite
      0xDFFF          le sommet de la pile
      0xFF80-0xFF89   la routine DMA, recopiée en HRAM par l'init

  L'acteur écrit ses sprites dans l'OAM miroir, jamais dans l'OAM réelle :
  entrée 0 en 0xC000 (Y+16), 0xC001 (X+8), 0xC002 (tuile), 0xC003 (attributs).
  Le décalage de 16 et de 8 est celui du matériel — l'OAM range la position du
  *coin bas-droit étendu*, ce qui permet à un sprite de sortir par le haut ou
  par la gauche de l'écran. Le DMA du vblank suivant publie le tout d'un bloc.

  ## Pourquoi un miroir, et pourquoi le DMA depuis la HRAM

  L'OAM n'est lisible par le CPU que pendant le vblank ; en dehors, le PPU la
  balaye et le bus est à lui. Un jeu qui écrirait ses sprites au fil de sa
  logique les écrirait donc dans le vide une frame sur deux. D'où le miroir en
  WRAM, accessible en permanence, et la publication par un transfert unique
  quand la dalle se tait.

  Ce transfert est un DMA matériel : le jeu écrit la page source dans 0xFF46
  et le contrôleur recopie 160 octets tout seul. Pendant ces 160 cycles, le
  CPU n'a plus accès au bus principal — ni ROM, ni WRAM. La seule mémoire qui
  lui reste est la HRAM, ces 127 octets câblés dans le processeur même. Un
  `CALL` vers une routine restée en ROM lirait donc du néant à l'instruction
  suivante. Le noyau recopie donc la routine en 0xFF80 au démarrage et l'y
  appelle : c'est la contrainte matérielle la plus contre-intuitive de la
  console, et le premier endroit où une ROM Potion doit ressembler à une vraie.

  Notre émulateur, lui, exécute le DMA d'un coup à l'écriture de 0xFF46 et
  laisserait passer une routine restée en ROM. On écrit quand même la vraie :
  une ROM qui ne tournerait que chez nous ne prouverait rien.

  ## Le battement

  L'init arme l'interruption vblank, et *seulement* elle (IE = 0x01). La
  boucle principale est alors un `HALT` : le processeur dort, le vblank le
  réveille, le handler lève le drapeau, la boucle lit le pad, appelle l'acteur,
  et se rendort. C'est l'ordonnanceur v0 — un seul slot, l'acteur unique — et
  c'est aussi la forme que garderont les suivants : ce qui change alors est le
  contenu du slot, pas le battement.

  Le drapeau n'est pas une décoration. `HALT` se réveille sur *toute*
  interruption servie, et il en viendra d'autres (le timer, le joypad, STAT) le
  jour où le noyau les armera ; le drapeau distingue « c'est une nouvelle
  frame » de « on m'a réveillé ». Sans lui, l'acteur tournerait à un rythme
  inconnu de lui.

  ## Les deux tuiles du v0

  La tuile 0 est un carré plein — le sprite. La tuile 1 est vide, et l'init
  remplit toute la carte de fond (0x9800-0x9BFF) de tuile 1.

  Cette carte est le seul écart avec un noyau strictement minimal, et il est
  forcé : la VRAM effacée met la carte de fond à zéro, donc à la tuile 0 — le
  carré plein. Le fond serait alors un aplat noir, et le sprite invisible
  dessus. Éteindre le fond (LCDC bit 0) serait l'autre issue, mais un jeu sans
  couche de fond n'est pas une Game Boy ; on remplit.
  """

  alias Potion.Assembleur

  # ── Les registres touchés ───────────────────────────────────────────────────

  @p1 0x00
  @div 0x04
  @lcdc 0x40
  @scy 0x42
  @scx 0x43
  @ly 0x44
  @dma 0x46
  @bgp 0x47
  @obp0 0x48
  @irq_if 0x0F
  @irq_ie 0xFF

  # ── La carte mémoire ────────────────────────────────────────────────────────

  @oam_miroir 0xC000
  @pad 0xC0A0
  @drapeau 0xC0A1
  @etat 0xC100
  @hram_dma 0xFF80
  @pile 0xDFFF

  # La VRAM entière, la carte de fond, et la page de WRAM que l'init efface :
  # l'OAM miroir, les cellules du noyau, et l'état de l'acteur.
  @vram 0x8000
  @vram_octets 0x2000
  @fond 0x9800
  @wram_efface 0x0200

  # LCD allumé, données de tuiles en 0x8000 (indices non signés), OBJ et BG
  # allumés. 0x93 est ce que la quasi-totalité des jeux DMG écrit.
  @lcdc_marche 0x93

  # La palette de l'identité : couleur 0 → teinte 0, 1 → 1, 2 → 2, 3 → 3.
  @palette 0xE4

  @doc """
  Le programme complet : l'init, le noyau, puis le code de l'acteur.

  Prêt pour `Potion.ROM.construit(programme, vblank: :vblank)` — sans cette
  option le vecteur 0x40 reste des zéros et la première interruption servie
  exécuterait du remplissage.

  Le fragment `acteur` n'a pas à se nommer : le noyau pose l'étiquette
  `:acteur` juste avant lui. Il doit en revanche finir par un `{:ret}` — c'est
  un `CALL` qui l'atteint, et un acteur qui déborde de son fragment continue
  dans les octets suivants, c'est-à-dire dans le remplissage de la cartouche.
  Le contrôle est fait ici, à l'assemblage, parce qu'à l'exécution le symptôme
  serait un opcode illégal à des milliers de cycles de sa cause.
  """
  @spec programme([Assembleur.element()]) :: [Assembleur.element()]
  def programme(acteur) when is_list(acteur) do
    verifie_acteur!(acteur)

    init() ++
      vblank() ++
      lire_pad() ++
      boucle() ++
      [{:etiquette, :dma_source}, {:octets, octets_dma()}] ++
      [{:etiquette, :acteur}] ++ acteur
  end

  defp verifie_acteur!(acteur) do
    case List.last(acteur) do
      {:ret} ->
        :ok

      autre ->
        raise ArgumentError, """
        l'acteur ne finit pas par un RET : #{inspect(autre)}

        Le noyau atteint l'acteur par un CALL, une fois par frame. Sans RET \
        final, l'exécution continue dans ce qui suit le fragment — le \
        remplissage de la cartouche, puis la VRAM.
        """
    end
  end

  @doc """
  L'adresse de l'OAM miroir — l'entrée 0 commence là.
  """
  @spec oam_miroir() :: 0xC000
  def oam_miroir, do: @oam_miroir

  @doc "La cellule d'état du pad, recomposée à chaque frame par le noyau."
  @spec pad() :: 0xC0A0
  def pad, do: @pad

  @doc "Le drapeau « frame prête » : levé par le handler, consommé par la boucle."
  @spec drapeau() :: 0xC0A1
  def drapeau, do: @drapeau

  @doc "La première adresse laissée à l'acteur."
  @spec etat() :: 0xC100
  def etat, do: @etat

  @doc "L'adresse de la routine DMA en HRAM."
  @spec hram_dma() :: 0xFF80
  def hram_dma, do: @hram_dma

  # ══ L'init ═══════════════════════════════════════════════════════════════════

  @doc """
  Le démarrage : de l'état laissé par la ROM de boot à une machine qui bat.

  Dans l'ordre, et l'ordre compte : couper les interruptions, poser la pile,
  attendre le vblank *avant* de toucher au LCD (l'éteindre en pleine ligne
  visible abîme les vraies dalles), effacer la VRAM que rien n'a initialisée,
  installer les tuiles et la carte de fond, recopier le DMA en HRAM, poser les
  palettes, et seulement alors rallumer l'écran et ouvrir les interruptions.
  """
  @spec init() :: [Assembleur.element()]
  def init do
    [
      {:etiquette, :init},
      {:di},
      {:ld, :sp, @pile},
      # DIV remis à zéro : le seul compteur qui tourne depuis le boot, et le
      # seul grain d'aléa dont un jeu v0 disposerait. Autant partir d'un état
      # connu — une frame dorée ne se compare pas à une machine qui a démarré
      # à un autre instant.
      {:xor, :a, :a},
      {:ldh, {:haut, @div}, :a}
    ] ++
      attente_vblank() ++
      [
        # LCD éteint : le PPU lâche le bus, la VRAM devient écrivable d'un
        # bout à l'autre. Le même zéro sert à recentrer le fond — SCX et SCY
        # sortent du boot à zéro sur DMG, mais rien ne l'y oblige.
        {:xor, :a, :a},
        {:ldh, {:haut, @lcdc}, :a},
        {:ldh, {:haut, @scy}, :a},
        {:ldh, {:haut, @scx}, :a}
      ] ++
      efface(@vram, @vram_octets, :efface_vram) ++
      efface(@oam_miroir, @wram_efface, :efface_wram) ++
      carte_de_fond() ++
      tuiles() ++
      copie_dma() ++
      [
        {:ld, :a, @palette},
        {:ldh, {:haut, @bgp}, :a},
        {:ldh, {:haut, @obp0}, :a},
        # IF nettoyé avant d'ouvrir : l'attente de vblank ci-dessus a laissé
        # le bit 0 levé. Sans ce coup de balai, le premier EI servirait une
        # frame fantôme et l'acteur tournerait deux fois pour une seule dalle.
        {:xor, :a, :a},
        {:ldh, {:haut, @irq_if}, :a},
        {:ld, :a, 0x01},
        {:ldh, {:haut, @irq_ie}, :a},
        {:ld, :a, @lcdc_marche},
        {:ldh, {:haut, @lcdc}, :a},
        {:ei},
        {:jp, {:etiquette, :boucle}}
      ]
  end

  # Scruter LY jusqu'au vblank. C'est l'attente active des jeux réels — il n'y
  # a rien d'autre à faire avant que les interruptions soient armées, et le
  # matériel ne propose aucun « attendre » qui ne soit pas une boucle.
  defp attente_vblank do
    [
      {:etiquette, :attente_vblank},
      {:ldh, :a, {:haut, @ly}},
      {:cp, :a, 144},
      {:jr, :c, {:etiquette, :attente_vblank}}
    ]
  end

  # Une plage mise à zéro : 256 tours d'un corps déroulé autant de fois qu'il
  # faut. `LD (HL+), A` coûte 8 cycles, la fin de boucle 16 de plus — une
  # boucle d'une seule écriture passerait les deux tiers de son temps à
  # compter, et la VRAM entière lui prendrait trois frames. Déroulée
  # trente-deux fois, elle tient dans une.
  #
  # `LD B, 0` puis `DEC B` : 256 tours, le zéro comptant pour un tour complet.
  # Le compteur est le registre, jamais une cellule mémoire.
  defp efface(base, octets, etiquette) when rem(octets, 256) == 0 do
    [
      {:ld, :hl, base},
      {:xor, :a, :a},
      {:ld, :b, 0},
      {:etiquette, etiquette}
    ] ++
      List.duplicate({:ld, {:mem, :hl_inc}, :a}, div(octets, 256)) ++
      [
        {:dec, :b},
        {:jr, :nz, {:etiquette, etiquette}}
      ]
  end

  # La carte de fond en tuile 1 — la tuile vide. La sortie de boucle se lit sur
  # H : la carte va de 0x9800 à 0x9BFF, et 0x9C est le premier octet haut dont
  # le bit 2 est levé. Tester un bit d'un registre coûte moins qu'entretenir un
  # compteur, et l'adresse de fin est déjà dans HL.
  defp carte_de_fond do
    [
      {:ld, :hl, @fond},
      {:ld, :a, 0x01},
      {:etiquette, :carte_fond},
      {:ld, {:mem, :hl_inc}, :a},
      {:bit, 2, :h},
      {:jr, :z, {:etiquette, :carte_fond}}
    ]
  end

  # La tuile 0 : seize octets à 0xFF, soit huit lignes de huit pixels en
  # couleur 3 — un carré plein. Deux bitplans à 1 font la couleur 3, et c'est
  # tout le tileset du v0. La tuile 1 reste celle que l'effacement a laissée.
  defp tuiles do
    [
      {:ld, :hl, @vram},
      {:ld, :a, 0xFF},
      {:ld, :b, 16},
      {:etiquette, :tuile_pleine},
      {:ld, {:mem, :hl_inc}, :a},
      {:dec, :b},
      {:jr, :nz, {:etiquette, :tuile_pleine}}
    ]
  end

  # La recopie de la routine DMA vers la HRAM. La longueur n'est pas écrite à
  # la main : elle vient de l'assemblage de la routine elle-même. C'est le
  # bénéfice concret d'un noyau qui est une valeur — la source et la mesure ne
  # peuvent pas diverger.
  defp copie_dma do
    [
      {:ld, :hl, {:etiquette, :dma_source}},
      {:ld, :c, @hram_dma - 0xFF00},
      {:ld, :b, byte_size(octets_dma())},
      {:etiquette, :copie_dma},
      {:ld, :a, {:mem, :hl_inc}},
      {:ldh, {:haut, :c}, :a},
      {:inc, :c},
      {:dec, :b},
      {:jr, :nz, {:etiquette, :copie_dma}}
    ]
  end

  # ══ Le handler vblank ════════════════════════════════════════════════════════

  @doc """
  Le handler d'interruption vblank — la cible de l'option `vblank:` de
  `Potion.ROM`.

  Il sauve les quatre paires : une interruption tombe entre deux instructions
  quelconques de la boucle principale, et rendre la main avec un registre
  modifié est le genre de bug qui se manifeste une fois sur mille frames.

  Le drapeau se lève *avant* le DMA. L'ordre est libre — la boucle principale
  ne peut rien voir avant le RETI — et celui-ci dit ce que le drapeau signifie
  vraiment : « une frame a commencé », pas « l'OAM est publiée ».
  """
  @spec vblank() :: [Assembleur.element()]
  def vblank do
    [
      {:etiquette, :vblank},
      {:push, :af},
      {:push, :bc},
      {:push, :de},
      {:push, :hl},
      {:ld, :a, 0x01},
      {:ld, {:mem, @drapeau}, :a},
      {:call, @hram_dma},
      {:pop, :hl},
      {:pop, :de},
      {:pop, :bc},
      {:pop, :af},
      {:reti}
    ]
  end

  @doc """
  La routine DMA, dans sa forme source — celle qui sera assemblée à part et
  recopiée en 0xFF80.

  L'attente est un décompte de quarante tours à seize cycles : les 160 cycles
  machine que le contrôleur met à recopier l'OAM. Il n'y a aucun registre à
  scruter — le matériel n'annonce pas la fin d'un DMA, il faut la compter.
  """
  @spec routine_dma() :: [Assembleur.element()]
  def routine_dma do
    [
      {:ld, :a, div(@oam_miroir, 0x100)},
      {:ldh, {:haut, @dma}, :a},
      {:ld, :a, 40},
      {:etiquette, :attente},
      {:dec, :a},
      {:jr, :nz, {:etiquette, :attente}},
      {:ret}
    ]
  end

  @doc """
  Les octets de la routine DMA, assemblés à son adresse d'exécution.

  L'origine 0xFF80 n'est pas décorative : les étiquettes de la routine
  désignent des adresses absolues, et l'assembler à 0x0150 donnerait un saut
  relatif correct par accident (JR compte une distance) mais toute évolution —
  un `JP`, une table — sortirait fausse. Assemblée à part, la routine a aussi
  son propre espace d'étiquettes : son `:attente` ne peut pas collisionner avec
  celles du noyau.
  """
  @spec octets_dma() :: binary()
  def octets_dma, do: Assembleur.assemble(routine_dma(), origine: @hram_dma)

  # ══ Le pad ═══════════════════════════════════════════════════════════════════

  @doc """
  La lecture du pad, recomposée en un octet à l'endroit.

  P1 (0xFF00) est un registre à matrice : le jeu tire une des deux nappes à la
  masse (bit 4 les directions, bit 5 les boutons — actifs à *zéro*) et relit
  quatre lignes dans le quartet bas, elles aussi actives à zéro. Deux niveaux
  de logique inversée dont aucun jeu ne veut dans sa logique.

  Le noyau les paie une fois pour toutes : `CPL` remet les touches à l'endroit,
  `SWAP` range les boutons dans le quartet haut, et 0xC0A0 porte un octet où un
  bit à 1 veut dire « appuyé » :

      bit 0 Droite   bit 1 Gauche   bit 2 Haut     bit 3 Bas
      bit 4 A        bit 5 B        bit 6 Select   bit 7 Start

  La double lecture de chaque nappe est un rite du matériel : les lignes sont
  des résistances de tirage, elles mettent quelques cycles à s'établir après un
  changement de sélection, et la première lecture peut mentir. Elle ne coûte
  rien et un jour elle nous évitera un bug qu'on ne saurait pas nommer.
  """
  @spec lire_pad() :: [Assembleur.element()]
  def lire_pad do
    [{:etiquette, :lire_pad}] ++
      nappe(0x20) ++
      [{:ld, :b, :a}] ++
      nappe(0x10) ++
      [
        {:swap, :a},
        {:or, :a, :b},
        {:ld, {:mem, @pad}, :a},
        # Les deux nappes relâchées : c'est l'état au repos du registre, et
        # celui qu'un lecteur extérieur (le combo de reset du matériel, par
        # exemple) attend entre deux frames.
        {:ld, :a, 0x30},
        {:ldh, {:haut, @p1}, :a},
        {:ret}
      ]
  end

  defp nappe(selection) do
    [
      {:ld, :a, selection},
      {:ldh, {:haut, @p1}, :a},
      {:ldh, :a, {:haut, @p1}},
      {:ldh, :a, {:haut, @p1}},
      {:cpl},
      {:and, :a, 0x0F}
    ]
  end

  # ══ La boucle principale ═════════════════════════════════════════════════════

  @doc """
  L'ordonnanceur v0 : dormir, se réveiller sur le vblank, lire le pad, appeler
  l'acteur, se rendormir.

  `HALT` n'est pas une économie de batterie ici, c'est la seule horloge du
  système : il donne au noyau un rythme exact d'une frame, sans compter un
  seul cycle. Une boucle qui scruterait LY marcherait aussi, et dériverait dès
  que l'acteur grossirait.
  """
  @spec boucle() :: [Assembleur.element()]
  def boucle do
    [
      {:etiquette, :boucle},
      {:halt},
      # Réveil : d'où vient-il ? Sans drapeau levé, ce n'était pas une frame.
      {:ld, :a, {:mem, @drapeau}},
      {:and, :a, :a},
      {:jr, :z, {:etiquette, :boucle}},
      {:xor, :a, :a},
      {:ld, {:mem, @drapeau}, :a},
      {:call, {:etiquette, :lire_pad}},
      {:call, {:etiquette, :acteur}},
      {:jr, {:etiquette, :boucle}}
    ]
  end
end
