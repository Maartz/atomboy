# Atomboy

A Game Boy and Game Boy Color emulator written in Elixir — playable, with
sound, in a native macOS app, in a window, or in your terminal. Two copies can
trade Pokémon over a TCP link cable. The unusual bet: **the emulated CPU is
BEAM code**, generated from one instruction table into an oracle, a fast loop,
a compiler's assembler and a RISC-V emitter, so none of the four can drift
apart.

<p align="center"><img src="docs/demo.gif" width="320" alt="Pokémon Silver running in atomboy"></p>

## Highlights

- **A complete emulator** — all 501 SM83 opcodes, the full DMG and CGB PPU,
  four audio channels, MBC1/3/5 with battery saves. blargg's `cpu_instrs`
  11/11; dmg-acid2 and cgb-acid2 pixel-perfect and frozen as golden tests.
- **A macOS app that looks like a console** — a drawn body around the screen
  (⌘B), four of them following the panel presets, on top of an LCD simulation
  none of the other emulators have: response curve, dot structure, crosstalk,
  a contrast dial.
- **A time machine** — frame-perfect `.tas` movies, re-recording, frame
  advance, and Export Movie to MP4 or GIF.
- **The multiverse** — ⌘D forks the running game into four live universes,
  same buttons, different luck; listen to one, commit it, or walk it back.
- **Potion** — a GOOL-lineage language whose surface is Elixir and whose
  output is a real 32 KB cartridge. Six games written in it live in `games/`.
- **A native core** — the same instruction table emits a complete emulator in
  RV32 assembly, which runs under qemu and on an ESP32-C6 with a panel and a
  speaker.

## Installing

On macOS, Homebrew has both the app and the CLI binary:

```sh
brew install --cask maartz/tap/atomboy      # Atomboy.app
brew install maartz/tap/atomboy-cli         # the terminal binary
```

Or grab a binary from the
[releases](https://github.com/Maartz/atomboy/releases) — `atomboy_linux_x64`,
`atomboy_macos_arm`, or `Atomboy.app.zip`. Single-file executables: Burrito
wraps the app and the BEAM together, so no Erlang is required to play.

From source, with Docker and nothing else installed:

```sh
docker build --output type=local,dest=burrito_out .
```

Natively (Elixir 1.18/OTP 26, `xz` and zig 0.16.0, installed via `mise`):

```sh
bin/build --fast --app      # binaries in burrito_out/, plus Atomboy.app
```

The rest of the build and test commands are in
[the design page](docs/design.md#building-and-testing).

## Playing

Double-click Atomboy.app and pick a ROM — or drop a `.gb`/`.gbc` on it, or
open one with it. ⌘, is Settings, Esc is the panel behind the glass, and
everything else is in [Emulator features](docs/features.md).

In a terminal, or anywhere that is not a Mac:

```sh
atomboy game.gb                 # terminal renderer
atomboy game.gbc --window       # native window (wxWidgets)
```

Sound in the terminal and the wx window needs `ffplay` (ships with ffmpeg) on
the PATH; the app has its own audio and needs nothing.

## The four pages

| | |
|---|---|
| [Emulator features](docs/features.md) | everything you can do while playing: bodies, panels, saves, rewind, turbo, link cable, the time machine, the clock, the multiverse |
| [Emulator design](docs/design.md) | how it is built: the generated CPU, the panel model, the protocol behind the app, the testing philosophy |
| [Potion](docs/potion.md) | writing Game Boy games in Elixir, and the games written that way |
| [The native core](docs/native.md) | the emulator emitted as RV32 assembly, under qemu and on an ESP32-C6 |

And two deep dives on Potion, each following one thing all the way down:
[from Elixir to a cartridge](docs/pipeline.md) and
[sound in Potion](docs/sound.md).
