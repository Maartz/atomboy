# The multiverse — design

*2026-08-09 — approved: sub-project C of the TAS arc. ⌘D ("Duplicate") forks
the running game into four live universes — same buttons, different luck —
shown as four mini consoles; click to listen, double-click to make one real.
Fork lives inside the BEAM: one engine, four machines. App-first per the
standing rule; the terminal gets no split.*

## 1. The engine: one loop, four machines

The server context gains `split: nil | %Split{machines: [m0, m1, m2, m3],
focus: 0..3}` — a machine being the `{state, ram, apu}` trio a snapshot
freezes.

* **Fork** copies the live machine four times (immutable data — four
  assignments) and nudges each copy's internal divider counter by a distinct
  offset (0, +17, +37, +59). Universe 0 is the unperturbed original; the
  others draw different luck because game RNG feeds on DIV timing.
* Per frame: the same joypad is applied to all four, the machines step **in
  parallel** (`Task.async` — four scheduler cores), four tagged frames go
  out, PCM flows from the focused universe only.
* **Commit k** keeps machine k and drops the split. **Abort** commits
  universe 0 — by construction the future that would have happened anyway.
* Refusals, both directions: while split — ⌘D again, movie ops, save/load
  states, rewind, and turbo are refused with a note (each hides an "in
  which universe?" ambiguity v1 does not need); a fork while a take records
  or replays is refused; the link cable refuses as it does everything else.
* Performance: 4× emulation + rendering at 60 fps, parallel stepping. If a
  machine cannot hold it, the designed fallback is unfocused universes
  rendering every other frame — emulation never degraded.

## 2. Protocol

* One new inbound op letter (chosen against the op table, comment
  extended), value-coded: fork / focus k / commit k / abort.
* An outbound split-state announcement in the `?R` truth-op style (state +
  focus), so the shell is never optimistic — a refused fork never changes
  the UI.
* During a split, frames leave tagged with their universe (a new outbound
  tag: universe byte + RGB payload). The bare `F` frame is untouched for
  normal play; `A` (PCM) is unchanged — the engine sends only the focused
  universe's sound.

## 3. The shell: four consoles on the desk

* On the split announcement, the stage swaps to four mini bodies — the
  current preset's body at ~45% scale in a loose 2×2 on the transparent
  window, each with its own Metal screen fed by its universe's tagged
  frames, each running the full shader pipeline. The window re-aspects for
  the split through the existing per-layout plumbing.
* Input is shared, so all four drawn D-pads rock in unison — `ConsoleState`
  already drives every body; this comes free and must not be broken.
* Choreography: **click** = focus (sound switches, LED brightens, subtle
  scale-up); **double-click** = commit (the chosen console animates to
  center and full size, the others fade, the window re-aspects to single);
  **Esc** = abort, the same collapse onto universe 0.
* Menu parity: Game → "Split Reality" (⌘D); during a split, "Commit This
  Future" and "Abort Split". ⌘D disabled while a movie runs, while linked,
  while already split. HUD movie/save buttons disabled during a split.

## Testing

* The null-perturbation proof: universe 0 of a split run CRC-matches an
  unsplit run frame for frame.
* Divergence proof on a DIV-reading test ROM (paints RNG-derived pixels):
  universes 1–3 differ from 0.
* Commit k lands exactly machine k's state; abort lands universe 0;
  lockstep — all four always at the same frame count; PCM only from focus;
  the refusal matrix in both directions.
* Mutations: drop the divider nudge (divergence test must die); swap the
  commit index (commit test must die).
* Performance: measured per-frame cost of the 4-way step, printed —
  informational; the manual sign-off judges 60 fps on the real Mac.
* Shell: typecheck, choreography verified by hand with screenshots.

## Out of scope

Nested splits; 2- or 8-way variants; per-universe input (the "choices"
mode); splits during takes; split persistence across relaunch; terminal
front-end support.
