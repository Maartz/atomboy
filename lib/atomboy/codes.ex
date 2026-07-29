defmodule Atomboy.Codes do
  @moduledoc """
  Les codes GameShark : des pokes mémoire appliqués à chaque frame.

  Le format classique tient en huit chiffres hexadécimaux — `01VVLLHH` :
  type `01` (écriture huit bits), la valeur `VV`, puis l'adresse en
  petit-boutiste (`LLHH` → `0xHHLL`). `01FF16D1` écrit `0xFF` à `0xD116`
  à chaque frame — c'est tout le secret des vies infinies.

  Les codes actifs vivent dans la map mémoire (`ram[:codes]`, liste
  d'écritures analysées) : ils voyagent avec les états sauvés, et les
  trois boucles de jeu appellent `applique/1` avant chaque frame — le
  GameShark réel écrivait au vblank, même cadence. Les pokes passent par
  `CartLoop.poke/3` : banques et écho servis, SRAM verrouillée respectée.

  Seul le type `01` est accepté — les types bancaires (`9x`) attendront
  un jeu qui les exige. Un code invalide est simplement ignoré, signalé
  sur stderr : un GameShark aux contacts sales, pas une panne.
  """

  import Bitwise

  alias Atomboy.CPU.CartLoop

  @type écriture :: {addr :: 0x8000..0xFFFF, valeur :: 0..0xFF}

  @doc """
  Analyse un code `01VVLLHH`. `{:ok, {adresse, valeur}}`, ou `:error`.
  """
  @spec parse(String.t()) :: {:ok, écriture()} | :error
  def parse(<<code::binary-size(8)>>) do
    with {:ok, <<0x01, valeur, bas, haut>>} <- Base.decode16(String.upcase(code)),
         addr = bsl(haut, 8) ||| bas,
         true <- addr >= 0x8000 do
      {:ok, {addr, valeur}}
    else
      _ -> :error
    end
  end

  def parse(_), do: :error

  @doc """
  Analyse une liste séparée par des virgules — les codes invalides sont
  ignorés et signalés. Rend la liste d'écritures.
  """
  @spec analyse(String.t()) :: [écriture()]
  def analyse(chaîne) do
    chaîne
    |> String.split([",", " ", "\n"], trim: true)
    |> Enum.flat_map(fn code ->
      case parse(code) do
        {:ok, écriture} ->
          [écriture]

        :error ->
          IO.puts(:stderr, "code GameShark ignoré : #{code}")
          []
      end
    end)
  end

  @doc """
  Pose les codes dans la map — `ram[:codes]`, remplacement complet. Une
  liste vide efface la clé : zéro coût par frame sans codes.
  """
  @spec installe(map(), [écriture()]) :: map()
  def installe(ram, []), do: Map.delete(ram, :codes)
  def installe(ram, écritures), do: Map.put(ram, :codes, écritures)

  @doc "Applique les codes actifs — un poke par code, chaque frame."
  @spec applique(map()) :: map()
  def applique(ram) do
    case Map.get(ram, :codes) do
      nil ->
        ram

      écritures ->
        Enum.reduce(écritures, ram, fn {addr, valeur}, ram ->
          CartLoop.poke(ram, addr, valeur)
        end)
    end
  end
end
