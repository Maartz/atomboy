defmodule Atomboy.CPU.ALU do
  @moduledoc """
  Les huit opérations arithmétiques et logiques du SM83, avec leurs drapeaux.

  Écrites à la main, pas générées. `Atomboy.CPU.Gen` s'occupe de la *structure*
  — quel opcode appelle quoi sur quel opérande ; la sémantique des drapeaux vit
  ici, en Elixir lisible. Émettre ce calcul sous forme d'AST le rendrait
  illisible précisément là où il faut pouvoir le relire : les drapeaux sont
  l'endroit où les émulateurs se trompent, et où l'erreur reste invisible le
  plus longtemps.

  ## Niveau valeurs, pas niveau état

  Les fonctions prennent et rendent des octets : `add(a, v) → {résultat, f}`.
  Elles ne connaissent pas `Atomboy.CPU.State` — c'est ce qui permet aux deux
  backends générés de partager la même arithmétique :

    * le backend struct (`Atomboy.CPU.exec/3`, l'oracle) enveloppe le résultat
      dans une mise à jour de structure ;
    * la boucle rapide (`Atomboy.CPU.Loop`) le passe en argument d'appel
      terminal, sans rien construire.

  Un seul endroit calcule la demi-retenue ; aucun backend n'en a sa copie.
  Troisième consommateur prévu : le code recompilé de la phase 5 appellera ces
  mêmes primitives — la recompilation supprime le fetch, le décodage et le
  dispatch, pas l'arithmétique de drapeaux.

  ## Le registre F

  Quatre bits de poids fort, les quatre autres toujours à zéro :

      Z (0x80)  résultat nul
      N (0x40)  la dernière opération était une soustraction
      H (0x20)  retenue entre le bit 3 et le bit 4
      C (0x10)  retenue sortante

  `N` et `H` n'existent que pour `DAA`, qui doit savoir après coup si l'opération
  était une addition ou une soustraction et si le demi-octet a débordé. C'est la
  raison pour laquelle il faut les poser correctement même quand rien ne les lit
  encore : le bug ne se manifestera qu'à l'implémentation de `DAA`, très loin
  d'ici.

  ## Le piège de la demi-retenue

  Pour `ADC` et `SBC`, **la retenue entrante compte dans le calcul de `H`**.

      H de ADC = (a & 0xF) + (v & 0xF) + carry > 0xF

  L'oublier laisse passer la grande majorité des cas — il faut que la somme des
  demi-octets tombe pile sur 0xF et que le carry entre à 1 — et casse `DAA` bien
  plus tard, quand plus personne ne cherche de ce côté. Les vecteurs
  SingleStepTests couvrent ce cas ; c'est précisément pour ça qu'ils passent
  avant les ROMs de blargg.
  """

  import Bitwise

  @z 0x80
  @n 0x40
  @h 0x20
  @c 0x10

  @type byte8 :: 0..0xFF
  @typedoc "Le résultat d'une opération qui écrit A : `{nouvel A, nouveau F}`."
  @type result :: {byte8(), byte8()}

  @doc "ADD A, v — addition."
  @spec add(byte8(), byte8()) :: result()
  def add(a, value) do
    sum = a + value
    {sum &&& 0xFF, add_flags(a, value, 0, sum)}
  end

  @doc "ADC A, v — addition avec la retenue entrante extraite de `f`."
  @spec adc(byte8(), byte8(), byte8()) :: result()
  def adc(a, f, value) do
    carry = carry_in(f)
    sum = a + value + carry
    {sum &&& 0xFF, add_flags(a, value, carry, sum)}
  end

  @doc "SUB v — soustraction."
  @spec sub(byte8(), byte8()) :: result()
  def sub(a, value) do
    {a - value &&& 0xFF, sub_flags(a, value, 0)}
  end

  @doc "SBC A, v — soustraction avec l'emprunt entrant extrait de `f`."
  @spec sbc(byte8(), byte8(), byte8()) :: result()
  def sbc(a, f, value) do
    carry = carry_in(f)
    {a - value - carry &&& 0xFF, sub_flags(a, value, carry)}
  end

  @doc """
  CP v — comparaison. Renvoie les drapeaux seuls.

  Une soustraction dont le résultat est jeté : d'où la réutilisation de
  `sub_flags/3` — dupliquer le calcul reviendrait à entretenir deux fois la
  même subtilité d'emprunt.
  """
  @spec cp(byte8(), byte8()) :: byte8()
  def cp(a, value), do: sub_flags(a, value, 0)

  @doc """
  AND v — et logique.

  Seule opération logique à poser `H`. Ce n'est pas une régularité oubliée,
  c'est ainsi sur le matériel.
  """
  @spec bit_and(byte8(), byte8()) :: result()
  def bit_and(a, value) do
    result = a &&& value
    {result, zero(result) ||| @h}
  end

  @doc "XOR v — ou exclusif. Tous les drapeaux sauf Z sont remis à zéro."
  @spec bit_xor(byte8(), byte8()) :: result()
  def bit_xor(a, value) do
    result = bxor(a, value)
    {result, zero(result)}
  end

  @doc "OR v — ou logique. Tous les drapeaux sauf Z sont remis à zéro."
  @spec bit_or(byte8(), byte8()) :: result()
  def bit_or(a, value) do
    result = a ||| value
    {result, zero(result)}
  end

  @doc """
  INC v — incrément. Pose Z et H, efface N, **préserve C** depuis `f`.

  C'est le second piège classique après la demi-retenue : poser les quatre
  drapeaux par réflexe. Sur le matériel, INC et DEC laissent la retenue
  strictement intacte — le motif `OR A / INC / JR C` des jeux en dépend. D'où
  la signature : `f` entre, pour que le bit C en ressorte.
  """
  @spec inc(byte8(), byte8()) :: result()
  def inc(value, f) do
    result = value + 1 &&& 0xFF
    half = if (value &&& 0x0F) == 0x0F, do: @h, else: 0
    {result, zero(result) ||| half ||| (f &&& @c)}
  end

  @doc "DEC v — décrément. Pose Z, N et H (emprunt), **préserve C**."
  @spec dec(byte8(), byte8()) :: result()
  def dec(value, f) do
    result = value - 1 &&& 0xFF
    half = if (value &&& 0x0F) == 0x00, do: @h, else: 0
    {result, zero(result) ||| @n ||| half ||| (f &&& @c)}
  end

  @doc """
  ADD HL, rr — addition 16 bits.

  Le miroir inversé d'INC : ici c'est **Z qui est préservé** et C qui bouge.
  H se calcule au bit 11 (retenue entre les deux quartets hauts du mot), C au
  bit 15. N est effacé.
  """
  @spec add16(0..0xFFFF, 0..0xFFFF, byte8()) :: {0..0xFFFF, byte8()}
  def add16(hl, value, f) do
    sum = hl + value
    half = if (hl &&& 0x0FFF) + (value &&& 0x0FFF) > 0x0FFF, do: @h, else: 0
    carry = if sum > 0xFFFF, do: @c, else: 0
    {sum &&& 0xFFFF, (f &&& @z) ||| half ||| carry}
  end

  @doc """
  ADD SP, r8 et LD HL, SP+r8 — l'addition d'offset signé à SP.

  Les drapeaux les plus contre-intuitifs du processeur : opération 16 bits,
  drapeaux calculés **sur l'octet bas comme une addition 8 bits non signée** —
  H au bit 3, C au bit 7 — et Z toujours effacé, même quand le résultat est
  nul. L'offset est signé pour le résultat, non signé pour les drapeaux.
  """
  @spec add_sp(0..0xFFFF, byte8()) :: {0..0xFFFF, byte8()}
  def add_sp(sp, offset) do
    half = if (sp &&& 0x0F) + (offset &&& 0x0F) > 0x0F, do: @h, else: 0
    carry = if (sp &&& 0xFF) + offset > 0xFF, do: @c, else: 0
    signed = offset - bsl(bsr(offset, 7), 8)
    {sp + signed &&& 0xFFFF, half ||| carry}
  end

  # ── Opérations sur l'accumulateur seul (colonne z=7 de la table) ────────────
  #
  # Toutes de signature `(a, f) → {a, f}`, même celles qui n'utilisent pas l'un
  # des deux : l'uniformité permet au générateur de les traiter en une seule
  # clause.

  @doc """
  RLCA — rotation circulaire gauche de A. C reçoit l'ancien bit 7.

  Z est **toujours effacé**, même si le résultat est nul — contrairement au
  `RLC A` de la table CB, qui pose Z normalement. Deux instructions, deux
  encodages, deux sémantiques de Z : classique source de confusion.
  """
  @spec rlca(byte8(), byte8()) :: result()
  def rlca(a, _f) do
    bit7 = bsr(a, 7)
    {(bsl(a, 1) ||| bit7) &&& 0xFF, bit7 * @c}
  end

  @doc "RRCA — rotation circulaire droite. C reçoit l'ancien bit 0, Z effacé."
  @spec rrca(byte8(), byte8()) :: result()
  def rrca(a, _f) do
    bit0 = a &&& 1
    {bsr(a, 1) ||| bsl(bit0, 7), bit0 * @c}
  end

  @doc "RLA — rotation gauche à travers C : C entre par le bit 0, sort du bit 7."
  @spec rla(byte8(), byte8()) :: result()
  def rla(a, f) do
    {(bsl(a, 1) ||| carry_in(f)) &&& 0xFF, bsr(a, 7) * @c}
  end

  @doc "RRA — rotation droite à travers C."
  @spec rra(byte8(), byte8()) :: result()
  def rra(a, f) do
    {bsr(a, 1) ||| bsl(carry_in(f), 7), (a &&& 1) * @c}
  end

  @doc """
  DAA — ajustement décimal après une opération BCD.

  L'instruction la plus tordue du processeur, et la raison d'être des drapeaux
  N et H posés soigneusement partout ailleurs : DAA est leur *seul* lecteur.
  Après une addition (N=0), on ré-ajoute 0x06 et/ou 0x60 selon H, C et la
  valeur ; après une soustraction (N=1), on retranche selon H et C seuls — la
  valeur de A n'entre pas en compte, c'est ainsi. C n'est **jamais effacé** par
  DAA, seulement posé.
  """
  @spec daa(byte8(), byte8()) :: result()
  def daa(a, f) do
    n = (f &&& @n) != 0
    h = (f &&& @h) != 0
    c = (f &&& @c) != 0

    {a, c} =
      if n do
        low = if h, do: 0x06, else: 0
        high = if c, do: 0x60, else: 0
        {a - low - high &&& 0xFF, c}
      else
        low = if h or (a &&& 0x0F) > 0x09, do: 0x06, else: 0
        high = if c or a > 0x99, do: 0x60, else: 0
        {a + low + high &&& 0xFF, c or high > 0}
      end

    {a, zero(a) ||| if(n, do: @n, else: 0) ||| if(c, do: @c, else: 0)}
  end

  @doc "CPL — complément de A. Pose N et H, préserve Z et C."
  @spec cpl(byte8(), byte8()) :: result()
  def cpl(a, f) do
    {bxor(a, 0xFF), (f &&& (@z ||| @c)) ||| @n ||| @h}
  end

  @doc "SCF — pose C. Efface N et H, préserve Z. A inchangé."
  @spec scf(byte8(), byte8()) :: result()
  def scf(a, f), do: {a, (f &&& @z) ||| @c}

  @doc "CCF — inverse C. Efface N et H, préserve Z. A inchangé."
  @spec ccf(byte8(), byte8()) :: result()
  def ccf(a, f), do: {a, (f &&& @z) ||| bxor(f &&& @c, @c)}

  # ── Drapeaux ────────────────────────────────────────────────────────────────

  # La retenue entrante, ramenée à 0 ou 1.
  defp carry_in(f), do: bsr(f &&& @c, 4)

  defp add_flags(a, value, carry, sum) do
    # La retenue entrante participe à la demi-retenue — voir le moduledoc.
    half = if (a &&& 0x0F) + (value &&& 0x0F) + carry > 0x0F, do: @h, else: 0
    full = if sum > 0xFF, do: @c, else: 0
    zero(sum) ||| half ||| full
  end

  defp sub_flags(a, value, carry) do
    # En soustraction, H et C signalent un *emprunt* : le demi-octet, puis
    # l'octet, passent sous zéro. L'emprunt entrant s'ajoute au soustracteur.
    half = if (a &&& 0x0F) < (value &&& 0x0F) + carry, do: @h, else: 0
    full = if a < value + carry, do: @c, else: 0
    zero(a - value - carry) ||| @n ||| half ||| full
  end

  # `result` peut être négatif : `&&& 0xFF` en prend le complément à deux, ce
  # qui est exactement l'octet que le matériel aurait produit.
  defp zero(result), do: if((result &&& 0xFF) == 0, do: @z, else: 0)
end
