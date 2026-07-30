defmodule Atomboy.Native.Asm do
  @moduledoc """
  Étiquettes, renvois avant, et la passe qui comble les trous.

  `Atomboy.Native.RV32` encode une instruction dont tous les opérandes sont
  connus. Un interpréteur n'en produit presque aucune de ce genre : `j fetch`
  saute vers une étiquette dont l'adresse dépend de tout ce qui sera émis après.
  Ce module est la couche qui manque — et elle est petite, parce qu'une seule
  règle la garde petite.

  ## La règle : aucune taille ne dépend d'une distance

  Rien n'est compressé (voir `Atomboy.Native.RV32`), donc chaque élément connaît
  sa taille avant que la moindre adresse ne soit résolue. La passe 1 parcourt les
  éléments en sommant les tailles et note où tombe chaque étiquette ; la passe 2
  repasse et émet les octets, les trous étant comblés avec les distances qu'on
  connaît désormais.

  Sans cette règle il faudrait un point fixe : un branchement lointain occupe
  plus de place, ce qui éloigne les cibles suivantes, ce qui allonge d'autres
  branchements. C'est le problème de la relaxation, et il vaut cent fois son prix
  en octets tant que le code tient dans l'icache.

  L'invariant qui verrouille tout cela — *le nombre d'octets émis en passe 2 est
  exactement la taille calculée en passe 1* — est vérifié à chaque assemblage,
  pas seulement dans les tests. Une régression de taille est le genre de bug qui
  produit du code qui s'exécute et donne de mauvais résultats.

  ## Les éléments

      binary                    des octets déjà encodés — instruction ou donnée
      {:label, nom}             taille nulle ; définit une adresse
      {:align, n}               bourrage de zéros jusqu'au multiple de n
      {:ref, nom, encodeur}     4 octets, comblés par `encodeur.(distance)`
      {:addr, nom}              4 octets : l'adresse absolue de l'étiquette
      {:space, n}               n octets à zéro

  `{:addr, nom}` est ce qui rend la table de saut possible : 256 mots contenant
  l'adresse de chaque gestionnaire, chargés par un `lw` et suivis d'un `jr`.
  """

  alias Atomboy.Native.RV32

  @typedoc "Un élément d'assemblage."
  @type item ::
          binary()
          | {:label, atom()}
          | {:align, pos_integer()}
          | {:ref, atom(), (integer() -> binary())}
          | {:addr, atom()}
          | {:space, non_neg_integer()}

  @typedoc "Le résultat d'un assemblage : les octets, et où chaque étiquette est tombée."
  @type assembled :: %{
          code: binary(),
          labels: %{atom() => non_neg_integer()},
          size: non_neg_integer()
        }

  @doc """
  Assemble une liste d'éléments en partant de l'adresse `base`.

  `base` est l'adresse à laquelle l'image sera chargée : les `{:addr, _}`
  contiennent des adresses absolues, donc l'assembleur doit la connaître.
  """
  @spec assemble([item()], non_neg_integer()) :: assembled()
  def assemble(items, base \\ 0) do
    items = List.flatten(items)
    {size, labels} = measure(items)
    code = emit(items, base, labels)

    unless byte_size(code) == size do
      raise "assemblage incohérent : passe 1 annonce #{size} octets, passe 2 en a émis #{byte_size(code)}"
    end

    %{code: code, labels: labels, size: size}
  end

  @doc """
  L'adresse absolue d'une étiquette dans un assemblage.
  """
  @spec address(assembled(), atom(), non_neg_integer()) :: non_neg_integer()
  def address(%{labels: labels}, name, base \\ 0) do
    case labels do
      %{^name => offset} -> base + offset
      _ -> raise ArgumentError, "étiquette inconnue : #{inspect(name)}"
    end
  end

  # ══ Passe 1 : les tailles et les étiquettes ══════════════════════════════════

  defp measure(items) do
    Enum.reduce(items, {0, %{}}, fn item, {offset, labels} ->
      case item do
        {:label, name} ->
          if Map.has_key?(labels, name) do
            raise ArgumentError, "étiquette définie deux fois : #{inspect(name)}"
          end

          {offset, Map.put(labels, name, offset)}

        _ ->
          {offset + size(item, offset), labels}
      end
    end)
  end

  defp size(binary, _offset) when is_binary(binary), do: byte_size(binary)
  defp size({:ref, _, _}, _offset), do: 4
  defp size({:addr, _}, _offset), do: 4
  defp size({:space, n}, _offset), do: n
  defp size({:align, n}, offset), do: padding(offset, n)

  defp size(item, _offset) do
    raise ArgumentError, "élément d'assemblage inconnu : #{inspect(item)}"
  end

  defp padding(offset, n) do
    case rem(offset, n) do
      0 -> 0
      r -> n - r
    end
  end

  # ══ Passe 2 : les octets ═════════════════════════════════════════════════════

  defp emit(items, base, labels) do
    {chunks, _offset} =
      Enum.reduce(items, {[], 0}, fn item, {chunks, offset} ->
        case item do
          {:label, _} ->
            {chunks, offset}

          _ ->
            bytes = bytes(item, offset, base, labels)
            {[bytes | chunks], offset + byte_size(bytes)}
        end
      end)

    chunks |> Enum.reverse() |> IO.iodata_to_binary()
  end

  defp bytes(binary, _offset, _base, _labels) when is_binary(binary), do: binary
  defp bytes({:space, n}, _offset, _base, _labels), do: <<0::size(n * 8)>>
  defp bytes({:align, n}, offset, _base, _labels), do: <<0::size(padding(offset, n) * 8)>>

  defp bytes({:addr, name}, _offset, base, labels) do
    <<base + resolve!(labels, name)::32-little>>
  end

  defp bytes({:ref, name, encoder}, offset, _base, labels) do
    encoder.(resolve!(labels, name) - offset)
  end

  defp resolve!(labels, name) do
    case labels do
      %{^name => offset} ->
        offset

      _ ->
        raise ArgumentError,
              "étiquette inconnue : #{inspect(name)} — définies : #{labels |> Map.keys() |> Enum.sort() |> Enum.join(", ")}"
    end
  end

  # ══ Les émetteurs qui visent une étiquette ═══════════════════════════════════

  @doc "Définit une étiquette à la position courante."
  @spec label(atom()) :: item()
  def label(name), do: {:label, name}

  @doc "Un saut inconditionnel vers une étiquette."
  @spec j(atom()) :: item()
  def j(name), do: {:ref, name, &RV32.j/1}

  @doc "Un appel de sous-routine : l'adresse de retour part dans `ra`."
  @spec call(atom()) :: item()
  def call(name), do: {:ref, name, &RV32.jal(:ra, &1)}

  for branch <- [:beq, :bne, :blt, :bge, :bltu, :bgeu] do
    @doc "`#{branch} rs1, rs2, étiquette`"
    @spec unquote(branch)(RV32.reg(), RV32.reg(), atom()) :: item()
    def unquote(branch)(rs1, rs2, name) do
      {:ref, name, &RV32.unquote(branch)(rs1, rs2, &1)}
    end
  end

  @doc "Un branchement si le registre est nul — `beq rs, zero`."
  @spec beqz(RV32.reg(), atom()) :: item()
  def beqz(rs, name), do: beq(rs, :zero, name)

  @doc "Un branchement si le registre est non nul — `bne rs, zero`."
  @spec bnez(RV32.reg(), atom()) :: item()
  def bnez(rs, name), do: bne(rs, :zero, name)
end
