# The glass — design (IN PROGRESS)

*2026-08-10 — a brainstorm paused mid-design, saved so it survives a reboot.
The TAS arc is parked by Maartz's decision this session ("i want to go away
from this TAS thing for now"); the criterion for the next build is "features
that make it cool", with Elixir treated as a strength rather than a tax.
What won: an inspector that lets you find, name, watch, graph, freeze and
edit any byte of a running commercial cartridge — without the game ever
stopping. Working name **the glass**, not yet blessed.*

## 0. Resume here

Sections 1 and 2 below have been presented. **Section 1 is approved**
("yeah"). **Section 2 was presented and not yet answered** — the question on
the table was: *does the division hold up — the engine answers questions
about the past, the shell owns the present?*

Still to write, in order: the names file and the GameShark bridge (3),
refusals and error handling (4), testing (5), then the scope cut and
phasing. After that: spec self-review, Maartz's review of the file, then
the writing-plans skill. No code until the whole spec is approved.

The brainstorming skill's checklist was being tracked as tasks #1-#8;
#1-#3 are done, #4 (present design section by section) is mid-flight.

## 1. What you see and what you do — APPROVED

⌘I opens an **Inspector** window, titled with the cartridge. The game keeps
running behind it, untouched.

Two halves:

* **The grid** (top). WRAM as 128×64 cells, one per byte; HRAM as a thin
  strip beneath; cart SRAM as a third block when the cartridge has any. A
  cell lights when the game writes there and fades over about a second, so
  the grid is a live picture of where the game is *thinking*. Hover reads
  out address and value. This is the part that is *cool*: a Game Boy's whole
  mind is 8 KB, small enough to watch all at once.
* **The question** (bottom). Buttons — *changed / dropped / rose / held
  still* — and a reach: since 0.5s, 2s, 5s, 10s ago. Press one and the grid
  dims to just the addresses that answer, with a list beside it (address,
  was → now). Press *dropped* again after taking another hit and the list
  narrows. Two or three presses is usually one address.
* From any candidate: **name it**. It joins a watch list — name, live value,
  a sparkline of its last 40 seconds, a freeze switch, and a field to type a
  new value into.

**The claim this rests on.** Cheat Engine's scan-filter-scan ritual exists
because it holds one snapshot at a time and must narrow by repetition.
Atomboy remembers: the rewind ring is already there, so the search is a
*retroactive diff over time you already played*. No marking, no ritual, no
passes. That is the Elixir-is-a-strength argument in one feature.

## 2. How it works, and who owns what — PRESENTED, APPROVAL PENDING

**A new module `Atomboy.Glass`, pure functions only** — no process, no state
of its own: extract a region vector from a machine, diff two of them, apply
a filter, encode payloads. `Atomboy.Glass.Map` handles the names file.
Neither knows anything about windows or sockets. `server.ex` is already 1175
lines, so it gets a thin seam and nothing more: one call after a frame, one
clause for the new op family. Terminal `play.ex` is untouched — the watch
and the listener stay as they are, per the app-first rule.

**Heat comes from diffing frames, not from instrumenting writes.**
Instrumenting `CartLoop.ram_write` would put a cost in the hot path that
every player pays forever, for a window usually closed. Diffing consecutive
frames avoids that — and is the better answer anyway, since a write storing
the same value is not interesting to look at. RAM is a flat address map, so
extraction scans the three regions through `CartLoop`'s own read path, so
banking and echo are served exactly as the CPU sees them. **The grid samples
at 30 Hz, not 60** — half the cost, invisible to the eye.

**The protocol follows the library's precedent.** On open, one full baseline
dump; then per sample only the changed bytes, four bytes each (region,
offset, value). The shell holds the whole image from then on, so sparklines
and the fade are computed there — the same doctrine as `?P`: the shell owns
the display, so the shell owns time. Questions about the *past* stay in the
engine, because the ring is the engine's. `<<?I, verb, …>>` in, `<<?I,
len::32-big, json>>` back for candidate lists.

**A freeze is a GameShark code.** It goes into `ram[:codes]` and rides
`CartLoop.poke` at vblank — so frozen cells already travel with save states,
and "export as a code" is free: a named cell prints `01VVLLHH`.

**Reach snaps to real snapshots** (the ring holds one per ten frames), so a
query for "2 seconds" reports the age it actually used — 1.8s or 2.1s —
rather than the round number that was asked for. No silent rounding.

## 3. Judgment calls already made

Stated to Maartz and not contested:

* Searchable space is **WRAM + HRAM + cart SRAM**, not VRAM — variables live
  there, tiles do not.
* Values are **8-bit and 16-bit little-endian** at first. Pokémon's BCD
  counters are a noted follow-up, not v1.
* Names persist in **the game's own library folder** (keyed by header, as the
  save browser already does), not in UserDefaults — a map you build is
  shareable.
* Placement: **its own window** (⌘I), chosen by Maartz over a sidebar, an
  overlay on the glass, or a full-screen toggle. Reason: you must see the
  game while you watch its memory, and a second window leaves the console
  shell, its transparency and the full frame untouched.

## 4. Facts dug up this session (do not re-derive)

* **The rewind ring**: one snapshot every ten frames, ring of 240
  (`play.ex:527`) — **40 seconds of history at 1/6 s granularity, already in
  memory**. This is the diff's reach, for free.
* **RAM is a flat map** keyed by address, with atom keys mixed in (`:codes`,
  `:wram_base`); CGB WRAM banks are served by an offset
  (`cart_loop.ex:321,529,596`).
* **Output ops already taken**: `F` frame, `A` audio, `J` library JSON, `P`
  panel, `R` movie state, `S` multiverse, `U` tagged universe frame. `I` is
  free.
* **The structured-answer precedent** is the library's `<<?J, len::32-big,
  json>>`; the value-op precedent for input is `<<?V, v>>` and friends.
* File sizes for the boundary argument: `server.ex` 1175, `play.ex` 1517,
  `library.ex` 424 lines.
* The core has **one dependency** (Burrito, packaging only) and must stay
  inside AtomVM's OTP subset — no library may be added for this.

## 5. The decision trail — what else was on the table

Seven candidates were put up, each cashing in a specific BEAM strength;
Maartz leaned toward all of them, so they were argued down. They clumped
into two products and a trick:

* **A. The glass console — the machine is open while it runs.** Spine: the
  live inspector (this spec). Neighbours that fall out of the same plumbing
  and become *separate specs later, made cheaper by this one*: **live
  surgery** (hot code loading — edit `ppu.ex` mid-boss-fight and lose no
  frame), **the flight recorder** (which opcode wrote this address, asked
  backwards), **state as a stream** (HP in a shell prompt, a web dashboard).
* **B. The console that travels — the machine is a value.** Spectate and
  share a controller with a friend over Bonjour; mid-frame hand-off between
  machines. Not chosen: cooler to others than to you, and the same class of
  problem as the link cable, which took ten rounds.
* **C. Live surgery alone.** Smallest and sharpest, but shallow.

Recommendation given and accepted: **A, scoped to its spine.** It is the one
you would open weekly rather than demo once, it is the deepest identity
claim ("no C emulator gives you this without a separate debugger build"),
and it turns GameShark codes from magic numbers you look up into something
you discover.

## 6. Still open

* Section 2's division question (see §0).
* The names file format and what exactly "export as a GameShark code" puts
  on the clipboard.
* Refusals: what the inspector does while a movie records or replays (a poke
  breaks determinism — record it or refuse it), while a multiverse split is
  up (*which* universe's memory?), and when SRAM is locked.
* Testing: unit and property coverage, plus the mutation discipline — break
  the diff's filter or the reach-snapping arithmetic, watch a named test
  die, revert by reverse edit only.
* The scope cut. The grid, the retroactive diff, the watch list, freezing,
  the map file and the sparklines are a lot for one plan; candidates for
  phase two are the value-brightness grid mode, SRAM bank awareness, and
  16-bit types.
* The name. **The glass** is a placeholder; Potion was named by Maartz and
  this should be too.
