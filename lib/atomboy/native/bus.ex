defmodule Atomboy.Native.Bus do
  @moduledoc """
  Les accès mémoire, isolés — la couture où la cartouche entrera un jour.

  `Atomboy.CPU.Loop` et `Atomboy.CPU.CartLoop` sortent du même générateur et ne
  diffèrent **que** par leurs deux fonctions d'accès mémoire : l'une voit un
  espace plat de 64 Ko, l'autre y greffe les banques MBC, la RAM de sauvegarde
  et les registres d'entrée-sortie. Ce module est l'équivalent natif de cette
  frontière, et il existe dès maintenant pour la même raison — le jour où le
  natif devra parler à une vraie cartouche, c'est le seul fichier qui grossira.

  Aujourd'hui il ne fait rien d'autre qu'ajouter la base des 64 Ko à une adresse
  de 16 bits. C'est précisément ce qu'on veut : la mémoire plate est le contrat
  que les vecteurs SM83 valident.

  ## Le registre d'adresse

  `t1` sert de temporaire à chaque accès. Un appelant peut donc y placer
  l'adresse elle-même — `add t1, mem, t1` reste correct — mais ne doit rien y
  garder à travers un accès.
  """

  alias Atomboy.Native.Asm
  alias Atomboy.Native.Regs
  alias Atomboy.Native.RV32

  @doc "Lit l'octet à `adresse` dans `dest`."
  @spec lire(RV32.reg(), RV32.reg()) :: [Asm.item()]
  def lire(adresse, dest) do
    [
      RV32.add(:t1, Regs.mem(), adresse),
      RV32.lbu(dest, :t1, 0)
    ]
  end

  @doc "Écrit `source` à `adresse`. Seuls les huit bits bas partent — `sb` s'en charge."
  @spec ecrire(RV32.reg(), RV32.reg()) :: [Asm.item()]
  def ecrire(adresse, source) do
    [
      RV32.add(:t1, Regs.mem(), adresse),
      RV32.sb(source, :t1, 0)
    ]
  end

  @doc """
  Lit le mot de deux octets à `adresse`, petit-boutien, dans `dest`.

  L'octet haut est à `adresse + 1` **replié sur 16 bits** : une pile posée à
  `0xFFFF` reprend son octet haut à l'adresse 0, et le matériel fait exactement
  cela. Écrase `t1`, `t2` et `t3` ; `dest` ne doit être aucun des trois.
  """
  @spec lire16(RV32.reg(), RV32.reg()) :: [Asm.item()]
  def lire16(adresse, dest) do
    [
      RV32.add(:t1, Regs.mem(), adresse),
      RV32.lbu(dest, :t1, 0),
      suivante(adresse),
      RV32.add(:t1, Regs.mem(), :t3),
      RV32.lbu(:t2, :t1, 0),
      RV32.slli(:t2, :t2, 8),
      RV32.or_(dest, dest, :t2)
    ]
  end

  @doc """
  Écrit `source` sur deux octets à `adresse`, octet bas d'abord.

  Même repli à 16 bits que `lire16/2`, et `adresse` en ressort intacte — ce qui
  compte pour `PUSH`, dont l'adresse est SP lui-même.
  """
  @spec ecrire16(RV32.reg(), RV32.reg()) :: [Asm.item()]
  def ecrire16(adresse, source) do
    [
      RV32.add(:t1, Regs.mem(), adresse),
      RV32.sb(source, :t1, 0),
      suivante(adresse),
      RV32.add(:t1, Regs.mem(), :t3),
      RV32.srli(:t2, source, 8),
      RV32.sb(:t2, :t1, 0)
    ]
  end

  defp suivante(adresse) do
    [
      RV32.addi(:t3, adresse, 1),
      RV32.and_(:t3, :t3, Regs.mask16())
    ]
  end

  @doc """
  Déplace SP de `delta`, replié sur 16 bits — le geste commun à la pile.
  """
  @spec deplacer_pile(integer()) :: [Asm.item()]
  def deplacer_pile(delta) do
    [
      RV32.addi(Regs.sp(), Regs.sp(), delta),
      RV32.and_(Regs.sp(), Regs.sp(), Regs.mask16())
    ]
  end

  @doc """
  Compose dans `dest` l'adresse désignée par une paire indirecte.

  Pour `HL` c'est une copie, et c'est là que le choix d'empaqueter HL dans un
  seul registre 16 bits se paie : la forme séparée demanderait un décalage et un
  ou logique à chaque `(HL)`, c'est-à-dire sur une colonne entière de la table
  plus l'intégralité du bloc CB.
  """
  @spec adresse({:ind, atom()} | :hl_ind, RV32.reg()) :: [Asm.item()]
  def adresse(:hl_ind, dest), do: [RV32.mv(dest, Regs.hl())]
  def adresse({:ind, hl}, dest) when hl in [:hl_inc, :hl_dec], do: [RV32.mv(dest, Regs.hl())]
  def adresse({:ind, :bc}, dest), do: paire(Regs.b(), Regs.c(), dest)
  def adresse({:ind, :de}, dest), do: paire(Regs.d(), Regs.e(), dest)

  defp paire(haut, bas, dest) do
    [
      RV32.slli(dest, haut, 8),
      RV32.or_(dest, dest, bas)
    ]
  end

  @doc """
  L'ajustement de HL que traînent `LD (HL+), A` et `LD (HL-), A`.

  Il vient **après** l'accès : l'adresse est celle d'avant l'incrément.
  """
  @spec ajuster({:ind, atom()}) :: [Asm.item()]
  def ajuster({:ind, :hl_inc}), do: pas(1)
  def ajuster({:ind, :hl_dec}), do: pas(-1)
  def ajuster({:ind, _}), do: []

  defp pas(delta) do
    [
      RV32.addi(Regs.hl(), Regs.hl(), delta),
      RV32.and_(Regs.hl(), Regs.hl(), Regs.mask16())
    ]
  end

  @doc """
  L'adresse de la page haute : `0xFF00 + offset`.

  `0xFF00` ne tient pas dans un immédiat de 12 bits, mais retrancher 256 puis
  replier sur 16 bits donne exactement le même résultat pour un offset d'un
  octet — deux instructions au lieu de trois.
  """
  @spec page_haute(RV32.reg(), RV32.reg()) :: [Asm.item()]
  def page_haute(offset, dest) do
    [
      RV32.addi(dest, offset, -256),
      RV32.and_(dest, dest, Regs.mask16())
    ]
  end
end
