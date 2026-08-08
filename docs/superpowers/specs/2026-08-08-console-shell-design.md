# The console shell — design

*2026-08-08 — approved: skeuomorphic bodies drawn in SwiftUI code, whole-console
portrait layout, reactive but not clickable, turbo speed levels as a rider.
Brainstormed against the field (SameBoy, Delta, RetroArch, OpenEmu): the shell
is Delta's signature charm brought to the Mac, on top of a panel emulation none
of them have.*

## 1. Architecture: where the shell lives

A new file, `rel/macos/Shell.swift`, compiled alongside `Atomboy.swift`
(`bin/build` adds the file to the single `swiftc` invocation). The existing
`MetalView` — shaders untouched — becomes the *screen* of a drawn console: in
shell mode the window's content is the body drawing, with the Metal layer
positioned in the bezel's screen cutout.

* Shell mode is a toggle: **⌘B**, persisted as `reglages.shell`, default
  **on**. Plain frameless mode remains exactly today's window, one keystroke
  away.
* Window aspect follows the mode: 10:9 plain, the body's silhouette ratio
  (≈ 0.61 portrait for DMG) in shell mode. Resizing scales the console
  uniformly. The window stays chromeless and movable-by-background — you drag
  the console. Traffic lights keep their hover behavior on the main window.
  Fullscreen centers the console on black.
* The body follows the panel preset (`reglages.panneau`, no new setting):
  DMG, Pocket and CGB handheld bodies; the `crt` preset gets a living-room TV
  silhouette; the `raw` preset (the default) wears the DMG body — a raw panel
  in a gray shell is fine, and first launch shows the console.

## 2. The bodies, and what makes them alive

**Drawing.** Shared skeuomorphic primitives — `MoldedButton` (radial gradient,
top highlight, drop shadow; pressed variant collapses the shadow, darkens, and
translates 1 pt), `DPad`, `PillButton`, `SpeakerGrill`, `ScreenBezel` (recessed
surround, "DOT MATRIX" script and red/blue stripe on DMG), `PowerLED`. Four
silhouettes compose them: DMG gray/magenta, Pocket silver/black, CGB teal, and
the TV (wood grain, rabbit ears, channel dial, curved glass). All vector
(`Path`, gradients, shadows) — crisp at any size. Per-console geometry lives in
one `BodyLayout` struct (rects as fractions of body size); the screen cutout
the Metal layer needs comes from the same source as the drawing.

**Reactivity.** A `ConsoleState` observable: eight booleans (D-pad, A, B,
Start, Select) plus `powered`. The shell's two input paths — keyboard handler
and GameController callbacks — already forward to the engine's stdin; they
additionally set/clear the booleans (keyDown/keyUp, `isPressed` changes).
Buttons render their pressed variant from that state. The power LED glows while
the engine lives, dims to ember when paused, goes dark when the engine exits;
on the TV body it is the channel dial's pilot light. No mouse interaction on
any drawn control.

## 3. Turbo levels

Settings gains **Turbo speed**: 2×, 4×, 8×, Uncapped — default Uncapped,
which is exactly today's behavior.

* Engine: a capped level *divides the frame deadline* by the multiplier;
  Uncapped keeps the current deadline suspend. Rendering paces the display:
  every Nth frame at N× (~60 fps on screen), 1-in-4 uncapped as today. Audio
  stays discarded during turbo at every level. Turbo remains refused while the
  link cable is plugged.
* Hold semantics without breaking the terminal: the legacy `{:key, :turbo}`
  event still toggles (no key-release events without kitty), while press/release
  events (`+T`/`-T`, already carried by the protocol) engage turbo *while
  held*. The Mac shell switches to hold — Tab and shoulder engage on press,
  release on release. The HUD turbo button stays a toggle: it sends the press
  and withholds the release until clicked again.
* The speed reaches the engine like every persisted setting: a new stdin op,
  sent in the boot catch-up block and on change, plus a `--turbo N` CLI flag
  for terminal parity.

## 4. The settings window fix

The settings window stops inheriting the ghost chrome: standard titled,
closable window — visible close button, ⌘W and Esc close it. The requirement
is "closable like any Mac settings window"; the implementer verifies the exact
mechanism in code.

## Testing

Elixir: unit tests for capped-deadline math, toggle-vs-hold event handling,
link-cable refusal. Swift has no harness — a manual checklist (each body at
three window sizes, preset switching, LED states, keyboard + controller
reactivity, ⌘B persistence, fullscreen, settings closes) plus visual review of
screenshots before sign-off.

## Out of scope

Clickable or draggable controls; CGB shell color variants; a third-party skin
format; the iOS port; slow-motion; pitch-preserved audio during turbo.
