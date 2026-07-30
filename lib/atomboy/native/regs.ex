defmodule Atomboy.Native.Regs do
  @moduledoc """
  Où vit chaque registre du SM83, dans les 32 registres du RISC-V.

  Le seul module qui le sache. Tout ce qui est au-dessus dit `read8({:reg, :h},
  :t0)` et ignore que H n'existe pas — qu'il est la moitié haute d'un registre
  qui contient HL.

  ## La ressource rare n'est pas le nombre de registres

  Il y en a 32 pour une quinzaine de besoins. Ce qui est rare, c'est le sous-
  ensemble `x8`-`x15` : une instruction dont tous les opérandes y tombent peut
  se coder sur deux octets au lieu de quatre. On n'émet encore rien de
  compressé (voir `Atomboy.Native.RV32`), mais le jour où l'icache mordra, la
  compression sera gratuite là où les registres chauds auront été placés — et
  hors de prix ailleurs. D'où cette carte, décidée maintenant plutôt que
  regrettée plus tard.

  ## Trois choix qui ne vont pas de soi

  **`0xFFFF` occupe un registre entier.** `andi` ne prend qu'un immédiat signé
  sur 12 bits : masquer un octet est gratuit, masquer 16 bits est impossible.
  Sans registre dédié, chaque repli — PC, SP, HL, toute adresse — coûterait
  deux instructions au lieu d'une.

  **HL est empaqueté, B/C/D/E restent séparés.** Asymétrie délibérée avec les
  backends Elixir, et le seul endroit où le natif ne doit pas les imiter. HL
  sert d'adresse bien plus souvent que de deux octets : chaque opérande `(HL)`
  devient une addition, là où la forme séparée demanderait un décalage, un ou
  logique et une addition. B, C, D et E vont dans l'autre sens — presque
  toujours lus en octets, leurs formes par paires sont les rares.

  **F reste empaqueté en bits 7-4.** Le dépaqueter casserait `PUSH AF`, `DAA`,
  et surtout le contrat 1:1 avec `Atomboy.CPU.ALU` dont dépendra le test
  différentiel exhaustif des drapeaux.
  """

  alias Atomboy.Native.RV32

  @map [
    a: :s0,
    f: :s1,
    b: :a6,
    c: :a7,
    d: :s2,
    e: :s3,
    hl: :a2,
    sp: :a3,
    pc: :a4,
    mem: :a5,
    cycles: :s4,
    budget: :s5,
    control: :s6,
    dispatch: :s7,
    mask16: :s8,
    opcode: :a1
  ]

  for {role, register} <- @map do
    @doc "Le registre RV32 qui porte #{role}."
    @spec unquote(role)() :: RV32.reg()
    def unquote(role)(), do: unquote(register)
  end

  @doc "La carte complète, pour la documentation et les tests."
  @spec map() :: keyword(RV32.reg())
  def map, do: @map

  @doc """
  Les registres libres pour un gestionnaire d'opcode.

  `a1` porte l'opcode courant jusqu'au bout du gestionnaire — c'est ce qui
  permet à `opcode_inconnu` de dire lequel — et n'est donc pas de la pâture.
  """
  @spec scratch() :: [RV32.reg()]
  def scratch, do: [:t0, :t1, :t2, :a0]

  # ══ Les octets ═══════════════════════════════════════════════════════════════

  @doc """
  Lit un registre 8 bits du SM83 dans `dest`.

  `dest` peut être le registre porteur lui-même : la lecture est alors une
  copie inutile, que l'appelant est libre d'élider.
  """
  @spec read8({:reg, atom()}, RV32.reg()) :: [binary()]
  def read8({:reg, :h}, dest), do: [RV32.srli(dest, hl(), 8)]
  def read8({:reg, :l}, dest), do: [RV32.andi(dest, hl(), 0xFF)]
  def read8({:reg, name}, dest), do: [RV32.mv(dest, direct!(name))]

  @doc """
  Écrit `src` dans un registre 8 bits du SM83.

  `src` doit déjà tenir sur huit bits. Les formes H et L écrasent `t1` et `t2`,
  qui ne doivent donc pas porter `src`.
  """
  @spec write8({:reg, atom()}, RV32.reg()) :: [binary()]
  def write8({:reg, :h}, src) do
    guard!(:h, src, [:t1, :t2])

    [
      RV32.andi(:t1, hl(), 0xFF),
      RV32.slli(:t2, src, 8),
      RV32.or_(hl(), :t1, :t2)
    ]
  end

  def write8({:reg, :l}, src) do
    guard!(:l, src, [:t1])

    # -256 vaut 0xFFFFFF00 une fois sign-étendu : les huit bits bas tombent,
    # tout le reste survit. L'immédiat tient dans les 12 bits signés, là où
    # 0xFF00 n'y tiendrait pas.
    [
      RV32.andi(:t1, hl(), -256),
      RV32.or_(hl(), :t1, src)
    ]
  end

  def write8({:reg, name}, src), do: [RV32.mv(direct!(name), src)]

  defp direct!(name) do
    case Keyword.fetch(@map, name) do
      {:ok, register} ->
        register

      :error ->
        raise ArgumentError,
              "registre SM83 sans porteur direct : #{inspect(name)} — H et L passent par HL"
    end
  end

  defp guard!(name, src, forbidden) do
    if src in forbidden do
      raise ArgumentError,
            "écrire #{String.upcase(to_string(name))} depuis #{src} : ce registre sert de temporaire ici"
    end
  end
end
