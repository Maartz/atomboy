# The Mac-citizen pass — design

*2026-08-07 — approved scope: all four items. Shell-only; the engine and the
protocol are untouched.*

## Problem

The shell holds up against the HIG checklist in places — Game menu, document
types, Settings on ⌘, — and falls short in four: no screenshots at all, no
window-scale presets, no reset and no restraint in the background, no drop
target and no VoiceOver labels on the image-only controls.

## 1. Screenshots

The `Engine` retains the last frame it drew (it receives every one; one
`Data` reference kept, nothing copied). Two commands:

* **Copy Screen — ⌘C**, replacing the Edit menu's pasteboard group: nothing
  else in an emulator is copyable, so the standard key does the natural
  thing. 3× nearest-neighbour — paste-ready.
* **Save Screenshot — ⌥⌘S**, Game menu: 1× native PNG (pure pixels,
  archival) written to `~/Pictures/Atomboy/<Game> — <timestamp>.png` via
  `NSBitmapImageRep`. The folder is created on first use.

Both no-op harmlessly with no game running. Frames arrive with the panel's
colours already applied, so screenshots carry the chosen panel.

## 2. View menu

Scale presets **1×–5× on ⌥⌘1…⌥⌘5** (slots keep ⌘1–9), each setting the
window's content size to exactly `160×144×N` — which the shader's integer
scale then fills edge to edge, no letterbox. Fullscreen is a verification
item, not code: the system provides it and the Metal pass letterboxes.

## 3. Reset and background pause

* **Game → Reset — ⌥⌘R**: the `F` op with the *current* profile — a power
  cycle on the same battery, exactly the hardware button. The engine flushes
  the battery first, so no confirmation dialog.
* **Pause in background** — General setting, on by default
  (`reglages.pauseFond`): the shell sends `P` on resign-active and again on
  become-active, guarded by its own flag. Safe because nothing can toggle
  pause while the app has no keyboard focus.

## 4. Drop and accessibility

* `.onDrop` of file URLs on the game view: `.gb`/`.gbc` launches, anything
  else is refused. Dock drop already works through the declared document
  types.
* VoiceOver labels on every image-only control: the HUD's buttons, the state
  cards' trash button.

## Testing

Menus, drop, fullscreen and VoiceOver by hand; the PNG path is pure AppKit.
The Elixir suite must stay green untouched — no engine change is part of
this pass.

## Out of scope

Video recording; wx/terminal parity for any of it; help-menu content.
