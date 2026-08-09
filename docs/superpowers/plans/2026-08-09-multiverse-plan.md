# The multiverse — implementation plan

*Spec: `docs/superpowers/specs/2026-08-09-multiverse-design.md`. Staffing:
Opus agents build, Fable reviews. Two build tasks in sequence, then the
sign-off.*

## Rules for every agent

- All new code and comments in English; existing French prose stays.
- No bare `mix format` — only touched files.
- Never stage `games/art/*` (pineapple.png stays untracked) or
  `lib/mix/tasks/atomboy.native.esp32.ex`. `git add` explicit paths only;
  on index.lock wait 2s and retry.
- Undo deliberate mutations by reverse edit only — never `git checkout`.
- Elixir acceptance: `mix test` green (1235+). Swift acceptance:
  `swiftc -typecheck -parse-as-library -target arm64-apple-macos14.0
  rel/macos/Atomboy.swift rel/macos/Shell.swift` (allowed warnings: the two
  allowedFileTypes deprecations).
- Commits: one-line poetic English in the repo's voice.

## Task 1 — Four machines in one loop (engine + protocol)

*Files: `lib/atomboy/server.ex`, `lib/atomboy/play.ex` (only if a shared
seam genuinely lives there), new test file.*

The split machinery per spec section 1, the protocol per section 2: the
`%Split{}` context, fork with divider nudges (find the divider's true home
in the CPU state and nudge the internal counter, not the visible 0xFF04
byte), parallel stepping with `Task.async/await` per frame, tagged frames,
focus-gated PCM, commit/abort, the full refusal matrix both ways, the
outbound truth announcement. Op letter chosen against the table; protocol
comment extended.

Tests per spec: null-perturbation CRC proof, divergence on a DIV-reading
fixture ROM (build it in the established fixture style), commit-k
exactness, abort-is-universe-0, lockstep, PCM gating, refusals. Both named
mutations run and killed before commit. Print the measured 4-way step cost
in one test as information.

Beware two standing traps: the `:movie_take` stamp lives inside frozen
maps (Task 3 of the time machine) — forked machines carry whatever the
live map holds, and commit must not manufacture a stale stamp; and no
blocking `:file.read` anywhere near this path (the 8bb9b5d dirty-scheduler
lesson).

## Task 2 — Four consoles on the desk (shell)

*After Task 1. Files: `rel/macos/Atomboy.swift`, `rel/macos/Shell.swift`.*

Spec section 3: the SplitStage of four mini bodies with four Metal screens
fed by tagged frames (the existing MetalView/ScreenView machinery must be
instantiable per universe or the split screens need their own lighter
layer — read the code and choose, justifying in a comment), the
click/double-click/Esc choreography with animation, the truth-driven state
(never optimistic), window re-aspect through the existing layout plumbing,
menu items and their disable matrix, HUD buttons disabled during a split,
shared `ConsoleState` reactivity intact on all four bodies.

Acceptance: typecheck; screenshots of the split stage (idle and focused)
rendered via the headless harness in the scratchpad where feasible, or a
clear statement of what only a live run can show.

## Task 3 — The sign-off

*Maartz's hands: rebuild, ⌘D on a real game (Pokémon battle = the canonical
demo), listen across universes, double-click a future, Esc an abort, judge
60 fps and the choreography. Findings loop back as fixes.*
