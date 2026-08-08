# The time machine — design

*2026-08-08 — approved: sub-project A of the TAS arc (A: foundation, B: piano-roll
workbench, C: multiverse, D: ghost racing, E: channel surfing). Dual anchors
(power-on and savestate), state-load-while-recording = re-record, movie
machinery as a context module in the Turbo mold. Ground truth verified before
design: snapshots are complete versioned terms, the emulation core touches no
wall clock and no randomness (the link cable is the one nondeterministic
input; MBC3's RTC is unimplemented) — so a movie is an anchor plus a
frame-indexed button log, and replay is exact.*

## 1. The movie: format and module

A new `Atomboy.Movie` module owns the artifact — a versioned term in the
snapshot idiom: `{:atomboy_movie, 1, header, anchor, track}`, written with
`term_to_binary(…, [:compressed])`, extension `.tas`, stored in the game's
library folder.

* **header** — format version; ROM identity (title, header checksum, global
  checksum — a movie refuses to run against the wrong ROM); anchor kind;
  frame count; **re-record count**; the active GameShark codes (they poke
  state every frame, so they are part of the recording's truth); created-at
  and author strings.
* **anchor** — `:boot`, or an embedded snapshot (`{state, ram, apu}`, exactly
  the term `save.ex` already writes for machine snapshots). A boot anchor still embeds the battery RAM
  as it stood at record start (or records its absence): Pokémon from power-on
  plays differently with yesterday's save, so boot-purity means ROM +
  embedded SRAM + button log reproduces everything on any machine.
* **track** — one byte per frame, the eight buttons as a bitmask. An hour is
  ~216 KB raw; the compressed term is far smaller.

## 2. Loop wiring

The play context gains a `movie` field — `nil | {:recording, movie} |
{:replaying, movie, cursor}` — consulted at one seam per frame, the same
pattern `Atomboy.Play.Turbo` set:

* **Recording** appends the frame's joypad byte after input events are
  applied.
* **Replay** overrides the joypad from `track[cursor]`; live game input is
  ignored while system keys (menu, save states, panel, watch) keep working.
  At track end, control returns to the player with a status note.
* **Frame advance** — the first TAS verb: a new event that, while paused,
  runs exactly one frame. Default key `.`, rebindable like every key.
* **Re-record** — while recording, snapshots and rewind entries are tagged
  with their movie-frame index. Loading any of them truncates the track to
  that frame, keeps recording, and increments the counter. Loading a state
  foreign to the current recording is refused with a note.
* **Refusals** — recording and replay are refused while the link cable is
  plugged (honest nondeterminism), the same policy turbo already applies.
  Turbo itself stays allowed: it is pacing, not state, and turbo-during-
  replay is how a movie is fast-forwarded.

## 3. Surfaces

* CLI: `--record file.tas` (record from launch; boot anchor) and
  `--replay file.tas`.
* In-game menu: RECORD MOVIE / STOP & SAVE (savestate anchor when started
  mid-game) / REPLAY.
* Two new server-protocol ops so the Mac shell gets Game-menu items and a
  File → Replay Movie… open panel (op letters chosen against the existing
  op table, protocol comment extended — the Task 2 playbook).
* Status: the terminal status line and the shell HUD show ● + frame count
  while recording, ▶ + cursor/total during replay.

## 4. The export — P1, done properly

`mix atomboy.export run.tas --out run.mp4` (and `.gif`): headless replay at
uncapped speed, video and the PCM audio track piped to ffmpeg (GIF silent by
nature). Deterministic replay makes the export frame-perfect regardless of
encode speed. This mix task is part of sub-project A and is its visible
milestone.

## Testing

The property that defines the sub-project, written before the features:
record a scripted session, replay it, assert every frame's CRC identical.
Plus: replay-twice-identical; a savestate-anchored mid-game movie; a boot
anchor with battery RAM reproducing; re-record truncation correctness; ROM
identity refusal; link-cable refusal for record and replay. Mutation
discipline before each commit: break the joypad override (or the truncation
arithmetic), watch a named test die, revert by reverse edit only.

## Out of scope

The piano-roll editor, greenzone and movie editing (sub-project B); the
multiverse (C); ghost racing (D); channel surfing (E); importing other
emulators' movie formats; TASVideos submission tooling.
