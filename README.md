# Atomboy

Émulateur Game Boy (DMG) en Elixir, destiné à tourner sur AtomVM sur ESP32.

Le but n'est pas de faire tourner une ROM par le chemin le plus court, mais que
**le CPU émulé soit du code BEAM** — la suite du projet étant un recompilateur
statique Game Boy → Core Erlang. Voir [le brief](gameboy-atomvm-brief.md) pour
le matériel, l'architecture et les phases.

État : **phase 1 terminée** — les 501 opcodes décodés dans les deux backends
(oracle + boucle rapide), ~500 000 vecteurs SingleStepTests verts, et les ROMs
blargg `cpu_instrs` passent (10/11 — `02-interrupts` attend le contrôleur
d'interruptions). Mesuré sur ESP32-C6 en natif AOT : 12 % du temps réel, avant
recompilateur.

## Démarrer

```sh
mix atomboy.corpus         # vecteurs SM83 (~160 Mo) + ROMs blargg, une fois
mix test                   # ~500 000 vecteurs + équivalence croisée
mix test --include blargg  # les ROMs cpu_instrs en plus
```

## Commandes

| | |
|---|---|
| `mix test` | un test par opcode implémenté, ~1 000 vecteurs chacun |
| `mix atomboy.progress` | grille de couverture des deux tables d'opcodes |
| `mix atomboy.bench [n]` | débit du CPU en instructions/s |
| `mix atomboy.atomvm` | vérifie que le code se charge et s'exécute sous AtomVM |
| `mix atomboy.esp32 [--firmware]` | flashe la carte — ESP32 (bytecode) ou C6 (AOT natif riscv32), cible déduite du port |
| `mix atomboy.corpus` | récupère le corpus de vecteurs |

## Comment c'est organisé

Le décodeur n'est pas écrit à la main : la table SM83 est régulière en
décomposition octale, donc les familles d'opcodes sont générées.

| | |
|---|---|
| `cpu/table.ex` | **ce que tu édites** — les instructions, en donnée pure |
| `cpu/insn.ex` | le struct qui décrit une instruction (compilation seulement) |
| `cpu/gen.ex` | traduit une instruction en clause de fonction |
| `cpu.ex` | accueille les clauses générées |
| `cpu/state.ex` | l'état du processeur |
| `memory.ex` | la frontière mémoire — même API du Mac au NIF ESP32 |

Ajouter une famille d'opcodes, c'est des entrées dans `table.ex` et des clauses
`body/1` dans `gen.ex`. `cpu.ex` ne bouge pas.

L'intérêt réel de cette table arrive en phase 5 : le recompilateur statique lira
la *même* source pour émettre du Core Erlang, au lieu d'un second décodage à
maintenir en parallèle.

## Tester

Les vecteurs viennent de [SingleStepTests/sm83](https://github.com/SingleStepTests/sm83) :
pour chaque opcode, un millier d'états machine complets avant/après. Un échec
désigne l'opcode et le bit, là où une ROM de test répond seulement « échec ».

Les ROMs de blargg viennent après, pour ce que les vecteurs unitaires ne voient
pas : enchaînements, timers, interruptions.

## AtomVM

`mix atomboy.atomvm` empaquette l'application et l'exécute sur le build
`generic_unix`. AtomVM n'implémente qu'un sous-ensemble des instructions BEAM et
d'OTP, et **résout les fonctions à l'appel** : ce check ne prouve donc que ce que
le programme fumée exécute réellement.

Il cherche le build dans `ATOMVM_BUILD`, sinon dans `../AtomVM/build`.

Sur macOS, AtomVM exige MbedTLS 2.x ou 3.x — pas la 4.x que Homebrew installe
par défaut :

```sh
brew install mbedtls@3
cmake .. -DMBEDTLS_ROOT_DIR=/opt/homebrew/opt/mbedtls@3
make -j8 AtomVM PackBEAM atomvmlib exavmlib
```
