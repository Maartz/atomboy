# The console shell — implementation plan

*Spec: `docs/superpowers/specs/2026-08-08-console-shell-design.md`. Staffing:
each task goes to an Opus agent with this plan and the spec as context; Fable
reviews and integrates. Tasks land as separate commits, each green.*

## Rules for every agent

- All new code and comments in English. Settings keys keep the `reglages.*`
  prefix and the engine stays named `atomboy-moteur` (data/bundle compat).
- Do not run a bare `mix format` — the repo was formatted by an older Elixir
  and 1.18.4 recasses ~10 unrelated files. Format only the files you touched.
- The working tree carries unrelated art files (`games/art/…`) and a modified
  `atomboy.native.esp32.ex` — never stage them. `git add` explicit paths only.
- Swift acceptance without Xcode:
  `swiftc -typecheck -parse-as-library -target arm64-apple-macos14.0
  rel/macos/Atomboy.swift rel/macos/Shell.swift`
- Elixir acceptance: `mix test` stays green (935+ tests).

## Task 1 — The settings window learns to close

*Independent. Small. Files: `rel/macos/Atomboy.swift`.*

The settings window currently inherits the main window's ghost chrome (traffic
lights born at `alphaValue = 0`, restored only by the game view's hover
tracking — which the settings window lacks), so it cannot be closed. Find how
the settings window is presented (search `settingsRequested`, the section
comment "Settings (⌘,)") and give it standard titled+closable chrome: visible
close button, ⌘W and Esc both close it. Do not touch the main window's hover
behavior. Acceptance: typecheck passes; manual — open Settings, close it three
ways.

## Task 2 — Turbo grows speed levels (engine)

*Independent. Files: `lib/atomboy/play.ex`, `lib/atomboy/server.ex`,
`lib/atomboy/cli.ex`, tests.*

Today turbo is a toggle that suspends the frame deadline (`play.ex` ~395–425,
660). Changes:

1. Context gains `turbo_speed :: 2 | 4 | 8 | :uncapped`, default `:uncapped`.
   Capped: deadline becomes `frame_deadline / speed` instead of suspended.
   Rendering: render every `speed`-th frame when capped; keep 1-in-4 when
   uncapped. Audio stays discarded during turbo at every level. The link-cable
   refusal is unchanged.
2. Hold semantics, both grammars: legacy `{:key, :turbo}` still toggles
   (terminal without kitty has no releases); `{:press, :turbo}` engages,
   `{:release, :turbo}` disengages. Note `apply_event` currently pattern-matches
   `tag in [:key, :press]` for turbo — split those paths.
3. `--turbo N` CLI flag (2, 4, 8; absent = uncapped) threaded to the context.
4. Server protocol: a new 2-byte stdin op setting turbo speed at runtime
   (pick an unused op byte; grep server.ex for the existing op letters first
   and extend the protocol comment at the top of the file). Value byte: 2, 4,
   8, or 0 for uncapped.

Tests: capped-deadline arithmetic per level, toggle-vs-hold event sequences
(press+release leaves turbo off; legacy key toggles on then off), link-cable
refusal for both grammars, CLI flag parsing. Mutation discipline: before
committing, invert the deadline division and confirm a test fails.

## Task 3 — Turbo grows speed levels (shell)

*After Task 2. Files: `rel/macos/Atomboy.swift`.*

1. Settings gains a "Turbo speed" picker — 2×, 4×, 8×, Uncapped — persisted as
   `reglages.turbo` (Int: 2/4/8, 0 = uncapped, default 0), sent via Task 2's
   op in the boot catch-up block (`~1056`) and on change.
2. Hold semantics: the keyboard path sends press/release for the turbo
   keybind (the protocol already carries `+`/`-` prefixed keys); the
   controller shoulder (`~842`) sends `+T` on press and `-T` on release
   instead of the rising-edge-only toggle. The HUD turbo button keeps toggle
   semantics: first click sends the press and withholds the release, second
   click sends the release.

Acceptance: typecheck; manual — hold Tab speeds up while held at the chosen
multiplier, HUD button latches.

## Task 4 — Shell.swift: the frame before the flesh

*Independent of 1–3. Files: new `rel/macos/Shell.swift`, `rel/macos/Atomboy.swift`,
`bin/build`.*

Scaffolding with a deliberately crude placeholder body (flat gray rounded
rectangle + screen cutout), so the structure is provable before the art:

1. `bin/build` compiles both Swift files (line ~75).
2. `BodyLayout` struct: per-console geometry as fractions of body size —
   body aspect ratio, screen cutout rect, control positions. One instance per
   console (`dmg`, `pocket`, `cgb`, `tv`), DMG-only for now.
3. Shell mode toggle: **⌘B** in the menu bar, persisted `reglages.shell`
   (default on). In shell mode the window aspect locks to the body ratio and
   the content is the body view with `MetalView` placed in the screen cutout;
   plain mode is exactly today's window. Resizing scales uniformly; the window
   stays chromeless and movable-by-background; fullscreen centers the console
   on black.
4. Body selection follows the panel preset (`reglages.panneau` /
   the `?P`/`?N` preset plumbing): raw→DMG, dmg→DMG, pocket→Pocket, cgb→CGB,
   crt→TV — with all four mapping to the DMG placeholder until Tasks 5–7.

Acceptance: typecheck; manual — ⌘B flips between plain window and placeholder
body without disturbing the running game; aspect ratios hold under resize.

## Task 5 — The DMG body and the pulse

*After Task 4. Files: `rel/macos/Shell.swift`, small hooks in `Atomboy.swift`.*

1. Skeuomorphic primitives: `MoldedButton` (radial gradient, top highlight,
   drop shadow; pressed = shadow collapses + darkens + 1 pt translate),
   `DPad`, `PillButton`, `SpeakerGrill`, `ScreenBezel` (recessed surround,
   "DOT MATRIX WITH STEREO SOUND" script, red/blue power stripe), `PowerLED`.
   Pure `Path`/gradient/shadow vector work.
2. The DMG silhouette composed from them: gray body, magenta A/B, rotated
   start/select pills, corner speaker grill — proportions from photos of the
   real thing, geometry into `BodyLayout.dmg`.
3. `ConsoleState` observable: eight booleans (up/down/left/right/A/B/start/
   select) + `powered`. The existing keyboard handler and GameController
   callbacks set/clear them alongside their engine forwarding (keyDown/keyUp,
   `isPressed` edges). Buttons render pressed variants from this state.
4. LED: glowing while the engine runs, ember when paused, dark when the
   engine exits (the shell already observes engine lifecycle for its
   termination handling — reuse that signal).

Acceptance: typecheck; manual — arrows rock the drawn D-pad, controller
presses light the drawn buttons, pause dims the LED. Screenshot for review.

## Task 6 — Pocket and Color

*After Task 5. Files: `rel/macos/Shell.swift`.*

Pocket (silver/black, slimmer, smaller silhouette) and CGB (teal, the
southeast-rotated button pair, its own proportions) composed from the Task 5
primitives, geometry in `BodyLayout.pocket` / `.cgb`. Preset switching swaps
bodies live (the `?P`/`?N` path from Task 4). Acceptance: typecheck;
screenshots of all three handhelds for review.

## Task 7 — The living-room TV

*After Task 5, parallel with 6. Files: `rel/macos/Shell.swift`.*

The `crt` preset's body: wood-grain box, curved-glass screen surround, channel
dial with pilot light (the `powered` LED of this body), rabbit ears. Landscape
silhouette — `BodyLayout.tv` carries its own aspect ratio; the ⌘B window
plumbing from Task 4 must already read the ratio per body, not per mode.
Reactive controls don't exist on a TV; only the pilot light lives. Acceptance:
typecheck; screenshot for review.

## Task 8 — The checklist and the sign-off

*Last. No new code — fixes only.*

Run the manual checklist: each body at three window sizes; preset switching
live; LED states (running/paused/exited); keyboard + controller reactivity;
⌘B persistence across relaunch; fullscreen; settings window closes three
ways; turbo at 2×/4×/8×/uncapped, hold and HUD latch, refused when linked.
Screenshots of every body to Maartz for the lickability verdict. Polish
findings loop back as small fixes; then `bin/build --app` proves the full
bundle still assembles.
