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

## Potion — writing Game Boy games in Elixir

<p align="center"><img src="docs/potion.gif" width="320" alt="A Potion-compiled square walking around under d-pad control"></p>

Atomboy now runs in both directions. **Potion** is a language in the
lineage of Andy Gavin's GOOL (the Lisp that Crash Bandicoot was written
in): the surface is Elixir, the semantics are the console's, and the
output is a real 32 KB cartridge — header, Nintendo logo, checksums —
that runs in atomboy or on hardware via flashcart:

```elixir
defmodule Hero do
  use Potion

  defactor :hero do
    variables x: 80, y: 72

    every_frame do
      if pressed?(:right), do: x = x + 1
      if pressed?(:left), do: x = x - 1
      if pressed?(:up), do: y = y - 1
      if pressed?(:down), do: y = y + 1
      sprite(0, x: x, y: y, tile: 0)
    end
  end
end
```

`mix run games/hero.exs` compiles that into `games/hero.gb` — the GIF
above is that ROM, running in atomboy. Variables are WRAM cells,
`x = x + 1` is three SM83 instructions that wrap at 255, and anything
the console cannot do is refused at `mix compile` time with a message
that explains what Potion knows. The assembler is derived from the same
instruction table as the emulator's decoder, so the two can never
disagree; the emulator is the compiler's test harness, down to
pixel-exact assertions on the rendered frame.

The machinery lives under `lib/potion/` — the reversed instruction
table (`Potion.Assembleur`), the cartridge builder (`Potion.ROM`), a
GOOL-style kernel with a vblank heartbeat, OAM DMA from HRAM and one
actor slot (`Potion.Noyau`), and the macro compiler (`Potion.Compilo`).

## The native core — the emulator compiled to RISC-V, by Elixir

The same instruction table that generates the BEAM decoder and Potion's
assembler also generates a **complete native emulator in RV32
assembly**, emitted by plain Elixir. No C, no linker, no compiler
toolchain in the loop: `lib/atomboy/native/` builds a bootable image
out of encoded instructions and runs it under `qemu-system-riscv32`.

Why: the ESP32-C6 port hit 12% of real time under AtomVM, and the wall
was the interpreter, not the silicon — roughly a megabyte of native
interpreter fighting a 32 KB instruction cache. A purpose-built SM83
interpreter is a fraction of that size, so the ceiling moves.

What exists, and how it is checked:

| | |
|---|---|
| `rv32.ex` | the instruction encoder, verified against `riscv64-unknown-elf-as` |
| `asm.ex`, `image.ex` | labels, and a bootable image with no C and no linker |
| `alu.ex` | the flag arithmetic, checked exhaustively — 892,928 cases, compared inside the guest |
| `interp.ex` | all 501 opcodes, dispatched in constant time through a jump table |
| `ppu.ex` | the DMG scanline renderer: dmg-acid2 comes out pixel-identical to the Elixir PPU |
| `machine.ex` | the machine cadence — 154 lines of 456 T-cycles, LY, vblank, timers, joypad |

Everything is validated differentially against the Elixir emulator as
oracle, with the comparison run **inside** the guest so a few hundred
cases cost one boot instead of a serial port full of pictures.

The measurements, under `qemu -icount shift=0` (retired instructions,
not seconds — qemu is not cycle-accurate, so timing it would measure
the host):

| | |
|---|---|
| 22 | RV32 instructions per SM83 instruction |
| 339,517 | instructions per frame, CPU and cadence |
| 976,255 | instructions per frame with the renderer — 58.6 M/s at 60 fps |
| 16,040 bytes | of generated code: 49% of the C6's instruction cache |

Against a 160 MHz C6 that is about 37% of the core at one instruction
per cycle, with the cache half empty. What qemu cannot tell us is the
real IPC on silicon — flash latency, cache misses, branch prediction —
so the number is a green light, not a victory.

And the two compilers meet: `games/hero.gb`, compiled from Elixir by
Potion, **runs and displays on the generated native core**, its frame
byte-identical to the one the BEAM emulator draws.

```sh
mix atomboy.native            # assemble and run the native core under qemu
mix atomboy.native.bench      # the number: RV32 instructions per SM83 instruction
```

Needs `qemu-system-riscv32` and `riscv64-unknown-elf-as` (Homebrew);
without them the native tests exclude themselves and the suite stays
green.

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

On macOS, the nicest way is the native app — `bin/build --fast --app`
produces `burrito_out/Atomboy.app`: a SwiftUI shell (full-bleed pixels
under the window's rounded corners, a Liquid Glass hover HUD, sound
through AVAudioEngine — no ffplay needed) driving the BEAM engine over a
pipe. Drag it to /Applications, double-click, pick a ROM — or open a
`.gb`/`.gbc` file with it. Cmd-, opens Settings: the sound mixer, and
GameShark codes saved per game.

Everywhere else (and for the terminal aficionados), the standalone binary:

```sh
atomboy game.gb                 # terminal renderer
atomboy game.gbc --window      # native window (wxWidgets)
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
| `--window` | native window instead of the terminal |
| `--palette gray` | neutral grays instead of the DMG green |
| `--dmg` | force original Game Boy mode for CGB-flagged ROMs |
| `--save <name>` | save profile — own `.sav`/`.state` per player |
| `--sound` / `--no-sound | force sound on/off |
| `--codes 01FF16D1,…` | GameShark codes, applied every frame |

Sound needs `ffplay` (ships with ffmpeg) on the PATH; without it the game
plays silently.

### Link cable

One side listens, the other calls:

```sh
atomboy argent.gbc --window --listen            # waits on port 7373
atomboy argent.gbc --window --link host:7373    # connects
```

Use `--save` on both sides if they share the same ROM file. Turbo is
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
bin/build --fast         # skip the tests
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
real time with native AOT: the ceiling was the interpreter, not the hardware.

That diagnosis is what the native core above acts on — and it is why the
microcontroller is back on the table rather than filed away as a
curiosity. The AtomVM route asked a general-purpose VM to run an
emulator; the native route generates the emulator itself, which is the
one thing that fits in the cache.
