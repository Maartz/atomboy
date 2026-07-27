defmodule Atomboy.CPU.ALU do
  @moduledoc """
  Les huit opérations arithmétiques et logiques du SM83, avec leurs drapeaux.

  Écrites à la main, pas générées. `Atomboy.CPU.Gen` s'occupe de la *structure*
  — quel opcode appelle quoi sur quel opérande ; la sémantique des drapeaux vit
  ici, en Elixir lisible. Émettre ce calcul sous forme d'AST le rendrait
  illisible précisément là où il faut pouvoir le relire : les drapeaux sont
  l'endroit où les émulateurs se trompent, et où l'erreur reste invisible le
  plus longtemps.

  Ces fonctions sont publiques parce qu'elles ont un second consommateur prévu :
  le code recompilé de la phase 5 appellera les mêmes primitives. La
  recompilation supprime le fetch, le décodage et le dispatch — pas
  l'arithmétique de drapeaux, qu'il n'y a aucune raison de réimplémenter.

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

  alias Atomboy.CPU.State

  @z 0x80
  @n 0x40
  @h 0x20
  @c 0x10

  @doc "ADD A, v — addition."
  @spec add(State.t(), 0..0xFF) :: State.t()
  def add(%State{a: a} = st, value) do
    result = a + value
    %{st | a: result &&& 0xFF, f: add_flags(a, value, 0, result)}
  end

  @doc "ADC A, v — addition avec retenue entrante."
  @spec adc(State.t(), 0..0xFF) :: State.t()
  def adc(%State{a: a, f: f} = st, value) do
    carry = carry_in(f)
    result = a + value + carry
    %{st | a: result &&& 0xFF, f: add_flags(a, value, carry, result)}
  end

  @doc "SUB v — soustraction."
  @spec sub(State.t(), 0..0xFF) :: State.t()
  def sub(%State{a: a} = st, value) do
    %{st | a: a - value &&& 0xFF, f: sub_flags(a, value, 0)}
  end

  @doc "SBC A, v — soustraction avec emprunt entrant."
  @spec sbc(State.t(), 0..0xFF) :: State.t()
  def sbc(%State{a: a, f: f} = st, value) do
    carry = carry_in(f)
    %{st | a: a - value - carry &&& 0xFF, f: sub_flags(a, value, carry)}
  end

  @doc """
  CP v — comparaison.

  Une soustraction dont le résultat est jeté : seuls les drapeaux subsistent.
  D'où la réutilisation de `sub_flags/3` — dupliquer le calcul reviendrait à
  entretenir deux fois la même subtilité d'emprunt.
  """
  @spec cp(State.t(), 0..0xFF) :: State.t()
  def cp(%State{a: a} = st, value), do: %{st | f: sub_flags(a, value, 0)}

  @doc """
  AND v — et logique.

  Seule opération logique à poser `H`. Ce n'est pas une régularité oubliée,
  c'est ainsi sur le matériel.
  """
  @spec bit_and(State.t(), 0..0xFF) :: State.t()
  def bit_and(%State{a: a} = st, value) do
    result = a &&& value
    %{st | a: result, f: zero(result) ||| @h}
  end

  @doc "XOR v — ou exclusif. Tous les drapeaux sauf Z sont remis à zéro."
  @spec bit_xor(State.t(), 0..0xFF) :: State.t()
  def bit_xor(%State{a: a} = st, value) do
    result = bxor(a, value)
    %{st | a: result, f: zero(result)}
  end

  @doc "OR v — ou logique. Tous les drapeaux sauf Z sont remis à zéro."
  @spec bit_or(State.t(), 0..0xFF) :: State.t()
  def bit_or(%State{a: a} = st, value) do
    result = a ||| value
    %{st | a: result, f: zero(result)}
  end

  # ── Drapeaux ────────────────────────────────────────────────────────────────

  # La retenue entrante, ramenée à 0 ou 1.
  defp carry_in(f), do: bsr(f &&& @c, 4)

  defp add_flags(a, value, carry, result) do
    # La retenue entrante participe à la demi-retenue — voir le moduledoc.
    half = if (a &&& 0x0F) + (value &&& 0x0F) + carry > 0x0F, do: @h, else: 0
    full = if result > 0xFF, do: @c, else: 0
    zero(result) ||| half ||| full
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
