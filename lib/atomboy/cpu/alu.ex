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
