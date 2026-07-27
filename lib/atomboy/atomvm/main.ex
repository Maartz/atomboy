defmodule Atomboy.AtomVM.Main do
  @moduledoc """
  Point d'entrée embarqué : smoke test puis mesure de débit, sur AtomVM.

  Tourne à l'identique sur le build `generic_unix` (Mac) et sur ESP32 — c'est
  le même `.avm`. La version Mac sert de contrôle : si un chiffre ESP32 semble
  aberrant, on compare d'abord au même programme sur le même VM en local.

  ## Pourquoi ce bench n'est pas `mix atomboy.bench`

  Le bench Mix remplit les 64 Ko d'adressage de `LD B, C`, soit une map de
  65 536 entrées. Le firmware ESP32 utilisé n'active pas la PSRAM : le tas vit
  dans la SRAM interne, et une map de cette taille n'y tient pas.

  Ici la mémoire ne contient que le petit programme du smoke test ; tout le
  reste de l'espace lit 0, c'est-à-dire `NOP`. Le débit mesuré est donc celui
  d'une boucle fetch + dispatch + NOP : un **plafond**, pas une moyenne. La
  comparaison utile est ESP32 contre Mac *sur ce même programme*, pas contre le
  bench Mix.

  ## Chiffre attendu

  Le brief estime AtomVM/ESP32 à 20 000–100 000 instructions Game Boy par
  seconde, sans mesure. C'est précisément ce que ce module va remplacer par un
  nombre.
  """

  alias Atomboy.CPU.State
  alias Atomboy.Memory.Flat

  # :atomvm n'existe que sous AtomVM ; sur OTP ce module ne tourne jamais.
  @compile {:no_warn_undefined, :atomvm}

  # LD B,C ; LD (HL),B ; LD A,(HL) ; NOP — le même programme que le smoke test
  # du garde-fou generic_unix.
  @program %{0x0000 => 0x41, 0x0001 => 0x70, 0x0002 => 0x7E, 0x0003 => 0x00}

  # Le bench est borné en temps, pas en pas : 5 s de mesure quelle que soit la
  # vitesse de la cible. La version bornée en pas a coûté 158 s sur ESP32 à
  # 631 instr/s — un chiffre qu'on ne connaissait justement pas avant de
  # mesurer, ce qui est toute l'ironie d'un bench à durée dépendante du
  # résultat.
  @budget_ms 5_000
  @chunk 1_000
  @max_steps 10_000_000

  def start do
    :erlang.display({:atomboy, :smoke})
    smoke()

    :erlang.display({:atomboy, :bench})
    bench()

    :erlang.display({:atomboy, :probe})
    Atomboy.AtomVM.Probe.bench()

    :erlang.display({:atomboy, :loop})
    loop_bench()

    :erlang.display({:atomboy, :done})

    # Sur ESP32, un start/0 qui retourne peut redémarrer la carte et noyer le
    # résultat dans les logs de boot : on reste en vie. Sur generic_unix c'est
    # l'inverse — la sortie standard n'est flushée qu'à la terminaison du
    # processus, donc il faut sortir pour que quiconque voie quoi que ce soit.
    case :atomvm.platform() do
      :esp32 -> idle()
      _ -> 0
    end
  end

  defp smoke do
    mem = Flat.new(@program)
    state = %State{c: 0x42, h: 0xC0, sp: 0xFFFE}

    {final, mem, cycles} = run(state, mem, 4, 0)

    checks = [
      {:b, final.b, 0x42},
      {:a, final.a, 0x42},
      {:pc, final.pc, 0x0004},
      {:mem_c000, Flat.read8(mem, 0xC000), 0x42},
      {:cycles, cycles, 24}
    ]

    case Enum.reject(checks, fn {_name, got, want} -> got == want end) do
      [] ->
        :erlang.display(:smoke_ok)

      bad ->
        :erlang.display(:smoke_failed)

        Enum.each(bad, fn {name, got, want} -> :erlang.display({name, :got, got, :want, want}) end)
    end
  end

  defp bench do
    mem = Flat.new(@program)
    state = %State{c: 0x42, h: 0xC0, sp: 0xFFFE}

    # Tour de chauffe : stabilise la mesure, et vérifie que la boucle tient en
    # mémoire avant de partir pour cinq secondes.
    run(state, mem, @chunk, 0)

    t0 = :erlang.monotonic_time(:millisecond)
    {steps, elapsed} = bench_loop(state, mem, t0, 0)

    # Tout en entiers : pas de dépendance au formatage flottant d'AtomVM.
    per_second = if elapsed > 0, do: div(steps * 1000, elapsed), else: :too_fast

    :erlang.display({:steps, steps})
    :erlang.display({:elapsed_ms, elapsed})
    :erlang.display({:instructions_per_second, per_second})
  end

  # Mesure par tranches de @chunk pas, arrêt au budget de temps ou au plafond
  # de pas — le plafond évite qu'une cible très rapide ne fasse dix milliards
  # de pas en cinq secondes.
  defp bench_loop(state, mem, t0, steps) do
    {state, mem, _cycles} = run(state, mem, @chunk, 0)
    steps = steps + @chunk
    elapsed = :erlang.monotonic_time(:millisecond) - t0

    if elapsed >= @budget_ms or steps >= @max_steps do
      {steps, elapsed}
    else
      bench_loop(state, mem, t0, steps)
    end
  end

  defp run(state, mem, 0, cycles), do: {state, mem, cycles}

  defp run(state, mem, steps, cycles) do
    {state, mem, step_cycles} = Atomboy.CPU.step(state, mem)
    run(state, mem, steps - 1, cycles + step_cycles)
  end

  # Une frame DMG : 154 scanlines × 456 T-cycles.
  @frame_cycles 70_224
  # Le débit de T-cycles qu'une DMG soutient : 4,194304 MHz.
  @dmg_hz 4_194_304

  # La boucle rapide, appelée comme la boucle de frame l'appellera : un budget
  # d'une frame par appel, l'état matérialisé entre deux. Le chiffre rendu est
  # celui qui compte pour le projet — le pourcentage du temps réel.
  defp loop_bench do
    rom = Atomboy.AtomVM.Probe.rom()
    state = %State{c: 0x42, h: 0xC0, sp: 0xFFFE}

    {_state, _ram, _cycles} = Atomboy.CPU.Loop.run(state, rom, %{}, @frame_cycles)

    t0 = :erlang.monotonic_time(:millisecond)
    {frames, elapsed} = loop_frames(state, rom, t0, 0)

    cycles = frames * @frame_cycles
    per_second = if elapsed > 0, do: div(cycles * 1000, elapsed), else: :too_fast

    :erlang.display({:loop_frames, frames})
    :erlang.display({:loop_elapsed_ms, elapsed})
    :erlang.display({:loop_cycles_per_second, per_second})

    if is_integer(per_second) do
      :erlang.display({:loop_realtime_percent, div(per_second * 100, @dmg_hz)})
    end
  end

  defp loop_frames(state, rom, t0, frames) do
    # La ram repart vide à chaque frame : le bench mesure le CPU, pas la
    # croissance d'une map d'écritures qu'aucun PPU ne consomme encore.
    {state, _ram, _cycles} = Atomboy.CPU.Loop.run(state, rom, %{}, @frame_cycles)
    frames = frames + 1
    elapsed = :erlang.monotonic_time(:millisecond) - t0

    if elapsed >= @budget_ms or frames >= 100_000 do
      {frames, elapsed}
    else
      loop_frames(state, rom, t0, frames)
    end
  end

  defp idle do
    receive do
    after
      60_000 ->
        :erlang.display({:atomboy, :idle})
        idle()
    end
  end
end
