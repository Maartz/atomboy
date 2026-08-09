# The native core

*The emulator, compiled to RISC-V, by Elixir.*

The instruction table that generates the BEAM decoder and Potion's assembler
also generates a **complete native emulator in RV32 assembly**, emitted by
plain Elixir. No C, no linker, no compiler toolchain in the loop:
`lib/atomboy/native/` builds a bootable image out of encoded instructions and
runs it under `qemu-system-riscv32` — or emits the same code as a blob an
ESP32-C6 application calls as a subroutine.

## Why

The ESP32-C6 port under AtomVM hit 12% of real time, and the wall was the
interpreter, not the silicon: roughly a megabyte of native interpreter
fighting a 32 KB instruction cache. A purpose-built SM83 interpreter is a
fraction of that size, so the ceiling moves. Everything below is that
diagnosis acted on.

## What exists, and how it is checked

| | |
|---|---|
| `rv32.ex` | the instruction encoder, verified against `riscv64-unknown-elf-as` |
| `asm.ex`, `image.ex` | labels and forward references, and a bootable image with no C and no linker |
| `emit.ex` | the third backend: an `%Insn{}` becomes RISC-V instructions |
| `regs.ex` | where each SM83 register lives among the RISC-V 32 |
| `alu.ex` | the flag arithmetic, checked exhaustively — compared inside the guest |
| `interp.ex` | the 501 opcodes, dispatched in constant time through a jump table |
| `bus.ex`, `cart.ex` | memory access, and more ROM than the address space has room for |
| `ppu.ex` | the DMG scanline renderer: dmg-acid2 comes out pixel-identical to the Elixir PPU |
| `apu.ex` | the four voices, stereo s16le at 32,768 Hz, sample-for-sample against `Atomboy.APU` |
| `machine.ex` | the machine cadence — 154 lines of 456 T-cycles, LY, vblank, timers, joypad |
| `blob.ex` | the same core with the boot removed and a calling convention in its place |

Every part is validated differentially against the Elixir emulator as oracle,
with the comparison run **inside** the guest — so a few hundred cases cost one
boot instead of a serial port full of pictures. The native modules are written
clause for clause against their Elixir counterparts on purpose: two emulators
that round differently cannot be compared.

## The measurements

Under `qemu -icount shift=0`, counting retired instructions rather than
seconds — qemu is not cycle-accurate, so timing it would measure the host:

| | |
|---|---|
| 18.0 | RV32 instructions per SM83 instruction, on a register-move loop |
| 27.5 | on a mixed block — loads, stores, arithmetic, control flow |
| 19,576 bytes | of emitted code all told: 59.7% of the C6's instruction cache |

`mix atomboy.native.bench` prints those, along with its own projection: at 160
MHz and one instruction per cycle, roughly seven to eight times a DMG's real
time — **for the CPU alone**, no PPU, no APU, no banking. What qemu cannot tell
us is the real IPC on silicon, so the projection is a green light, not a
victory.

```sh
mix atomboy.native            # size, coverage, and one witness run under qemu
mix atomboy.native --size     # build only, without launching qemu
mix atomboy.native.bench      # the number: RV32 instructions per SM83 instruction
```

Needs `qemu-system-riscv32` and `riscv64-unknown-elf-as` (Homebrew); without
them the native tests exclude themselves and the suite stays green.

And the two compilers meet: `games/hero.gb`, compiled from Elixir by Potion,
runs and displays on the generated native core, its frame byte-identical to the
one the BEAM emulator draws.

## The console on the desk

`esp32/native/` is an ESP-IDF application for the ESP32-C6 with a Waveshare
2.4" ILI9341 panel on four-wire SPI and an I2S amplifier. It embeds the blob
and calls offset 0; what comes back is five words — status, the opcode it
stopped on, T-cycles run, the framebuffer, and the emulated 64 KB. Calling
again continues the same console, because the blob writes its CPU state back
before it returns.

```sh
mix atomboy.native.esp32                  # writes esp32/native/main/blob.bin
mix atomboy.native.esp32 games/pong.gb
```

then, from `esp32/native/`, the usual `idf.py flash monitor`. This is a
different chain from `mix atomboy.esp32`, which flashes AtomVM and runs the
BEAM emulator on the board.

Two lessons the board taught, both recorded in `main/main.c` beside the code
that acts on them:

* **The bus is the budget.** 103,680 bytes a frame at 20 MHz SPI is 41 ms,
  which caps the console at 40% of real time and leaves the music full of
  holes. At 80 MHz it is 10 ms and the panel stops being the limit. The clock
  went down to 20 first and back up only as a measurement — on loose jumper
  wires a fast clock rings and the panel ignores every command it is sent.
* **The sound is the clock.** With the panel no longer the limit the loop
  settled around 13.6 ms against the 16.7 a DMG frame is worth, which means
  the console ran *fast* — invisible behind a non-blocking write, because the
  excess is silently dropped and the meter still reads 99%. A blocking I2S
  write paces the machine to exactly one DMG frame per DMG frame: the DMA
  drains at 32,768 samples a second, no faster and no slower, so there is no
  timer to calibrate and nothing to drift.

Before the panel is believed at all, the frame is checksummed against what the
BEAM emulator draws for the same ROM. Pixels one already trusts are the only
kind worth debugging an SPI bus with.

---

[← back to the README](../README.md) · [Emulator design](design.md) ·
[Emulator features](features.md) · [Potion](potion.md)
