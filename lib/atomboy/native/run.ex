defmodule Atomboy.Native.Run do
  @moduledoc """
  Exécuter du SM83 en natif, vu d'Elixir.

  La même signature que `Atomboy.CPU.Loop.run/4`, à la mémoire près — le natif
  ne connaît qu'un espace d'adressage plat de 64 Ko, sans la superposition
  ROM + écritures que la boucle Elixir traîne pour rester immuable.

  C'est volontairement le seul point de contact : tout ce qui est au-dessus
  (tests d'équivalence, rejeu de vecteurs, mesures) passe par ici et ignore
  qu'il y a une image, un qemu et un port série au milieu.
  """

  import Bitwise

  alias Atomboy.CPU.State
  alias Atomboy.Native.Interp
  alias Atomboy.Native.Qemu

  @memoire 0x10000

  @typedoc "Ce que l'invité rapporte."
  @type resultat :: %{
          state: State.t(),
          memoire: binary(),
          cycles: non_neg_integer(),
          statut: :ok | :opcode_inconnu,
          opcode: 0..0xFF,
          instret: non_neg_integer(),
          duration_us: non_neg_integer(),
          taille: non_neg_integer()
        }

  @doc """
  Exécute `budget` T-cycles depuis `state`, sur une mémoire plate de 64 Ko.

  Rend `{:ok, resultat}`, ou `{:error, raison}` si qemu n'a pas rendu la main ou
  si le flux série est illisible — deux pannes qu'il vaut mieux distinguer d'un
  désaccord avec l'oracle.
  """
  @spec run(binary(), State.t(), pos_integer(), keyword()) :: {:ok, resultat()} | {:error, term()}
  def run(memoire, %State{} = state, budget, opts \\ []) when byte_size(memoire) == @memoire do
    image = Interp.image(memoire, state, budget)

    case Qemu.run(image.code, opts) do
      %{status: :timeout, duration_us: us} ->
        {:error, {:timeout, us}}

      %{status: :ok, serial: serial, duration_us: us} ->
        decode(serial, us, image.size)
    end
  end

  @doc """
  Le même appel, mais qui lève sur une panne de harnais.

  Dans un test, un qemu qui boucle n'est pas un résultat à comparer : c'est un
  échec, et il doit le dire tout de suite.
  """
  @spec run!(binary(), State.t(), pos_integer(), keyword()) :: resultat()
  def run!(memoire, state, budget, opts \\ []) do
    case run(memoire, state, budget, opts) do
      {:ok, resultat} -> resultat
      {:error, raison} -> raise "l'invité n'a rien rendu d'exploitable : #{inspect(raison)}"
    end
  end

  defp decode(serial, duration_us, taille) do
    magic = Interp.magic()

    case serial do
      <<^magic, a, f, b, c, d, e, h, l, sp::16-little, pc::16-little, control, cycles::32-little,
        statut, opcode, instret::32-little, memoire::binary-size(@memoire)>> ->
        {:ok,
         %{
           state: %State{
             a: a,
             f: f,
             b: b,
             c: c,
             d: d,
             e: e,
             h: h,
             l: l,
             sp: sp,
             pc: pc,
             ime: control &&& 1,
             halted: (control &&& 2) != 0,
             ime_pending: control >>> 2 &&& 1
           },
           memoire: memoire,
           cycles: cycles,
           statut: statut(statut),
           opcode: opcode,
           instret: instret,
           duration_us: duration_us,
           taille: taille
         }}

      autre ->
        {:error,
         {:flux_illisible, byte_size(autre), binary_part(autre, 0, min(32, byte_size(autre)))}}
    end
  end

  defp statut(code) do
    Enum.find_value(Interp.statuts(), :inconnu, fn {nom, valeur} -> valeur == code && nom end)
  end
end
