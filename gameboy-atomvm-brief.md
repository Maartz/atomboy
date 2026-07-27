# Game Boy sur AtomVM — brief technique

Émulateur Game Boy (DMG) écrit en Erlang/Elixir, tournant sur AtomVM sur ESP32,
logé à terme dans une coque Game Boy LEGO.

Le but n'est pas de faire tourner une ROM par le chemin le plus court. Le but est
que **le CPU émulé soit du code BEAM**, parce que la suite du projet est un
recompilateur statique Game Boy → bytecode BEAM.

---

## Principe directeur

> On utilise AtomVM là où on peut, le reste via NIF.

Ce qui relève de la logique, de la structure ou de la compilation reste en BEAM.
Ce qui est une pompe à octets à débit fixe part en C.

---

## Matériel

| Élément | Référence | Notes |
|---|---|---|
| MCU principal | ESP32-WROVER-E | PSRAM — carte des phases 1 à 4 |
| MCU secondaire | ESP32-C6 | RISC-V, cible du JIT AtomVM, phase 5 |
| Écran | Waveshare 2,4" ILI9341, SPI | 240×320 natif, zone active 36,72 × 48,96 mm |
| Entrées | PCF8574 (I2C) + 8 boutons tactiles | 8 boutons sur 3 fils |
| Audio | MAX98357A (I2S) + HP 8 Ω 2 W | alimenté en **5 V** |
| Coque | Game Boy LEGO | ouverture écran 50 × 40 mm, panneau dispo 90 × 80 mm |

Le C6 n'a pas de PSRAM mais a 512 Ko de SRAM. Le working set estimé de
l'émulateur est ~100 Ko (VRAM 8 Ko + WRAM 8 Ko + HRAM + OAM + RAM cartouche
jusqu'à 32 Ko + framebuffer). Les deux cartes sont donc viables ; la WROVER-E
donne juste plus de marge.

---

## Architecture

### En C (NIF / Port / resource)

- Espace d'adressage 64 Ko (voir « modèle mémoire »)
- PPU : rendu scanline, tuiles, sprites → écrit dans le framebuffer
- Transfert framebuffer → SPI en DMA
- APU + push I2S vers le MAX98357A (phase tardive)

### En BEAM

- CPU : fetch / décodage / exécution — puis, phase 5, les modules recompilés
- MMU : logique de banking MBC
- Interruptions, timers DIV / TIMA
- Boucle de frame, supervision, lecture des boutons
- Shell de debug, inspection d'état

---

## Modèle mémoire — la décision structurante

C'est le point coûteux à changer plus tard. À trancher avant d'écrire du code.

Le PPU (C) lit la VRAM et l'OAM 60 fois par seconde. Le CPU (BEAM) y écrit. Une
binary BEAM est immuable : chaque écriture recopierait tout. Inutilisable.

**Décision : l'espace d'adressage 64 Ko est une resource possédée par le C.**

- NIFs `read8/2`, `write8/3`, `read16/2`
- Le PPU y accède directement en C, sans copie
- Le CPU y accède par appel de NIF

Prix à payer, à anticiper : chaque accès mémoire du CPU est un appel de NIF. À
~200 000 accès/s c'est absorbable. Mais au moment du recompilateur puis du JIT,
ces appels sont exactement ce que le JIT ne peut pas inliner, et ils risquent de
dominer le profil.

Deux conséquences à intégrer dès la conception de l'interface :

1. Prévoir des **accesseurs en bloc** en plus des accès unitaires — un `push` /
   `pop` qui fait deux accès en un seul appel se voit sur le profil.
2. Le recompilateur pourra **prouver** qu'une grande partie des accès visent la
   ROM à des adresses constantes et les remplacer par des constantes inlinées.
   C'est là que le compilateur gagne le plus, davantage que sur le décodage.
   L'interface mémoire doit être dessinée en gardant cette optimisation ouverte.

---

## Écran

- Dalle native 240×320 (portrait). **Rotation via le registre MADCTL à
  l'initialisation**, jamais en logiciel — faire pivoter 46 Ko par frame côté
  BEAM serait absurde.
- Framebuffer 160×144, mise à l'échelle vers 320×240 :
  - **×5/3 → 267×240** (40,8 × 36,7 mm) : remplit la dalle en hauteur, comble
    bien l'ouverture LEGO. Motif 2,2,1 répété, quelques colonnes plus fines.
  - **×1,5 → 240×216** (36,7 × 33,0 mm) : pixels réguliers (2 → 3), mais l'image
    flotte dans l'ouverture.
  - Choix par défaut : ×5/3, avec un masque noir devant l'ouverture LEGO
    dimensionné sur l'image affichée.
- Débit : 46 Ko par frame en RGB565. À 20 MHz de SPI, ~18 ms rien qu'en
  transfert. **Sur breadboard, démarrer à 10 MHz**, valider l'image, puis monter
  jusqu'à la casse. Un plafond de framerate à ce stade vient du câblage, pas de
  l'émulateur.
- Avant toute découpe dans la coque : récupérer le **plan mécanique** Waveshare.
  Ce qui compte est la position de la zone active par rapport aux bords du PCB,
  rarement centrée.

---

## Entrées

8 boutons (D-pad ×4, A, B, Start, Select) sur un PCF8574 en I2C, plus sa broche
INT. 3 fils au lieu de 8 GPIO.

Points d'implémentation :

- Le PCF8574 est **quasi-bidirectionnel** : écrire 1 sur une broche avant de
  pouvoir la lire. Sinon on lit des zéros.
- Pull-ups internes faibles (~100 µA), suffisants pour des boutons vers la masse.
  Aucune résistance externe.
- INT en drain ouvert, actif bas, se réarme à la lecture du port.
- Adresse I2C entre 0x20 et 0x27 selon le cavalier A0/A1/A2 du module.
- **Pas d'antirebond logiciel nécessaire** : échantillonnage une fois par frame
  (16,7 ms) contre 1–5 ms de rebond. Le filtrage est gratuit.
- La valeur du registre `0xFF00` est reconstruite en logiciel à partir de l'état
  des 8 boutons (les lignes de sélection P14/P15 sont émulées, pas câblées).

---

## Audio

- MAX98357A : DAC I2S + ampli classe D, un seul module.
- **Alimentation 5 V**, logique I2S en 3,3 V (toléré). Sous 3,3 V on perd la
  moitié du volume.
- La broche SD sélectionne le canal (gauche / droite / (L+R)/2), ce n'est pas un
  simple shutdown malgré le nom.
- Même schéma que l'écran : le C pousse des blocs PCM en DMA, le BEAM génère les
  échantillons par paquets.
- Phase tardive. Ne pas commencer par là.

---

## Performance — à savoir avant de commencer

Le CPU de la DMG tourne à 4,194304 MHz, soit environ **500 000 instructions par
seconde** à soutenir.

Estimation à la louche : AtomVM sur ESP32 à 240 MHz fait peut-être 1 à 3 millions
d'instructions BEAM par seconde. Une instruction Game Boy émulée en Erlang en
coûte 20 à 60 (fetch, décodage, ALU, drapeaux, accès mémoire). On atterrit vers
**20 000 à 100 000 instructions Game Boy par seconde**, avant même le PPU.

Il manque donc un facteur 5 à 25. **C'est attendu.** Un interpréteur naïf en
BEAM ne fera pas tourner un jeu en temps réel, et ce n'est pas un échec de
l'implémentation.

Le plan pour combler l'écart :

1. Recompilation statique : supprimer fetch / décodage / dispatch → typiquement
   ×3 à ×10 sur un interpréteur.
2. JIT riscv32 d'AtomVM sur le C6 : supprimer le dispatch BEAM → ×2 à ×5.
3. Inlining des accès ROM à adresse constante par le recompilateur.

Ces chiffres sont des estimations, pas des mesures. Les mesurer fait partie du
projet.

---

## Phases

**1. Interpréteur, sur le Mac.** Erlang ou Elixir, exécuté sur OTP standard ou
sur le build `generic_unix` d'AtomVM. Objectif : les ROMs de test de blargg
(`cpu_instrs`) passent. Aucun matériel.

Cette phase produit surtout un **oracle** : le recompilateur de la phase 5 se
validera en comparant son état machine à celui de l'interpréteur, instruction par
instruction. Sans cet oracle, le débogage se fait à l'aveugle.

**2. Le même sur ESP32.** Via AtomVM sur la WROVER-E, ROM embarquée dans le
packbeam (pas de carte SD à ce stade — une ROM fait 32 Ko à 1 Mo, la partition
applicative absorbe ça). Résultat sur le port série. Toujours aucun matériel
supplémentaire.

**3. Écran + NIF framebuffer.** Le jeu s'affiche, même à 5 fps. Premier moment où
le projet devient tangible.

**4. Boutons, audio, coque LEGO.** Objet fini.

**5. Recompilateur statique.** ROM → graphe de flot → **Core Erlang** →
`:compile.forms` avec `:from_core`. Ne pas viser le bytecode BEAM directement :
Core Erlang est le bon niveau, et c'est la même cible que le projet Common Lisp
sur BEAM par ailleurs.

Difficultés attendues : code auto-modifiant et sauts calculés (imposent de
garder l'interpréteur en secours), mapping des registres Z80 sur des arguments de
fonction, comptage des cycles machine pour la synchro PPU, banques mémoire qui
cassent l'hypothèse de code statique.

**6. Optionnel.** Carte SD, lecteur de cartouche.

---

## Décisions déjà prises

- Frontière C/BEAM telle que décrite ci-dessus
- Mémoire = resource C, accès par NIF
- ROM embarquée dans le packbeam en phase 2, pas de SD
- Écran piloté en paysage via MADCTL
- Boutons via PCF8574, pas en GPIO direct
- Cible du recompilateur : Core Erlang
- Interpréteur d'abord, comme oracle — pas de recompilateur avant qu'il passe
  `cpu_instrs`

---

## Non-objectifs

- Précision cycle-exact au démarrage. Viser d'abord « les ROMs de test passent ».
- Game Boy Color, Super Game Boy, link cable.
- Le son en phase 1 à 3.
- Faire tourner un jeu en temps réel avant la phase 5. Ce n'est pas atteignable
  et ce n'est pas le critère de réussite intermédiaire.

---

## Notes AtomVM

- Développement du VM et des NIFs : build depuis les sources, ESP-IDF requis.
- Un NIF ou Port custom se place dans le répertoire `components/` de l'arbre
  AtomVM ; `REGISTER_NIF_COLLECTION` évite d'éditer des fichiers source.
  `idf.py reconfigure` ensuite. La doc officielle sur ce point est périmée
  (référence un `component_nifs.txt` qui n'existe plus) — lire la source.
- Le build `generic_unix` tourne sur macOS : toute la boucle d'itération sur le
  VM et sur l'interpréteur se fait sur le Mac, en quelques secondes.
- Packbeam flashé à 0x250000 (image avec Elixir) ou 0x210000 (image standard).
- Flash via `atomvm_rebar3_plugin` (`rebar3 atomvm esp32_flash`) ou ExAtomVM
  (`mix atomvm.esp32.flash`).
- AtomVM n'implémente pas toutes les instructions BEAM : voir
  `src/libAtomVM/opcodes.h`. À vérifier tôt pour le code généré en phase 5.
- Entiers limités à 256 bits (sans objet ici, mais à savoir).

---

## Références

- ROMs de test : blargg (`cpu_instrs` en premier), puis mooneye-gb
- Matériel de référence : `sonocotta/esp32-gameboy` — reprendre le schéma
  électrique (WROVER + PSRAM, PCF8574, ampli, 320×240). **Le firmware fourni est
  un émulateur NES**, pas Game Boy ; il ne sert pas.
- Documentation Game Boy : Pan Docs

---

## Pièges de câblage (breadboard)

- Pas de plan de masse, dupont = antennes. SPI à 10 MHz pour commencer.
- Rétroéclairage (60–100 mA) et MAX98357A sur le **5 V**, pas sur le régulateur
  3,3 V de la carte — sinon brownout au démarrage du son.
- Souffle audio normal sur breadboard (classe D + masses communes). Un 100 µF sur
  le 5 V près de l'ampli aide. Disparaît au câblage définitif.
