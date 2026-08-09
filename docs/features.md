# Emulator features

*Everything you can do while a game is running. The macOS app is the product,
so it comes first; the terminal and the wx window inherit most of it, and where
they do not, it says so.*

## The console on your desk

The app draws a console around the screen — **⌘B**, View → Console Body, on by
default. Four bodies, chosen by the panel preset rather than by a second
setting, because the screen and the plastic around it are one decision: the
DMG's gray, the Pocket's silver, the CGB's teal, and a living-room television
for the `crt` preset. `raw`, the default panel, wears the DMG body: a bare
panel in a gray shell is still a Game Boy, and first launch ought to show a
console.

They are drawn rather than photographed — vector paths, gradients and shadows,
laid out from a body's real millimetres divided by its case, so they stay crisp
at any window size. They are also alive: the D-pad rocks and the buttons sink
under your thumb, whether the input came from the keyboard or a gamepad, and
the power LED glows while the engine lives, dims to an ember on pause, and goes
dark when it exits. Nothing on the body is clickable — it reacts, it does not
receive.

⌘B off is the plain window: full-bleed pixels under the window's rounded
corners, one keystroke away.

**View → Scale 1×–5× (⌥⌘1…⌥⌘5)** sets the window to exactly 160×144×N, which
the shader's integer scale then fills edge to edge.

## The panel

Settings → Screen picks the screen the game is seen through, live, no restart:

| | |
|---|---|
| Raw | the pixels, straight |
| DMG | the 1989 green, ghosting and all |
| Pocket | the FSTN gray, tighter |
| Color | the CGB glass |
| CRT | the Super Game Boy's television |

Under it, two sliders. **Contrast** is the wheel under the DMG's thumb — up
toward ink, down toward the bare reflector — with a Reset that hands the panel
back its own resting point. **Age** is a panel that lived a life: dead columns
creep in from the edges, zero being factory-fresh.

The terminal and the wx window get the same panels statically, with `--panel
dmg|pocket|cgb|crt|raw` and `--dial 0-100`; the dot structure and the crosstalk
are the GPU's and stay in the app. What the panel model actually models is in
[the design page](design.md#the-screen-is-a-panel-not-a-palette).

## Saves

Every game gets a folder in the library, keyed by its **cartridge header** —
the title plus the global checksum — so renaming or moving a ROM never orphans
what it had. On macOS that is `~/Library/Application Support/atomboy`, on Linux
`~/.local/share/atomboy`, and `--library PATH` overrides it. The first time a
game boots, any `.sav` and `.state` files sitting next to the ROM are adopted
in, non-destructively; after that the library is the single truth.

* **Save State ⌘S / Load State ⌘R**, with **State Slot 1–9** on ⌘1…⌘9. A slot
  is just a named state called `slot-N`, so it carries a timestamp and a
  screenshot like any other.
* **Saves… ⌘⇧S** opens the browser: a grid of named states with their
  thumbnails and relative times, Save Current under a name of your choosing,
  Load, Delete.
* **Profiles** let two players share one ROM — each with its own battery.
  Switching profile is a power cycle, which is exactly what handing the console
  to the other player means. On the CLI it stays `--save <name>`.
* **Export .sav next to ROM** copies the battery back out for other emulators.

## Rewind, turbo, and time in general

* **Rewind** — hold the bound key (Delete by default, Backspace in the
  terminal) and the game walks backwards through about forty seconds of
  history.
* **Turbo** — Tab, or ⌘T, or the HUD's fast-forward button. Settings → General
  picks the speed: **2×, 4×, 8×, or Uncapped**. Held on the keyboard and on a
  gamepad shoulder; latched from the menu item and the HUD button, which cannot
  hold a key down. Sound stays out of the way at every speed, and turbo is
  refused while the link cable is plugged — the protocol is a paced duet.
* **Frame Advance** — `.`, or ⌘. in the menu. While the game is paused it buys
  exactly one frame and closes the pause again behind it.

## The time machine

A take is a `.tas` file under `movies/` in the game's library folder: a header, an anchor, and
one byte per frame holding the eight buttons. Because the emulation core
touches no wall clock and no randomness, that is enough to reproduce the run
exactly — replay is not approximate, it is the same frames.

* **Record Movie ⇧⌘R** (or the HUD's red dot, or RECORD MOVIE in the in-game
  menu) starts a take on the machine as it stands. The same key stops it and
  files it. The anchor is power-on if you started from boot, otherwise a
  snapshot embedded in the movie itself; a boot anchor still carries the
  battery RAM as it stood, because Pokémon from power-on plays differently with
  yesterday's save.
* **Replay Movie…** opens a `.tas` and hands the buttons over. Live input is
  ignored while it runs; the system keys — menu, save states, panel — keep
  working, and turbo is how you fast-forward a movie.
* **Re-recording** is the trick that makes it a tool rather than a curiosity:
  load a state while recording and the take is *truncated to that frame* and
  keeps going. Everything after it never happened, and the re-record count goes
  up by one. A state that belongs to some other recording is refused.
* **Export Movie… ⌘⇧E** picks a `.tas` and a destination, and renders it to
  **MP4** (with sound) or **GIF** (silent, by nature) through ffmpeg. It
  launches a second engine beside the one you are playing, so the game does not
  stop while the film is developed.
* The movie refuses to run against the wrong ROM, and recording and replay are
  both refused while the link cable is plugged: honest nondeterminism.

The terminal has the same machinery: `--record run.tas`, `--replay run.tas`,
and `--replay run.tas --export run.mp4`, plus `mix atomboy.export run.tas --out
run.gif` for a headless render. The status line and the HUD both show ● with a
frame count while recording and ▶ with a cursor while replaying.

## The console's clock

Settings → **Clock**, per game. The toggle keeps the console on real time; turn
it off and a date picker tells the cartridge what hour it believes it is, with
a +1 day button for the games that want to be slept on. During a take the panel
locks: the recording owns the clock, deriving its hour from its anchor and its
frame count, so the same movie tells the cartridge the same hour on every
replay.

## The multiverse

**⌘D** — Game → Split Reality — forks the running game into **four live
universes**. They take the same buttons, so all four D-pads rock in unison, but
each one's divider counter is nudged by a different offset, and game RNG feeds
on divider timing: same input, different luck. Universe 0 is the unperturbed
original, the future that would have happened anyway.

The window becomes four small consoles on a desk, each with its own screen
running the full shader pipeline.

* **Click** one to listen to it — sound follows focus.
* **Double-click** to commit: the chosen console grows into the only one left,
  and its machine is now the machine.
* **Esc** aborts, collapsing onto universe 0. So do Game → Commit This Future
  and Abort Split, for the hand that would rather read the verbs than know
  them.

While four machines run, anything that would have to answer "in which
universe?" is refused at the engine — another fork, movies, save and load
states, rewind, turbo — and the menu items and HUD buttons grey themselves out
from the engine's own announcement rather than from a guess. A fork is likewise
refused during a take, and while the cable is plugged. The split is app-only;
the terminal does not get one.

## The link cable

Two copies of atomboy trade over TCP, resolved at scanline granularity with
hardware-true transfer pacing — verified with the hardest client there is:
complete Pokémon gen-2 trades through the Cable Club, both directions,
including re-trading a link-received Pokémon.

**Game → Link Cable… (⌘L)** opens the sheet. Hosting relaunches the game
listening on port 7373 and publishes a Bonjour service named after your Mac and
the game; joining lists the consoles it can see on the network and connects to
the one you click. The cable is a boot-time affair on real hardware and here
too, so plugging it in relaunches the ROM — the battery is safe in the library.

From a terminal:

```sh
atomboy argent.gbc --window --listen            # waits on port 7373
atomboy argent.gbc --window --link host:7373    # connects
```

Use `--save` on both sides if they share the same ROM file.

## Screenshots

* **Copy Screen ⌘C** — the frame at 3×, nearest-neighbour, on the pasteboard.
  Nothing else in an emulator is copyable, so the standard key does the natural
  thing.
* **Save Screenshot ⌥⌘S** — a 1× PNG into `~/Pictures/Atomboy/`, pure pixels,
  archival.

Both carry the panel you are playing through, because frames arrive with its
colours already applied.

## Controls

Gamepads are picked up as they connect, through the Game Controller framework —
no configuration, and the drawn body reacts to them like it does to the
keyboard. D-pad or left stick walks, A and B are A and B, Menu is Start and
Options is Select, the left shoulder rewinds and the right shoulder (or
trigger) holds turbo, X saves a state and Y loads one.

Settings → **Controls** rebinds the keyboard: one row per action — Up, Down,
Left, Right, A, B, Start, Select, Turbo, Rewind, Pause, Frame Advance, Settings
— click a row, press a key. Binding a key that is already taken steals it and
leaves the old action showing an em dash until you rebind it. There is a Reset
to Defaults.

The terminal's keys are fixed:

| Key | | Key | |
|---|---|---|---|
| Arrows | D-pad | Esc / `m` | menu |
| `x` | A | `s` / `r` | save / load state |
| `c` | B | `1`–`9` | pick state slot |
| Enter | Start | Backspace (hold) | rewind |
| Space | Select | Tab | turbo |
| `p` | pause | `.` | frame advance |
| `q` | quit | | |

On Ghostty, kitty or WezTerm the kitty keyboard protocol gives real key
releases, so diagonals and A+direction chords work as they do on hardware;
elsewhere the terminal falls back to ANSI half-blocks and press-only keys.

## The rest of the settings

**General** holds resume-on-launch, pause-in-background, and the turbo speed.
**Audio** is the mixer: master volume and each of the four voices. **GameShark
Codes** are stored per game and applied every frame; on the CLI they are
`--codes 01FF16D1,…`.

**Esc** opens the app's own panel on the Mac. In the terminal and the wx
window, Esc opens the in-game menu instead — drawn into the Game Boy frame
itself, so it looks the same in both: RESUME, SAVE STATE, LOAD STATE, RECORD
MOVIE, REPLAY MOVIE, STATE SLOT, PALETTE, PANEL, MIXER with its four voices,
BACK, QUIT. Navigate with the D-pad, confirm with A, close with B.

## Command-line options

| Option | |
|---|---|
| `--window` | native window (wxWidgets) instead of the terminal |
| `--panel raw\|dmg\|pocket\|cgb\|crt` | the panel the frame is seen through |
| `--dial 0-100` | the contrast wheel |
| `--palette gray` | neutral grays instead of the DMG green |
| `--dmg` | force original Game Boy mode for CGB-flagged ROMs |
| `--save <name>` | the battery profile to play on |
| `--library <path>` | where the library lives |
| `--turbo 2\|4\|8` | capped turbo speed (default uncapped) |
| `--codes 01FF16D1,…` | GameShark codes, applied every frame |
| `--record <file.tas>` / `--replay <file.tas>` | write or read a take |
| `--export <out.mp4>` | with `--replay`, render instead of play |
| `--listen <port>` / `--link <host:port>` | the cable, either end |
| `--sound` / `--no-sound` | force sound on or off |
| `--scale <n>` | window scale |

Sound in the terminal and the wx window needs `ffplay` on the PATH; the app
has its own audio through AVAudioEngine and needs nothing.

---

[← back to the README](../README.md) · [Emulator design](design.md) ·
[Potion](potion.md) · [The native core](native.md)
