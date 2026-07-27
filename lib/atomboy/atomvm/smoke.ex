defmodule Atomboy.AtomVM.Smoke do
  @moduledoc """
  Le point d'entrée du garde-fou AtomVM. Voir `mix help atomboy.atomvm`.

  Ce module ne teste pas la justesse du CPU — c'est le travail des vecteurs
  SM83, et sur OTP standard où le débogage est possible. Il répond à une seule
  question : **le code compilé se charge-t-il et s'exécute-t-il sous AtomVM ?**

  Ce qui casse à ce niveau ne se voit pas sur le Mac : une instruction BEAM
  absente de la table d'AtomVM, une fonction d'OTP non implémentée, une
  construction Elixir qui suppose une bibliothèque standard complète. Découvrir
  ça à la phase 2, avec des semaines de code écrit dessus, coûte cher — d'où un
  check exécutable dès le premier module.

  Le programme exercé traverse les mécanismes qui comptent : le dispatch sur
  entier dense généré par `for`, les opérations `Bitwise`, l'appel de NIF de
  map, et la construction de tuples.
  """

  @program %{
    # LD B, C     — registre vers registre
    0x0000 => 0x41,
    # LD (HL), B  — écriture mémoire
    0x0001 => 0x70,
    # LD A, (HL)  — lecture mémoire
    0x0002 => 0x7E,
    # NOP
    0x0003 => 0x00
  }

  @doc """
  Point d'entrée AtomVM. Affiche `smoke ok` ou le détail de l'écart.
  """
  def start do
    mem = Atomboy.Memory.Flat.new(@program)
    state = %Atomboy.CPU.State{c: 0x42, h: 0xC0, sp: 0xFFFE}

    {final, mem, cycles} = run(state, mem, 4, 0)

    checks = [
      {:b, final.b, 0x42},
      {:a, final.a, 0x42},
      {:pc, final.pc, 0x0004},
      {:mem_c000, Atomboy.Memory.Flat.read8(mem, 0xC000), 0x42},
      {:cycles, cycles, 4 + 8 + 8 + 4}
    ]

    case Enum.reject(checks, fn {_name, got, want} -> got == want end) do
      [] ->
        :erlang.display(:smoke_ok)

      bad ->
        :erlang.display(:smoke_failed)

        Enum.each(bad, fn {name, got, want} -> :erlang.display({name, :got, got, :want, want}) end)
    end

    0
  end

  defp run(state, mem, 0, cycles), do: {state, mem, cycles}

  defp run(state, mem, steps, cycles) do
    {state, mem, step_cycles} = Atomboy.CPU.step(state, mem)
    run(state, mem, steps - 1, cycles + step_cycles)
  end
end
