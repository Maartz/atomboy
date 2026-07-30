defmodule Mix.Tasks.Atomboy.Native.Bench do
  @shortdoc "Mesure le coût du natif en instructions RV32 par instruction SM83"

  @moduledoc """
  Le chiffre du chantier.

      mix atomboy.native.bench

  ## Pourquoi pas des secondes

  qemu n'est pas cycle-exact : chronométrer une exécution invitée ne mesure que
  la machine hôte. Ce qui est exact, en revanche, c'est le **nombre
  d'instructions retirées** — sous `-icount shift=0`, le compteur `instret` du
  processeur émulé les compte une à une. Vérifié à la main : une boucle de mille
  tours à deux instructions rend 2002.

  Le rapport « instructions RV32 par instruction SM83 » est donc une mesure, pas
  une estimation. C'est aussi la seule grandeur qui se transporte du qemu au
  silicium : elle ne dépend ni de la fréquence, ni du cache, ni de l'hôte.

  ## Ce que le chiffre ne dit pas

  Il ne dit pas combien d'instructions par cycle le C6 retire réellement. Les
  défauts d'icache, la latence de la flash et les aléas de branchement ne sont
  pas dans qemu. La projection en fin de rapport pose donc une hypothèse d'IPC
  explicite, et elle vaut ce que vaut cette hypothèse — c'est-à-dire qu'elle
  attend le silicium.
  """

  use Mix.Task

  alias Atomboy.CPU.Insn
  alias Atomboy.CPU.State
  alias Atomboy.CPU.Table
  alias Atomboy.Memory.Flat
  alias Atomboy.Native.Interp
  alias Atomboy.Native.Qemu
  alias Atomboy.Native.Run

  @icache 32 * 1024
  @horloge_dmg 4_194_304
  @horloge_c6 160_000_000

  # Deux programmes, et deux façons de mentir sur la même mesure.
  #
  # `LD B, C` répété n'accède à rien : c'est un plafond optimiste, et c'est
  # exactement ce que mesure `mix atomboy.bench`, donc les deux chiffres se
  # comparent.
  #
  # Le bloc mixte est celui que `Atomboy.AtomVM.Main` fait tourner sur carte —
  # immédiats, ALU, rotation CB, accès registre — donc les mesures du natif et
  # celles du C6 parlent du même programme.
  @blocs [
    {"LD B, C", <<0x41>>},
    {"bloc mixte",
     <<0x3E, 0x55, 0x06, 0x33, 0x80, 0x04, 0xB1, 0x2F, 0xCB, 0x37, 0xA8, 0x15, 0x1F, 0xE6, 0x0F,
       0x7D>>}
  ]

  @impl true
  def run(_argv) do
    Mix.Task.run("compile")

    unless Qemu.available?() do
      Mix.raise("qemu-system-riscv32 est introuvable — `brew install qemu`")
    end

    taille()
    Mix.shell().info("")
    Enum.each(@blocs, &mesure/1)
  end

  # ══ La taille ════════════════════════════════════════════════════════════════

  defp taille do
    image = Interp.image(:binary.copy(<<0>>, 0x10000), %State{}, 1)
    l = image.labels

    sections = [
      {"pilote, fetch et rapport", l[:h_cb]},
      {"gestionnaires d'opcodes", l[:alu_add] - l[:h_cb]},
      {"routines d'ALU", l[:table_base] - l[:alu_add]},
      {"tables de saut", 2 * 256 * 4}
    ]

    code = l[:table_base] + 2 * 256 * 4

    Mix.shell().info("Taille du code émis")

    for {nom, octets} <- sections do
      Mix.shell().info("  #{String.pad_trailing(nom, 26)} #{pad(octets)} o")
    end

    Mix.shell().info("  #{String.pad_trailing("total", 26)} #{pad(code)} o")

    Mix.shell().info(
      "  soit #{Float.round(code * 100 / @icache, 1)} % de l'icache du C6 (#{@icache} o)"
    )
  end

  defp pad(n), do: String.pad_leading(Integer.to_string(n), 6)

  # ══ La mesure ════════════════════════════════════════════════════════════════

  defp mesure({nom, bloc}) do
    %{instructions: par_bloc, cycles: cycles_bloc} = analyse(bloc)

    # Un budget en nombre entier de blocs : la dernière instruction ne déborde
    # pas, donc le compte d'instructions SM83 est exact et non estimé.
    tours = 5_000
    budget = cycles_bloc * tours
    instructions = par_bloc * tours

    memoire = remplir(bloc)
    verifie!(nom, bloc, memoire, par_bloc, cycles_bloc)

    resultat = Run.run!(memoire, %State{}, budget, icount: true)

    if resultat.statut != :ok do
      Mix.raise("le bloc « #{nom} » s'est arrêté sur #{resultat.statut}")
    end

    if resultat.cycles != budget do
      Mix.raise("budget #{budget} demandé, #{resultat.cycles} consommés — le bloc ne boucle pas")
    end

    # PC exactement sur la frontière du dernier tour : sans cela, le budget
    # s'arrêterait au milieu d'un bloc, le décompte d'instructions serait décalé
    # et le rapport faux sans que rien ne le signale.
    attendu_pc = rem(tours * byte_size(bloc), 0x10000)

    if resultat.state.pc != attendu_pc do
      Mix.raise(
        "PC finit à #{resultat.state.pc} au lieu de #{attendu_pc} — " <>
          "le budget ne tombe pas sur un tour entier"
      )
    end

    par_instruction = resultat.instret / instructions
    par_cycle = resultat.instret / budget
    cycles_par_seconde = @horloge_c6 / par_cycle

    Mix.shell().info("""
    #{nom} — #{par_bloc} instruction(s) SM83, #{cycles_bloc} T par tour
      #{instructions} instructions SM83, #{resultat.instret} instructions RV32
      #{Float.round(par_instruction, 2)} instructions RV32 par instruction SM83
      #{Float.round(par_cycle, 2)} par cycle T

      Projection C6 à #{div(@horloge_c6, 1_000_000)} MHz : #{round(cycles_par_seconde / 1000)} kcycles/s,
      soit #{Float.round(cycles_par_seconde * 100 / @horloge_dmg, 1)} % du temps réel d'une DMG —
      **en supposant une instruction par cycle**, ce que qemu ne peut pas valider,
      et **pour le seul CPU** : ni PPU, ni APU, ni banques de cartouche.
    """)
  end

  # Le décompte du bloc, confronté à l'oracle : `instructions` pas doivent
  # consommer exactement `cycles` T et ramener PC à son point de départ. Un banc
  # qui compte faux rend un rapport faux sans que rien ne le signale.
  defp verifie!(nom, bloc, memoire, instructions, cycles) do
    plate =
      Flat.new(for {b, addr} <- Enum.with_index(:binary.bin_to_list(memoire)), do: {addr, b})

    {etat, _mem, consommes} =
      Enum.reduce(1..instructions, {%State{}, plate, 0}, fn _, {st, mem, total} ->
        {st, mem, pas} = Atomboy.CPU.tick(st, mem)
        {st, mem, total + pas}
      end)

    if consommes != cycles do
      Mix.raise(
        "« #{nom} » : la table annonce #{cycles} T par tour, l'oracle en consomme #{consommes}"
      )
    end

    if etat.pc != byte_size(bloc) do
      Mix.raise(
        "« #{nom} » : après #{instructions} pas l'oracle est en #{etat.pc}, " <>
          "or le bloc fait #{byte_size(bloc)} octets — le décompte d'instructions est faux"
      )
    end

    :ok
  end

  # Le bloc répété jusqu'à remplir l'espace d'adressage. Sa longueur divise
  # 65 536 pour que le bouclage de PC retombe sur une frontière de bloc.
  defp remplir(bloc) do
    taille = byte_size(bloc)

    unless rem(0x10000, taille) == 0 do
      Mix.raise("un bloc de #{taille} octets ne pave pas 64 Ko")
    end

    :binary.copy(bloc, div(0x10000, taille))
  end

  # ══ Le décompte, depuis la table ═════════════════════════════════════════════

  # Combien d'instructions et de cycles dans un bloc. Dérivé de la table plutôt
  # qu'écrit à la main : un bloc de bench qui compterait faux donnerait un
  # rapport faux sans que rien ne le dise.
  defp analyse(bloc), do: analyse(:binary.bin_to_list(bloc), %{instructions: 0, cycles: 0})

  defp analyse([], acc), do: acc

  defp analyse([0xCB, sous | reste], acc) do
    insn = trouve(Table.extended(), sous)
    analyse(reste, %{acc | instructions: acc.instructions + 1, cycles: acc.cycles + insn.cycles})
  end

  defp analyse([opcode | reste], acc) do
    insn = trouve(Table.base(), opcode)
    reste = Enum.drop(reste, operandes(insn))
    analyse(reste, %{acc | instructions: acc.instructions + 1, cycles: acc.cycles + insn.cycles})
  end

  defp trouve(table, opcode) do
    Enum.find(table, &(&1.opcode == opcode)) ||
      Mix.raise("le bloc contient l'opcode #{opcode}, absent de la table")
  end

  defp operandes(%Insn{operands: operands}) do
    Enum.reduce(operands, 0, fn
      {:imm, 8}, n -> n + 1
      :a8_ind, n -> n + 1
      {:imm, 16}, n -> n + 2
      :a16_ind, n -> n + 2
      _, n -> n
    end)
  end
end
