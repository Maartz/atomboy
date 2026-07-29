# Atomboy

A Game Boy and Game Boy Color emulator written in Elixir — playable, with
sound, in your terminal or in a native window. Two copies can even trade
Pokémon over a TCP link cable.

<p align="center"><img src="docs/demo.gif" width="320" alt="Pokémon Silver running in atomboy"></p>

The unusual bet: **the emulated CPU is BEAM code.** The SM83 decoder is not
written by hand — it is generated from a data table into two backends (a
readable oracle and a fast tail-call loop), validated against ~500,000
[SingleStepTests](https://github.com/SingleStepTests/sm83) vectors, and kept
honest by cross-equivalence on random programs. Everything else (PPU, APU,
MBCs, link cable) is plain immutable Elixir on top of it.

## What works

- **CPU** — all 501 SM83 opcodes, interrupts, timers. blargg `cpu_instrs`:
  11/11.
- **Video** — full DMG PPU (background, window, sprites, raster tricks) and
  full CGB color mode. [dmg-acid2](https://github.com/mattcurrie/dmg-acid2)
  and [cgb-acid2](https://github.com/mattcurrie/cgb-acid2) both render
  pixel-perfect, frozen as golden tests.
- **Audio** — all four channels (pulse ×2, wave, noise), streamed to `ffplay`,
  paced by the wall clock so it never starves.
- **Cartridges** — MBC1, MBC3 (with real-time clock), MBC5; battery saves as
  standard `.sav` files, compatible with other emulators.
- **Game Boy Color** — CGB boot, VRAM/WRAM banking, color palettes, double
  speed, GDMA/HDMA. Pokémon Gold/Silver/Crystal run in full color.
- **Link cable over TCP** — the serial port speaks through a socket, resolved
  at scanline granularity with hardware-true transfer pacing. Verified with
  the hardest client there is: complete Pokémon gen-2 trades through the
  Cable Club, both directions, including re-trading a link-received Pokémon.
- **Comfort** — save states (9 slots), rewind (hold Backspace, 40 seconds of
  history), turbo, pause, save profiles so two players can share one ROM.
- **Two front ends** — a terminal renderer (real pixels via the kitty
  graphics protocol on Ghostty/kitty/WezTerm, ANSI half-blocks elsewhere) and
  a native window (wxWidgets, ships with OTP).
- **Single-file binaries** — Burrito wraps the app and the BEAM into one
  executable per platform. No Erlang required to play.

## Installing

On macOS, Homebrew has both the app and the CLI binary:

```sh
brew install --cask maartz/tap/atomboy      # Atomboy.app
brew install maartz/tap/atomboy-cli         # the terminal binary
```

Or grab a binary from the
[releases](https://github.com/Maartz/atomboy/releases) — `atomboy_linux_x64`,
`atomboy_macos_arm`, or `Atomboy.app.zip`.

## Playing

On macOS, the nicest way is the native app — `bin/build --vite --app`
produces `burrito_out/Atomboy.app`: a SwiftUI shell (full-bleed pixels
under the window's rounded corners, a Liquid Glass hover HUD, sound
through AVAudioEngine — no ffplay needed) driving the BEAM engine over a
pipe. Drag it to /Applications, double-click, pick a ROM — or open a
`.gb`/`.gbc` file with it. Cmd-, opens Settings: the sound mixer, and
GameShark codes saved per game.

Everywhere else (and for the terminal aficionados), the standalone binary:

```sh
atomboy game.gb                 # terminal renderer
atomboy game.gbc --fenetre      # native window (wxWidgets)
```

| Key | | Key | |
|---|---|---|---|
| Arrows | D-pad | Esc / `m` | menu |
| `x` | A | `s` / `r` | save / load state |
| `c` | B | `1`-`9` | pick state slot |
| Enter | Start | Backspace (hold) | rewind |
| Space | Select | Tab | turbo |
| `p` | pause | `q` | quit |

Esc opens an in-game menu — drawn into the Game Boy frame itself, so it
looks the same in the terminal and in the window: resume, save/load state,
state slot, palette, a sound mixer (master volume plus each of the four
voices), quit. Navigate with the D-pad, confirm with A, close with B.

Useful options:

| Option | |
|---|---|
| `--fenetre` | native window instead of the terminal |
| `--palette gris` | neutral grays instead of the DMG green |
| `--dmg` | force original Game Boy mode for CGB-flagged ROMs |
| `--sauvegarde <name>` | save profile — own `.sav`/`.state` per player |
| `--son` / `--no-son` | force sound on/off |
| `--codes 01FF16D1,…` | GameShark codes, applied every frame |

Sound needs `ffplay` (ships with ffmpeg) on the PATH; without it the game
plays silently.

### Link cable

One side listens, the other calls:

```sh
atomboy argent.gbc --fenetre --ecoute            # waits on port 7373
atomboy argent.gbc --fenetre --lien host:7373    # connects
```

Use `--sauvegarde` on both sides if they share the same ROM file. Turbo is
unavailable while the cable is plugged — the protocol is a paced duet.

## Building

With Docker, nothing to install:

```sh
docker build --output type=local,dest=burrito_out .
```

drops a standalone `atomboy_linux_x64` into `burrito_out/`. Pass
`--build-arg ATOMBOY_SHA=$(git rev-parse --short HEAD)` to stamp the version.

Natively (needs Elixir 1.18/OTP 26, `xz`, and zig 0.16.0 — installed via
`mise` automatically):

```sh
bin/build                # tests, then binaries in burrito_out/
bin/build --vite         # skip the tests
bin/build --install      # also copy to ~/.local/bin/atomboy
bin/build --app          # also assemble Atomboy.app (macOS, needs swiftc)
```

Or straight from the repo without building a release:

```sh
bin/play game.gb         # mix, with the right VM flags for the terminal
```

## Development

```sh
mix atomboy.corpus         # fetch SM83 vectors (~160 MB) + test ROMs, once
mix test                   # ~500,000 vectors + cross-equivalence + goldens
mix test --include blargg  # the cpu_instrs ROMs on top
```

| Task | |
|---|---|
| `mix atomboy.play rom.gb` | play from the repo (`--frames`, `--dump` for harnesses) |
| `mix atomboy.screen rom.gb [n]` | render n frames, `--debug` for blank-screen autopsies |
| `mix atomboy.progress` | opcode coverage grid for both tables |
| `mix atomboy.bench [n]` | CPU throughput in instructions/s |

### How the CPU is organized

| | |
|---|---|
| `cpu/table.ex` | **what you edit** — the instructions, as pure data |
| `cpu/insn.ex` | the struct describing one instruction (compile time only) |
| `cpu/gen.ex` | translates an instruction into function clauses |
| `cpu.ex` | hosts the generated oracle |
| `cpu/loop.ex`, `cpu/cart_loop.ex` | the generated fast loops (flat / cartridge semantics) |
| `cpu/state.ex` | processor state |

Adding an opcode family means entries in `table.ex` and `body/1` clauses in
`gen.ex`. The fast loop is never tested directly: it inherits correctness
from the oracle through cross-equivalence on random programs — state, memory
and cycle counts must match exactly, exceptions included.

### Testing philosophy

Per-opcode vectors first: a failure names the opcode and the bit, where a
test ROM only says "failed". Test ROMs (blargg, the acid2 pair) come second,
for what unit vectors cannot see: sequencing, timers, interrupts, rendering.
Golden CRCs freeze known-good frames. The link cable is tested against real
sockets, and was debugged against the pokegold/pokecrystal disassemblies as
the protocol oracle.

## The AtomVM heritage

Atomboy started life targeting [AtomVM](https://www.atomvm.net/) on ESP32 —
that is why the CPU is generated, why the memory API never changed shape,
and why `mix atomboy.atomvm` (packages and runs the app on a generic_unix
AtomVM build) and `mix atomboy.esp32` (flashes an ESP32 or ESP32-C6, with a
riscv32 AOT pipeline) still exist and work. The ESP32-C6 POC reached 12% of
real time with native AOT: the ceiling is the interpreter, not the hardware.
The embedded future of the project points at a Pi Zero 2W running the
regular BEAM instead; the ESP32 toolchain remains as a working curiosity.
