# The Save & State Library — design

*2026-08-07 — approved direction: engine-owned library, app-native UI (approach A), plus app-native key rebinding.*

## Problem

Every save artifact lands next to the ROM: `.sav`, `.state`, `.caseN.state`,
`.profile.sav`, `.profile.state`. One well-played game leaves half a dozen
sidecar files in whatever folder the ROM happens to sit in. States are
anonymous numbered slots; battery-save profiles exist only as a CLI flag; the
macOS app can trigger saves but shows nothing about them. And a ROM that moves
or is renamed silently orphans everything it had.

## Decisions taken

| Question | Decision |
|---|---|
| Where saves live | Library under the platform's user-data dir, sidecar interop kept |
| What "multiple saves" means | Named states (name + timestamp + screenshot) **and** battery profiles, both first-class |
| Who owns storage | The engine (`Atomboy.Library`); the shell is pure UI over protocol ops |
| Where the UI lives | macOS app only; wx/terminal keep slots 1–9 and `--save`, inheriting the storage silently |
| Key rebinding | App-native Controls tab; engine key maps untouched |

## 1. Identity

A game is identified by its **cartridge header, not its file path**: the title
(`0x134–0x143`, printable ASCII, trailing zeros trimmed) plus the global
checksum (`0x14E–0x14F`). Folder name: sanitized title, dash, checksum hex —
`POKEMON_CRYSTAL-91E2/`. Non-alphanumerics in the title become underscores; a
blank title becomes `UNTITLED`. Renaming or moving the ROM never orphans its
saves; two revisions or hacks with the same title differ by checksum.

## 2. Layout

Root: `:filename.basedir(:user_data, "atomboy")` —
`~/Library/Application Support/atomboy` on macOS, `~/.local/share/atomboy` on
Linux. Overridable with `--library PATH` (all frontends); the app exposes a
folder picker and passes the flag down.

```
<ROOT>/<TITLE-CHECKSUM>/
  game.sav                 # the default profile's battery
  <profile>.sav            # one battery per named profile ("nolan")
  states/
    <profile>/             # states belong to a profile
      slot-1.state         # slots are named states with reserved names
      before-boss.state
      before-boss.meta.json
      before-boss.png      # 160×144 screenshot, engine-written at save time
```

**A slot is a named state named `slot-N`.** One mechanism: slots gain
screenshots and timestamps for free, and keys 1–9 / s / r keep their exact
behaviour in every frontend. `meta.json` carries `name`, `created_at`
(ISO 8601, UTC), `profile`. State file format is unchanged.

## 3. Sidecar interop

* **Adoption** — on the first boot of a game, meaning its library folder does
  not exist yet: a `.sav` next to the ROM is *copied* in; `.state` becomes `slot-1`, `.caseN.state`
  becomes `slot-N`; `.name.sav`/`.name.state` become profile `name`. One-time,
  non-destructive — originals stay where they are.
* **After adoption, the library is the single truth.** No newer-file
  heuristics, ever: they turn save management into a guessing game.
* **Export** — an explicit action ("Export .sav next to ROM", protocol op `E`)
  copies the current profile's battery back beside the ROM for other
  emulators.
* **Fallback** — if the library root is unwritable, behave exactly as today
  (sidecar files), with one line on stderr.

## 4. Engine: `Atomboy.Library`

One new module owning: root resolution, game identity, directory layout,
adoption, export, and named-state CRUD (`list/2`, `save_state/4` with the
frame for the screenshot, `load_state/3`, `delete_state/3`). PNG comes from a
minimal `:zlib`-based encoder (~30 lines); if Potion's existing PNG code fits,
reuse it — decided at plan time.

Wiring: the three frontends swap `Save.path/2` for `Library` paths at boot;
`--save name` keeps its meaning as the profile name, now resolved inside the
library. `Save.load/flush` and the `.state` format are untouched. Rewind and
turbo are untouched.

## 5. Protocol

Output gains one structured record — the first reply in a fire-and-forget
stream:

    <<?J, len::32-big, json::binary-len>>

JSON payload: current game id, current profile, profiles list, and the named
states with metadata (name, timestamp, whether a screenshot exists, and the
absolute path of the png so the shell can load thumbnails from disk).

Input ops (op byte + payload, length-prefixed like `C` where a name travels):

| Op | Payload | Meaning |
|---|---|---|
| `L` | none (2-byte record, dummy byte) | list → `J` reply |
| `K` | len + name | save current state under this name (+ screenshot) → `J` |
| `O` | len + name | load the named state |
| `D` | len + name | delete it (state + meta + png) → `J` |
| `F` | len + name | switch profile — see below |
| `E` | none | export the battery beside the ROM |

**Profile switch is a power cycle**: flush the current battery, reset the
machine to boot state on the new profile's battery — the semantic of handing
the console to the other player. Names are sanitized engine-side
(filesystem-safe, no path separators); saving an existing name overwrites it.

## 6. App: the browser

A Saves sheet, reachable from the HUD, the File menu and ⌘⇧S:

* a thumbnail grid of named states — screenshot, name, relative time — sorted
  newest first; slots appear like any other state;
* Save Current (name field, default suggestion "state-N"), Load, Delete
  (confirmed) per entry;
* a profile picker ("Cartridge: game / nolan / New Profile…") with the
  power-cycle warning;
* Export .sav next to ROM.

Pure `Codable` over the `J` record; thumbnails read from the paths the engine
reported. Keyboard slots stay untouched.

## 7. Key rebinding (app-native)

A Controls tab in Settings: one row per action — Up, Down, Left, Right, A, B,
Start, Select, Turbo, Rewind, Pause, Menu, Save State, Load State — showing
the current key; click a row, press a key, bound. Persisted in UserDefaults
(`reglages.touches`, keyCode → action) with today's bindings as defaults, plus
Reset to Defaults. `Engine.key(_:)` consults the map instead of its hard-coded
switch. Binding an in-use key steals it and highlights the orphaned action so
it is rebound next. Escape stays reserved for settings. The gamepad mapping
stays fixed. wx/terminal keys are unchanged (candidate for the polish pass).

## 8. Errors

* Unwritable library root → sidecar behaviour + stderr note (§3).
* Missing `meta.json` or `.png` → the state still lists (name from filename,
  no thumbnail); never a crash.
* Corrupt state file on load → the existing load-state error path (note in
  title/HUD), library untouched.
* `J` record oversized/malformed shell-side → ignored, UI shows stale list.

## 9. Testing

`Atomboy.Library` carries the suite: identity from synthetic headers
(title/checksum edge cases), layout paths, adoption round-trips in `tmp_dir`
(all four sidecar shapes), export, named-state save/list/load/delete, PNG
magic bytes and dimensions, name sanitization. Protocol handlers stay thin
wrappers over `Library` and are tested through it — the server test's stdin is
not scriptable today, and making it so is out of scope. App UI and rebinding
are exercised by hand.

## Out of scope

Named states in the engine's pixel menu; gamepad rebinding; wx/terminal key
rebinding; cloud/sync anything; automatic sidecar re-export on every flush.

## Success criteria

The nine sidecar files beside the ROMs become one adopted, browsable library;
"nolan" is a menu item, not a flag; a state saved from the couch has a picture
and a name instead of a number; WASD players rebind in ten seconds; and
nothing anyone saved before this lands is lost.
