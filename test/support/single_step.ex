defmodule Atomboy.SingleStep do
  @moduledoc """
  Rejoue les vecteurs SingleStepTests/sm83 contre `Atomboy.CPU`.

  Chaque vecteur donne un état machine complet avant et après **une** seule
  instruction : les dix registres, IME, IE, et la liste des adresses mémoire
  touchées avec leur contenu. Le harnais reconstruit cet état, exécute un
  `step/3`, et compare champ par champ.

  ## Ce qui est vérifié, et ce qui ne l'est pas

  Vérifiés : les registres, les drapeaux, IME, la mémoire finale sur chaque
  adresse listée, et le **nombre** de cycles.

  Pas vérifié : le journal d'accès bus (`cycles`), qui indique pour chaque
  M-cycle l'adresse touchée et le sens. C'est de la précision cycle-exacte, un
  non-objectif déclaré du projet — mais la donnée est là, et l'assertion tiendra
  en quelques lignes le jour où le PPU exigera de savoir *quand* dans
  l'instruction un accès tombe.
  """

  import Bitwise

  alias Atomboy.CPU.State
  alias Atomboy.Memory.Flat
  alias Mix.Tasks.Atomboy.Corpus

  @typedoc "Un échec : le vecteur fautif et les champs qui divergent."
  @type failure :: %{name: String.t(), diffs: [{atom(), term(), term()}]}

  @doc "Le corpus est-il installé ?"
  @spec corpus?() :: boolean()
  defdelegate corpus?(), to: Corpus, as: :available?

  @doc "Les opcodes dont le corpus fournit un fichier."
  @spec available_opcodes() :: MapSet.t({Atomboy.CPU.prefix(), 0..0xFF})
  defdelegate available_opcodes(), to: Corpus, as: :opcodes

  @doc """
  Rejoue tous les vecteurs d'un opcode.

  Renvoie `{nombre_de_vecteurs, echecs}`. Un opcode juste donne une liste
  d'échecs vide.
  """
  @spec run(Atomboy.CPU.prefix(), 0..0xFF) :: {non_neg_integer(), [failure()]}
  def run(prefix, opcode) do
    vectors = load(prefix, opcode)
    {length(vectors), Enum.flat_map(vectors, &check/1)}
  end

  @doc "Charge et décode le fichier de vecteurs d'un opcode."
  @spec load(Atomboy.CPU.prefix(), 0..0xFF) :: [map()]
  def load(prefix, opcode) do
    Corpus.dir()
    |> Path.join("v1/#{file_name(prefix, opcode)}.json")
    |> File.read!()
    |> JSON.decode!()
  end

  @doc """
  Le nom de fichier d'un opcode. Les opcodes préfixés portent une espace :
  `cb 40.json`.
  """
  @spec file_name(Atomboy.CPU.prefix(), 0..0xFF) :: String.t()
  def file_name(nil, opcode), do: hex(opcode)
  def file_name(:cb, opcode), do: "cb " <> hex(opcode)

  @doc """
  Met en forme un échec pour le rapport de test.

  Le message vise l'usage réel : on regarde ça après avoir écrit une famille
  d'opcodes, avec des dizaines d'échecs corrélés. D'où le comptage global, le
  détail sur un seul vecteur, et les drapeaux épelés — `f: 176 au lieu de 144`
  ne dit rien, `Z-HC au lieu de Z-H-` désigne le bit.
  """
  @spec format_failures(Atomboy.CPU.prefix(), 0..0xFF, non_neg_integer(), [failure()]) ::
          String.t()
  def format_failures(prefix, opcode, total, failures) do
    first = hd(failures)

    diffs =
      Enum.map_join(first.diffs, "\n", fn {field, expected, got} ->
        "      #{field}: attendu #{show(field, expected)}, obtenu #{show(field, got)}"
      end)

    """
    opcode #{file_name(prefix, opcode)} : #{length(failures)}/#{total} vecteurs en échec

      premier échec — vecteur "#{first.name}"
    #{diffs}
    """
  end

  # ── Interne ─────────────────────────────────────────────────────────────────

  defp check(%{"initial" => initial, "final" => final, "cycles" => cycles} = vector) do
    mem = Flat.new(for [addr, value] <- initial["ram"], do: {addr, value})

    {state, mem, t_cycles} = Atomboy.CPU.step(state_from(initial), mem)

    case diff(final, cycles, state, mem, t_cycles) do
      [] -> []
      diffs -> [%{name: vector["name"], diffs: diffs}]
    end
  end

  defp state_from(vector) do
    %State{
      a: vector["a"],
      f: vector["f"],
      b: vector["b"],
      c: vector["c"],
      d: vector["d"],
      e: vector["e"],
      h: vector["h"],
      l: vector["l"],
      sp: vector["sp"],
      pc: vector["pc"],
      ime: vector["ime"],
      ie: vector["ie"] || 0
    }
  end

  defp diff(final, cycles, state, mem, t_cycles) do
    got = Map.take(state, [:a, :f, :b, :c, :d, :e, :h, :l, :sp, :pc, :ime])

    register_diffs =
      for {field, actual} <- got,
          # `ie` et parfois `ime` sont absents de l'état final de certains
          # vecteurs : ce qui n'est pas affirmé n'est pas comparé.
          Map.has_key?(final, Atom.to_string(field)),
          expected = final[Atom.to_string(field)],
          expected != actual,
          do: {field, expected, actual}

    memory_diffs =
      for [addr, expected] <- final["ram"] || [],
          actual = Flat.read8(mem, addr),
          actual != expected,
          do: {:"mem[#{hex16(addr)}]", expected, actual}

    # Un M-cycle du bus vaut 4 T-cycles.
    expected_cycles = length(cycles) * 4

    cycle_diffs =
      if t_cycles == expected_cycles, do: [], else: [{:t_cycles, expected_cycles, t_cycles}]

    Enum.sort(register_diffs) ++ Enum.sort(memory_diffs) ++ cycle_diffs
  end

  defp hex(value),
    do: value |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(2, "0")

  defp hex16(value),
    do: "0x" <> (value |> Integer.to_string(16) |> String.upcase() |> String.pad_leading(4, "0"))

  # Le registre F mérite un traitement à part : c'est le champ qui casse le plus
  # souvent, et sa valeur numérique n'apprend rien.
  defp show(:f, value) do
    flags =
      [{0x80, "Z"}, {0x40, "N"}, {0x20, "H"}, {0x10, "C"}]
      |> Enum.map_join(fn {bit, letter} -> if (value &&& bit) != 0, do: letter, else: "-" end)

    "#{flags} (0x#{hex(value)})"
  end

  defp show(:t_cycles, value), do: "#{value} T"
  defp show(field, value) when field in [:sp, :pc], do: hex16(value)
  defp show(_field, value) when is_integer(value), do: "0x#{hex(value)}"
  defp show(_field, value), do: inspect(value)
end
