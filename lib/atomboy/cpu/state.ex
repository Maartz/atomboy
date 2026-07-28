defmodule Atomboy.CPU.State do
  @moduledoc """
  L'état du CPU SM83.

  Les huit registres 8 bits, les deux registres 16 bits, et l'état
  d'interruption — en un seul terme nommé.

  ## Registres

  `a` et `f` (accumulateur et drapeaux), `b`, `c`, `d`, `e`, `h`, `l`, plus `sp`
  (pointeur de pile) et `pc` (compteur ordinal). Le SM83 les apparie en 16 bits
  — `AF`, `BC`, `DE`, `HL` — mais l'accès 8 bits est de loin le plus fréquent,
  donc ils sont stockés séparés et recomposés au besoin.

  ## Interruptions

  `ime` est le drapeau maître d'autorisation ; `ie` est en réalité le registre
  mémoire 0xFFFF, dupliqué ici parce que les vecteurs SingleStepTests le
  fournissent à part. `halted` retient l'effet de `HALT`.

  ## Le registre F

  Les drapeaux sont conservés **compactés** dans l'octet `f` — Z en bit 7, N en
  6, H en 5, C en 4, les quatre bits de poids faible toujours à zéro. C'est la
  représentation du matériel, celle des vecteurs de test, et celle qu'exigent
  `PUSH AF` / `POP AF`.

  Les garder dépliés en quatre booléens irait plus vite sur le code
  arithmétique, mais imposerait un recompactage à chaque accès à `AF` et un
  écart permanent entre l'état interne et ce que les vecteurs affirment. À
  revoir si le profil le réclame ; pas avant.
  """

  @type t :: %__MODULE__{
          a: 0..0xFF,
          f: 0..0xFF,
          b: 0..0xFF,
          c: 0..0xFF,
          d: 0..0xFF,
          e: 0..0xFF,
          h: 0..0xFF,
          l: 0..0xFF,
          sp: 0..0xFFFF,
          pc: 0..0xFFFF,
          ime: 0..1,
          ime_pending: 0..1,
          ie: 0..0xFF,
          halted: boolean()
        }

  defstruct a: 0x00,
            f: 0x00,
            b: 0x00,
            c: 0x00,
            d: 0x00,
            e: 0x00,
            h: 0x00,
            l: 0x00,
            sp: 0x0000,
            pc: 0x0000,
            ime: 0,
            ime_pending: 0,
            ie: 0x00,
            halted: false

  import Bitwise

  @flags [z: 0x80, n: 0x40, h: 0x20, c: 0x10]

  @doc """
  Les drapeaux positionnés, sous forme de liste d'atomes.

      iex> Atomboy.CPU.State.flags(%Atomboy.CPU.State{f: 0xB0})
      [:z, :h, :c]

  Pour l'inspection et les messages d'erreur : `f: 176` n'apprend rien.
  """
  @spec flags(t()) :: [:z | :n | :h | :c]
  def flags(%__MODULE__{f: f}) do
    for {flag, bit} <- @flags, (f &&& bit) != 0, do: flag
  end

  @doc """
  Les drapeaux épelés, un caractère par bit dans l'ordre Z N H C.

      iex> Atomboy.CPU.State.flag_string(%Atomboy.CPU.State{f: 0xB0})
      "Z-HC"
  """
  @spec flag_string(t()) :: String.t()
  def flag_string(%__MODULE__{f: f}) do
    Enum.map_join(@flags, fn {flag, bit} ->
      if (f &&& bit) != 0 do
        flag |> Atom.to_string() |> String.upcase()
      else
        "-"
      end
    end)
  end

  @doc """
  La paire 16 bits `HL`, l'adresse indirecte la plus utilisée du jeu
  d'instructions.
  """
  @spec hl(t()) :: 0..0xFFFF
  def hl(%__MODULE__{h: h, l: l}), do: bsl(h, 8) ||| l
end
