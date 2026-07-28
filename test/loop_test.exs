defmodule Atomboy.CPU.LoopTest do
  @moduledoc """
  Équivalence croisée : la boucle rapide contre l'oracle.

  `Atomboy.CPU.Loop` n'est pas validé par les vecteurs SM83 — il est validé
  par **héritage** : l'oracle passe les vecteurs, et ce test vérifie que la
  boucle produit exactement l'état et la mémoire de l'oracle sur des
  programmes aléatoires. Toute divergence entre les deux émetteurs de `Gen` —
  un drapeau oublié, un cycle mal compté, un opérande inversé — casse ici.

  Le comptage de cycles est vérifié structurellement : le budget donné à
  `run/4` est la somme exacte des cycles de N pas d'oracle. Si la boucle
  comptait différemment, elle exécuterait plus ou moins d'instructions que
  l'oracle, et les états divergeraient.

  Les graines sont fixes : un échec est reproductible tel quel, pas « une fois
  sur vingt en CI ».
  """

  use ExUnit.Case, async: true

  alias Atomboy.CPU.Loop
  alias Atomboy.CPU.State
  alias Atomboy.Memory.Flat

  @steps 2_000
  @seeds 1..20

  for seed <- @seeds do
    test "programme aléatoire, graine #{seed}" do
      :rand.seed(:exsss, {unquote(seed), 0, 0})

      rom = random_rom()
      state = random_state()

      # Les programmes s'auto-modifient — LD (HL), r écrit parfois sur le
      # chemin de PC — et peuvent fabriquer des opcodes hors table. L'oracle
      # s'arrête alors proprement ; l'équivalence porte sur le préfixe sain,
      # et sur le fait que la boucle échoue au même opcode juste après.
      {oracle_state, oracle_mem, budget, halted_on} = oracle(rom, state, @steps)
      {loop_state, loop_ram, loop_cycles} = Loop.run(state, rom, %{}, budget)

      assert loop_cycles == budget
      assert loop_state == oracle_state

      if halted_on do
        error =
          assert_raise Atomboy.CPU.Unimplemented, fn ->
            Loop.run(state, rom, %{}, budget + 1)
          end

        assert error.opcode == halted_on
      end

      # La mémoire de l'oracle contient ROM + écritures ; la ram de la boucle,
      # les écritures seules. Équivalence dans les deux sens : chaque octet de
      # l'espace d'adressage doit se lire pareil des deux côtés.
      divergences =
        for addr <- 0..0xFFFF,
            oracle_byte = Flat.read8(oracle_mem, addr),
            loop_byte = Map.get(loop_ram, addr, :binary.at(rom, addr)),
            oracle_byte != loop_byte,
            do: {addr, oracle_byte, loop_byte}

      assert divergences == []
    end
  end

  # ── Génération ──────────────────────────────────────────────────────────────

  # Un octet par adresse, tiré des opcodes implémentés. Aucun n'étant un saut,
  # PC parcourt l'espace linéairement et boucle — chaque tirage est un
  # programme valide de bout en bout.
  defp random_rom do
    opcodes = for {nil, op} <- Atomboy.CPU.implemented(), do: op

    0..0xFFFF
    |> Enum.map(fn _addr -> Enum.random(opcodes) end)
    |> :binary.list_to_bin()
  end

  defp random_state do
    %State{
      a: :rand.uniform(256) - 1,
      # F : quatre bits hauts seulement, comme le matériel.
      f: (:rand.uniform(16) - 1) * 16,
      b: :rand.uniform(256) - 1,
      c: :rand.uniform(256) - 1,
      d: :rand.uniform(256) - 1,
      e: :rand.uniform(256) - 1,
      h: :rand.uniform(256) - 1,
      l: :rand.uniform(256) - 1,
      sp: :rand.uniform(0x10000) - 1,
      pc: :rand.uniform(0x10000) - 1
    }
  end

  # N pas d'oracle sur une mémoire plate initialisée depuis la ROM. Renvoie
  # `{état, mémoire, budget_en_cycles, opcode_fautif | nil}` — l'opcode fautif
  # est celui, hors table, sur lequel l'exécution s'est arrêtée avant N pas.
  defp oracle(rom, state, steps) do
    mem =
      Flat.new(for {byte, addr} <- Enum.with_index(:binary.bin_to_list(rom)), do: {addr, byte})

    oracle_loop(state, mem, 0, steps)
  end

  defp oracle_loop(st, mem, cycles, 0), do: {st, mem, cycles, nil}

  # tick/2, pas step/2 : les boucles rapides servent les interruptions et
  # dorment sur HALT — les programmes aléatoires écrivent fortuitement dans
  # IF/IE et exécutent des HALT, et l'équivalence doit couvrir ce matériel-là
  # aussi. C'est même devenu son principal client.
  defp oracle_loop(st, mem, cycles, steps) do
    {st, mem, step_cycles} = Atomboy.CPU.tick(st, mem)
    oracle_loop(st, mem, cycles + step_cycles, steps - 1)
  rescue
    error in Atomboy.CPU.Unimplemented -> {st, mem, cycles, error.opcode}
  end
end
