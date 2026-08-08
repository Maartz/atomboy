# The time machine — implementation plan

*Spec: `docs/superpowers/specs/2026-08-08-time-machine-design.md`. Staffing:
each task goes to an Opus agent with the spec and this plan as context; Fable
reviews and integrates. Tasks land as separate commits, each green.*

## Rules for every agent

- All new code and comments in English. Existing French prose in old files
  stays untouched. UserDefaults keys keep the `reglages.*` prefix.
- No bare `mix format` (older-Elixir formatting; it recasses ~10 unrelated
  files). Format only the files you touched.
- The working tree carries unrelated art files (`games/art/…`) and a modified
  `lib/mix/tasks/atomboy.native.esp32.ex` — never stage them. `git add`
  explicit paths only. On index.lock, wait 2s and retry.
- To undo a deliberate mutation: reverse edit ONLY, never `git checkout
  <file>`.
- Elixir acceptance: `mix test` green (1134+ tests). Swift acceptance:
  `swiftc -typecheck -parse-as-library -target arm64-apple-macos14.0
  rel/macos/Atomboy.swift rel/macos/Shell.swift` (allowed warning:
  allowedFileTypes deprecation).
- Commit messages: one-line poetic English in the repo's voice
  (`git log --oneline -15`).

## Task 1 — The movie as an artifact

*Independent. Files: new `lib/atomboy/movie.ex`, new `test/movie_test.exs`.*

`Atomboy.Movie`: the struct (header, anchor, track), `write/2` and `read/1`
in the snapshot idiom (`{:atomboy_movie, 1, header, anchor, track}`,
`term_to_binary(…, [:compressed])`), ROM identity captured from the cartridge
header (title, header checksum, global checksum — read how `library.ex` keys
games by header and reuse that path) and verified on read against the loaded
ROM (`{:error, :wrong_rom}`). Anchor: `:boot` + embedded battery RAM
(binary or `:none`), or `{:snapshot, state, ram, apu}`. Track: an append-
friendly structure with one joypad byte per frame and O(1) `at/2`; document
the byte's bit order in the moduledoc. Header carries frame count, re-record
count, active GameShark codes, created-at, author. Pure data + IO, no loop
knowledge. Tests: round-trip, wrong-ROM refusal, truncation helper
(`truncate/2` for Task 3), corrupted-file `:error`.

## Task 2 — The loop learns to record and replay

*After Task 1. Files: `lib/atomboy/play.ex`, `lib/atomboy/joypad.ex` (read
only, most likely), `lib/atomboy/cli.ex` (context threading only),
`test/movie_loop_test.exs`.*

The context gains `movie: nil | {:recording, movie} | {:replaying, movie,
cursor}` consulted at ONE seam per frame, in the `Atomboy.Play.Turbo` mold:

1. Recording appends the frame's joypad byte after input events are applied
   — find where the joypad state the CPU will see for the frame is settled,
   and capture exactly that.
2. Replay overrides the joypad from `Movie.at(track, cursor)`; live game
   input is dropped while system events (menu, save states, panel, watch,
   pause, turbo) still work. Track end → back to `nil` with a status note.
3. Frame advance: new event `{:key, :frame_advance}` — while paused, run
   exactly one frame then pause again. Default key `.`, wired through the
   same keybind tables as existing keys (terminal input map; the shell's
   Keybind list is Task 4's job).
4. Refusals: starting record or replay while the link cable is plugged →
   status note, no-op (Turbo's refusal pattern).
5. Status line (terminal): ● + frame count recording, ▶ cursor/total
   replaying — follow how the turbo `»»4×` indicator landed in Task 2 of the
   console-shell plan (commit 6e64b0c).

TESTS — the determinism property is the sub-project: drive the loop
headlessly (the server_test.exs mailbox technique from 6e64b0c) with a
scripted input session on a test ROM, record, then replay, and assert every
frame's CRC identical. Plus replay-twice-identical, track-end handback,
link refusal, frame-advance advances exactly one frame. MUTATION before
commit: make replay read the live joypad instead of the track — the CRC
test must die.

## Task 3 — Re-record: history rewritten while it records

*After Task 2. Files: `lib/atomboy/play.ex`, `lib/atomboy/save.ex`,
`lib/atomboy/library.ex` (whichever actually tags), tests.*

While recording, every snapshot written and every rewind entry carries the
movie-frame index it was taken at (find where rewind entries are pushed —
the shoulder-button ring — and where menu/protocol snapshots go through
`save.ex`; tag without breaking the on-disk snapshot format for
non-recording use — an envelope or a parallel map, implementer's choice,
justified in a comment). Loading a tagged state while recording truncates
the track to that frame (`Movie.truncate/2`), keeps recording, increments
re-record count. Loading a foreign state while recording → refused with a
note. Tests: truncate-and-continue produces a movie whose replay matches a
straight recording of the same final input sequence; counter increments;
foreign-state refusal; rewind-pull during recording re-records the same way.
MUTATION: off-by-one the truncation frame — a test must die.

## Task 4 — The doors: CLI, menu, protocol, shell

*After Task 3. Files: `lib/atomboy/cli.ex`, `lib/atomboy/menu.ex`,
`lib/atomboy/server.ex`, `lib/atomboy/play.ex` (small),
`rel/macos/Atomboy.swift`, tests.*

1. CLI: `--record file.tas` (boot anchor: embed the battery as found on
   disk, or `:none`) and `--replay file.tas`; mutually exclusive, clear
   errors. Boot-anchored replay must reset to power-on before playing.
2. In-game menu: RECORD MOVIE (savestate anchor from the current frame),
   STOP & SAVE (into the game's library folder, timestamped name), REPLAY
   (most recent movie for this game).
3. Server protocol: two new ops chosen against the op table in server.ex's
   protocol comment (grep first, extend the comment — the 6e64b0c
   playbook): start/stop recording, and replay-a-path.
4. Mac shell: Game-menu items (Record Movie / Stop & Save, Replay Movie…
   with an NSOpenPanel filtered to .tas), `.` in the Keybind table for
   frame advance, HUD indicators (● recording, ▶ replaying) in the HUD's
   existing style, driven by a status the engine already emits or a small
   published flag — reuse the turboLatched pattern from 5b4c56a.
5. Swift typecheck + `mix test` green; manual checklist notes for Task 6.

## Task 5 — The export: P1 paid off

*After Task 2, parallel with Task 3/4. Files: new
`lib/mix/tasks/atomboy.export.ex`, tests.*

`mix atomboy.export run.tas --out run.mp4` (also `.gif`): load the movie,
resolve the ROM (argument `--rom`, or refuse with a clear message naming
what it needs), replay headlessly at uncapped speed, pipe RGB24 frames AND
the s16le PCM into ffmpeg (`-f rawvideo` + `-f s16le` two-input mux; GIF
path video-only with a palette pass). ffmpeg discovered on PATH, absence =
clear error. Frame-perfect by construction — assert the replay's final
frame CRC matches a direct replay in a test; the encode itself is smoke-
tested behind an ffmpeg-present guard (excluded tag if absent, the suite
already knows excluded tests).

## Task 7 — The console's own clock (added 2026-08-08 evening)

*After Task 4 (shares server.ex and Atomboy.swift). Files:
`lib/atomboy/cpu/cart_loop.ex`, `lib/atomboy/play.ex`,
`lib/atomboy/movie.ex` (format v1 stays readable), `lib/atomboy/server.ex`,
`rel/macos/Atomboy.swift`, tests.*

Discovered during the arc: the MBC3 RTC (cart_loop.ex `rtc_now/0`) serves
`System.os_time` + the `ATOMBOY_RTC_OFFSET` env var — real wall clock, which
(a) leaves Crystal's calendar events waiting on real days, and (b) breaks
movie determinism for RTC games (the spec's "no wall clock in the core" was
wrong; test ROMs never read the RTC so the Task 2 property didn't catch it).

1. **Runtime offset**: the offset moves from env-var-only into the machine's
   memory map (env var seeds it for compatibility), settable live via a new
   server-protocol op (signed seconds). The RTC latch semantics are
   unchanged.
2. **Virtual time under record/replay**: the movie anchor captures the RTC
   epoch (real time + offset at anchor); while recording or replaying, the
   served "now" derives from that epoch plus the frame counter
   (`frames × 70224 / 4194304` seconds) — never the wall clock. Same movie,
   same clock, every replay. Movie format: additive header field, old
   movies read fine (epoch absent → replay still virtualizes from the
   file's created_at, documented).
3. **SwiftUI**: Settings gains a "Console clock" control — a DatePicker
   ("the console believes it is…"), a "real time" toggle to snap back, and
   a +1 day nudge button, persisted PER GAME the way GameShark codes are
   (`codes.*`-style keying), sent on boot catch-up and on change.
4. Tests: an RTC test ROM (write one in the fixtures style: latch, read,
   paint seconds to the background) proving offset arithmetic, latch
   freezing, and — the point — that a recorded RTC-reading session replays
   with identical frame CRCs. Mutation: make replay serve the wall clock —
   the new determinism test must die.

## Task 6 — The checklist and the sign-off

*Last. Fixes only.* Record a real session (a commercial ROM by hand),
re-record mid-way, stop, replay it — watch it reproduce; frame-advance
through an input-sensitive moment; export the movie to MP4 and GIF and eyes
on both; boot-anchor purity check: copy the .tas to a fresh checkout-like
state and replay from ROM + file alone; link-cable refusals; the shell's
menu items and HUD badges. Screenshots and the exported MP4 to Maartz for
the verdict.
