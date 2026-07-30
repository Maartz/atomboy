defmodule Atomboy.Native.Emit do
  @moduledoc """
  Le troisième backend : un `%Insn{}` devient des instructions RISC-V.

  `Atomboy.CPU.Gen` en a deux — l'oracle à struct et la boucle rapide — qui
  produisent tous deux de l'AST Elixir. Celui-ci produit des octets. Les trois
  filtrent sur les mêmes motifs de `%Atomboy.CPU.Insn{}`, lus dans la même
  table, et c'est là que tient la propriété qui compte : une famille d'opérandes
  n'est décrite qu'une fois.

  ## Pourquoi ce module n'est pas une troisième famille dans `gen.ex`

  `gen.ex` fait déjà 1500 lignes pour deux émetteurs qui rendent de l'AST. Un
  troisième, dont les corps sont trois à cinq fois plus longs et rendent des
  binaires, en ferait un fichier que personne ne relit. Ce qui garantit qu'aucun
  backend ne rate une famille n'est de toute façon pas la proximité dans un
  fichier : c'est que les trois filtrent sur les mêmes têtes de clause, et que
  `couverture/0` dit lesquelles manquent encore ici.

  L'ordre des clauses de ce module recopie délibérément celui de `gen.ex`. Une
  divergence d'ordre est une divergence de sémantique quand deux motifs se
  chevauchent.

  ## Ce qui est couvert aujourd'hui

  L'étape 1 du chantier : `NOP` et les 49 `LD r, r'` de registre à registre.
  Aucun accès mémoire hors le fetch, aucun drapeau, aucun branchement — juste
  assez pour qu'un vrai vecteur SM83 franchisse toute la chaîne et se compare à
  l'oracle. Le reste de la table tombe dans `:non_supporté` et le dispatch y
  envoie `opcode_inconnu`.
  """

  alias Atomboy.CPU.Insn
  alias Atomboy.CPU.Table
  alias Atomboy.Native.Asm
  alias Atomboy.Native.RV32
  alias Atomboy.Native.Regs

  @doc """
  Le corps d'un gestionnaire d'opcode, ou `:non_supporté`.

  Le corps se termine toujours par la comptabilisation des cycles et un saut
  vers `fetch` — l'équivalent natif de l'appel terminal de `Gen.loop_ret/3`.
  """
  @spec body(Insn.t()) :: [Asm.item()] | :non_supporté

  # NOP — l'instruction qui ne fait que passer du temps.
  def body(%Insn{mnemonic: :nop, cycles: cycles}), do: fin(cycles)

  # LD r, r' — la moitié de la table, et la seule famille sans aucun effet de
  # bord. `LD B, B` s'émet comme les autres : élider serait une optimisation, et
  # les optimisations viennent après la mesure.
  def body(%Insn{mnemonic: :ld, operands: [{:reg, dst}, {:reg, src}], cycles: cycles}) do
    Regs.read8({:reg, src}, :t0) ++ Regs.write8({:reg, dst}, :t0) ++ fin(cycles)
  end

  def body(%Insn{}), do: :non_supporté

  @doc """
  La fin de tout gestionnaire : les cycles, puis le fetch suivant.

  Tous les coûts de la table valent 24 T ou moins, donc l'immédiat d'`addi` les
  accepte sans détour.
  """
  @spec fin(pos_integer()) :: [Asm.item()]
  def fin(cycles) do
    [RV32.addi(Regs.cycles(), Regs.cycles(), cycles), Asm.j(:fetch)]
  end

  @doc """
  Les instructions que ce backend sait émettre, par `{préfixe, opcode}`.

  Même forme que `Atomboy.CPU.implemented/0`, pour que les tests puissent
  restreindre un programme aléatoire à ce qui est couvert des deux côtés.
  """
  @spec couverture() :: [{nil | :cb, 0..0xFF}]
  def couverture do
    for insn <- Table.all(), body(insn) != :non_supporté, do: {insn.prefix, insn.opcode}
  end

  @doc "Les instructions encore à faire — le tableau de bord du chantier."
  @spec restant() :: [{nil | :cb, 0..0xFF}]
  def restant do
    for insn <- Table.all(), body(insn) == :non_supporté, do: {insn.prefix, insn.opcode}
  end
end
