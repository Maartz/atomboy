# Emulator design

*How the thing is built, and why it is built that way.*

The unusual bet is that **the emulated CPU is BEAM code**. The SM83 decoder is
not written by hand — it is generated from a data table into two backends, one
readable and one fast, and the two are held together by a test rather than by
discipline. Everything else (PPU, APU, MBCs, link cable) is plain immutable
Elixir on top of it.

## How the CPU is organized

| | |
|---|---|
| `cpu/table.ex` | **what you edit** — the instructions, as pure data |
| `cpu/insn.ex` | the struct describing one instruction (compile time only) |
| `cpu/gen.ex` | translates an instruction into function clauses |
| `cpu/alu.ex` | the flag primitives both backends share |
| `cpu.ex` | hosts the generated oracle |
| `cpu/loop.ex`, `cpu/cart_loop.ex` | the generated fast loops (flat / cartridge semantics) |
| `cpu/state.ex` | processor state |

`Table` describes *what*, `Gen` decides *how* — and it decides it twice:

* **the struct backend** — `exec(opcode, %State{}, mem)` returning `{state,
  mem, cycles}`. One allocation per instruction and an observable state after
  each one: this is the oracle. The SM83 vectors validate it, and debugging
  happens here.
* **the fast loop** — the registers travel as function arguments, every clause
  ends in a tail call to the next fetch, and nothing is built until the cycle
  budget runs out.

Two backends rather than one, for a measured reason: on native AtomVM the
struct loop topped out at ×1.21 over interpreted — all the time going into the
map BIFs the native compiler does not compile — while the map-free probe gave
×43. The struct's comfort stays where the state gets read; the speed goes where
nothing gets read. The semantics are still written only once, because both
emitters share the same table and the same ALU primitives.

`CartLoop` is the same skeleton with cartridge semantics: writing below 0x8000
does nothing (on real hardware those writes talk to the bank controller), and
reading below 0x8000 goes straight into the binary without consulting the
writes map — so fetching in the ROM region, the overwhelming majority of
fetches, skips a map lookup entirely.

Adding an opcode family means entries in `table.ex` and `body/1` clauses in
`gen.ex`. The fast loop is never tested directly: it inherits correctness from
the oracle through cross-equivalence on random programs — state, memory and
cycle counts must match exactly, exceptions included.

The same table feeds two more consumers: Potion's assembler
([Potion](potion.md)) and the RV32 emitter ([the native core](native.md)). Three
backends, one description of the instruction set, and no way for them to drift
apart.

## Testing philosophy

Per-opcode vectors first: a failure names the opcode and the bit, where a test
ROM only says "failed". Roughly 500,000
[SingleStepTests](https://github.com/SingleStepTests/sm83) vectors run against
the oracle.

Test ROMs come second, for what unit vectors cannot see — sequencing, timers,
interrupts, rendering: blargg's `cpu_instrs`, and the
[dmg-acid2](https://github.com/mattcurrie/dmg-acid2) /
[cgb-acid2](https://github.com/mattcurrie/cgb-acid2) pair, whose output is
frozen as golden CRCs.

Cross-equivalence covers what neither can: the fast loops against the oracle on
random programs. The link cable is tested against real sockets, and was
debugged against the pokegold/pokecrystal disassemblies as the protocol oracle.

**The mutation discipline** rides on top of all of it, before each commit:
break the thing the feature is supposed to guarantee — the joypad override, the
truncation arithmetic, the divider nudge — watch a *named* test die, and revert
by reverse edit only. A test that does not die was not testing the feature. The
design notes under `docs/superpowers/specs/` name the mutation each arc owed.

## The screen is a panel, not a palette

A Game Boy frame leaves the PPU as an index — a shade from 0 to 3, or a colour
in RGB555. What the player saw was that index *through a screen*: a reflective
STN panel with its own gamma, its own warmth, its own dial. The `#9BBC0F` green
everyone quotes is a myth of the web; photographs of real units show a far
greyer, far warmer thing.

`Atomboy.LCD` models the panel as a chain of per-pixel operations — contrast
dial, gamma, saturation, warm bias, contrast, brightness, black lift — and then
*throws the chain away*. Every step is a function of the pixel's value alone, so
the whole thing collapses into a table: four colours for a DMG frame, thirty-two
thousand for a colour one. Compiled once at boot, the panel costs nothing per
frame, and the terminal, the wx window and the macOS shell all get it for free.

Five presets — `raw`, `dmg`, `pocket`, `cgb`, `crt` — where `raw` is no panel
at all.

**The response curve** is the one temporal effect that still lives on the CPU
side. A pixel does not jump to its target, it approaches it exponentially:
quickly when darkening (τ ≈ 21 ms, the cell is driven), slowly when brightening
(τ ≈ 61 ms, it merely relaxes). The asymmetry is the point — most emulators
that model ghosting at all have it backwards, and the reversed version reads as
input lag where the real thing reads as softness. The state is a float per
pixel, because bytes would stall: a step smaller than half a shade rounds to
nothing and the pixel never arrives.

Two effects are *not* functions of the pixel alone or of its history, and live
on the GPU instead, as three Metal fragment passes in the macOS shell:

1. **`respond`** — the response curve at 160×144.
2. **`columns`** — reduces the responded frame to a 160×1 luma texture, the
   input the next pass needs to know what each column is carrying.
3. **`dots`** — at *display* resolution: the dot grid with the reflector
   showing through the gaps, the vertical streaking a passive matrix smears
   under dark sprites, the ~12% row-driven STN blend with the dot above, the
   CGB's split into R-G-B subpixel strips (faded out as the strips approach
   the pixel grid, so 8× does not turn into gaudy bars), and optional aging —
   hashed dead columns, edges first, the panel's biography rather than its
   mood.

The constants are empirical and chosen by eye against photo-matched palettes.
The one set with a real pedigree is the colour matrix, verified coefficient for
coefficient against ares' `gb/ppu/color.cpp`.

## The engine behind a pipe

The macOS app is not a reimplementation. `Atomboy.Server` runs the ordinary
emulator with stdout as its display and stdin as its controller, and the
SwiftUI shell is a client of that: it sends length-prefixed op records and
receives tagged frames, PCM, and structured status replies.

That seam is what keeps the app honest. A feature exists in the engine first
and reaches the app as a protocol op — panel preset, contrast dial, turbo
speed, save library, movies, the clock, the split — which is also why the
terminal front end keeps most of them for free, and why the app can never
believe something the engine refused. Truth ops are the rule: the shell does
not optimistically flip its own UI, it waits for the engine to announce the new
state.

The split — four universes running the same buttons — is the sharpest example
of the shape paying off. Each universe is its own process owning its own
machine, because a memory map is tens of thousands of keys and the BEAM copies
a map whole every time it crosses between processes. Stepping four universes in
four short-lived tasks copied four maps in and four back out every frame.
Owning the machine in the process costs one copy at the fork and one at the
commit; in between, what travels is a pad byte one way and refcounted binaries
the other. Each future keeps its own memory, and only the pictures travel.

## Building and testing

```sh
mix atomboy.corpus         # fetch SM83 vectors (~160 MB) + test ROMs, once
mix test                   # ~500,000 vectors + cross-equivalence + goldens
mix test --include blargg  # the cpu_instrs ROMs on top
```

```sh
bin/build                  # tests, then binaries in burrito_out/
bin/build --fast           # skip the tests
bin/build --install        # also copy to ~/.local/bin/atomboy
bin/build --app            # also assemble Atomboy.app (macOS, needs swiftc)
bin/build --release        # signed, notarized, stapled Atomboy.zip (implies --app)
bin/play game.gb           # play straight from the repo, right VM flags and all
```

`--release` signs the engine and the bundle with a Developer ID Application
identity (auto-detected, `ATOMBOY_SIGN_ID` overrides) under a hardened runtime
with the entitlements the BEAM's JIT needs, submits to `notarytool` under the
keychain profile in `ATOMBOY_NOTARY_PROFILE`, staples, and re-zips. The result
AirDrops to any Mac and opens clean.

With Docker, nothing to install:

```sh
docker build --output type=local,dest=burrito_out .
```

Pass `--build-arg ATOMBOY_SHA=$(git rev-parse --short HEAD)` to stamp the
version.

The workshop tasks:

| Task | |
|---|---|
| `mix atomboy.play rom.gb` | play from the repo (`--frames`, `--dump` for harnesses) |
| `mix atomboy.screen rom.gb [n]` | render n frames, `--debug` for blank-screen autopsies |
| `mix atomboy.progress` | opcode coverage grid for both tables |
| `mix atomboy.bench [n]` | CPU throughput in instructions/s |
| `mix atomboy.export run.tas --out run.mp4` | replay a movie headlessly into a file |
| `mix atomboy.live games/pong.exs` | a Potion game, recompiled under the running console |

## The AtomVM heritage

Atomboy started life targeting [AtomVM](https://www.atomvm.net/) on ESP32 —
that is why the CPU is generated, why the memory API never changed shape, and
why `mix atomboy.atomvm` (packages and runs the app on a generic_unix AtomVM
build) and `mix atomboy.esp32` (flashes an ESP32 or ESP32-C6, with a riscv32
AOT pipeline) still exist and work.

The ESP32-C6 POC reached 12% of real time with native AOT, and the diagnosis
was that the ceiling was the interpreter, not the hardware. That diagnosis is
what [the native core](native.md) acts on — and it is why the microcontroller
is back on the table rather than filed away as a curiosity. The AtomVM route
asked a general-purpose VM to run an emulator; the native route generates the
emulator itself, which is the one thing that fits in the cache.

---

[← back to the README](../README.md) · [Emulator features](features.md) ·
[Potion](potion.md) · [The native core](native.md)
