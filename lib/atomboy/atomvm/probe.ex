defmodule Atomboy.AtomVM.Probe do
  @moduledoc """
  Sonde de mesure : la boucle CPU **sans aucune map sur le chemin chaud**.

  Ce module ne préfigure pas l'architecture — c'est un instrument, à jeter. Il
  existe pour répondre à une seule question, chiffrée sur AtomVM natif :
  combien vaut la boucle quand on enlève ce que le JIT ne sait pas accélérer ?

  La mesure de référence a montré le problème : l'AOT natif ne gagne que ×1,21
  sur l'interprété, parce que chaque pas passe par des BIFs de map — fetch dans
  `Atomboy.Memory.Flat`, mise à jour du struct `State` — que la compilation
  native ne touche pas. Loi d'Amdahl : tant que 85 % du temps est dans les
  maps, aucun backend ne peut faire mieux que ×1,2.

  Ici, les deux sources de BIFs disparaissent :

    * **Les registres voyagent en arguments de fonction.** Dans du code natif,
      les registres x de la BEAM deviennent des registres machine. C'est le
      design `exec/13` d'origine, ressuscité là où il compte — la boucle
      interne — et invisible de l'extérieur.
    * **La ROM est une binary de 64 Ko**, fetch par `:binary.at/2`. Pas de
      hachage, pas d'allocation, et c'est déjà le modèle cible : la vraie ROM
      Game Boy est immuable par définition.

  Les écritures mémoire restent dans une map threadée en argument : le
  programme mesuré n'écrit qu'une fois par tour d'espace d'adressage, le coût
  est invisible. Le jour venu, ce sera la resource NIF du brief.

  Le programme est le même que celui de `Atomboy.AtomVM.Main` — LD B,C ;
  LD (HL),B ; LD A,(HL) ; NOP, puis des NOP jusqu'au bouclage de PC — pour que
  les deux chiffres soient comparables terme à terme.
  """

  import Bitwise

  @steps 1_000_000

  @doc "Construit la ROM : le programme de Main, puis des NOP jusqu'à 64 Ko."
  @spec rom() :: binary()
  def rom do
    <<0x41, 0x70, 0x7E, 0x00>> <> :binary.copy(<<0x00>>, 0x10000 - 4)
  end

  @doc """
  Mesure `#{@steps}` pas et affiche le débit, comme le bench de Main.
  """
  @spec bench() :: :ok
  def bench do
    rom = rom()

    # Chauffe courte, comme le bench de référence.
    loop(rom, %{}, 1_000, 0, 0, 0, 0, 0x42, 0, 0, 0xC0, 0x00, 0xFFFE, 0x0000)

    t0 = :erlang.monotonic_time(:millisecond)
    loop(rom, %{}, @steps, 0, 0, 0, 0, 0x42, 0, 0, 0xC0, 0x00, 0xFFFE, 0x0000)
    elapsed = :erlang.monotonic_time(:millisecond) - t0

    per_second = if elapsed > 0, do: div(@steps * 1000, elapsed), else: :too_fast

    :erlang.display({:probe_steps, @steps})
    :erlang.display({:probe_elapsed_ms, elapsed})
    :erlang.display({:probe_instructions_per_second, per_second})
    :ok
  end

  # La boucle : fetch binaire, dispatch, appel terminal — registres en
  # arguments d'un bout à l'autre, aucune structure construite.
  defp loop(_rom, _ram, 0, cycles, _a, _f, _b, _c, _d, _e, _h, _l, _sp, _pc), do: cycles

  defp loop(rom, ram, steps, cycles, a, f, b, c, d, e, h, l, sp, pc) do
    case :binary.at(rom, pc) do
      # NOP
      0x00 ->
        loop(rom, ram, steps - 1, cycles + 4, a, f, b, c, d, e, h, l, sp, pc + 1 &&& 0xFFFF)

      # LD B, C
      0x41 ->
        loop(rom, ram, steps - 1, cycles + 4, a, f, c, c, d, e, h, l, sp, pc + 1 &&& 0xFFFF)

      # LD (HL), B
      0x70 ->
        ram = Map.put(ram, bsl(h, 8) ||| l, b)
        loop(rom, ram, steps - 1, cycles + 8, a, f, b, c, d, e, h, l, sp, pc + 1 &&& 0xFFFF)

      # LD A, (HL)
      0x7E ->
        addr = bsl(h, 8) ||| l
        value = Map.get(ram, addr, :binary.at(rom, addr))
        loop(rom, ram, steps - 1, cycles + 8, value, f, b, c, d, e, h, l, sp, pc + 1 &&& 0xFFFF)
    end
  end
end
