# The panel's last secrets — design

*2026-08-07 — approved scope: all four effects. One engine knob, three
shader passes' worth of physics.*

## 1. The contrast dial (engine + everywhere)

`LCD.compile/4` gains a dial override: 0–100 mapped onto the profile's
density axis, `nil` meaning the preset's own resting point; `raw` has no
panel and ignores it. The asymmetry is already in the dial math — shade 0
slides hardest toward the reflector, shade 3 barely moves — and the ramp
and ghost tables rebuild with the shades.

Protocol: one value op, `<<?G, v>>` — 0–100 sets, anything above returns
the panel to rest. The server recompiles live. `--dial 0-100` on the CLI
gives wx and the terminal the same knob, statically. The app's Screen tab
gains a Contrast slider (persisted as `reglages.contraste`, −1 = default,
replayed at launch) with a Reset button.

Tests assert the promises: turning up darkens every shade, shade 0 moves
more than twice shade 3; turning down lifts toward the reflector; `raw` is
untouched; the colour table follows the dial too.

## 2. Crosstalk + STN mixing (shader)

A new `columns` pass reduces the post-response state to a 160×1 luma
texture (144 samples per fragment). The dots pass then:

* darkens each column by its own dark content — the vertical streaking a
  passive matrix smears under dark sprites — plus a fixed ±1% per-column
  hash gain, time-invariant so it never flickers;
* blends each dot ~12% with the dot above it (row-driven STN), edge rows
  clamped.

Strengths ride per preset in a new uniform lane; zero on `raw` and `crt`.
Pipeline order: respond → columns → dots.

## 3. CGB subpixel strips (shader, cgb preset)

Each dot splits into R-G-B vertical strips. Full amplitude while a strip
spans ≤ 4 device pixels, fading linearly to zero by 8 — the article's
moiré guard, which also keeps 8× from turning into gaudy bars. Gated on
scale ≥ 3 like the grid.

## 4. Aging (shader, all presets, default zero)

An Age slider in the Screen tab (`reglages.usure`, 0–1, shader-only — no
protocol, the uniform reads the preference). At 2.2-gamma scale: hashed
column selection with edge clustering (borders age first), dead columns
reflector-tinted with a length gradient and ~5-pixel soft bands, all
static — the panel's biography, not its mood.

## Uniforms

One new `float4 c` = (stn, crosstalk, subpixel, age), mirrored in MSL; the
dots pass gains the columns texture at index 1.

## Testing

The dial through `lcd_test` (promises, not constants). The shader passes
compile under the metal frontend and are judged by eye — the columns pass
has no CPU-visible output to assert on.

## Out of scope

Aging beyond column dropout (whole-panel yellowing, dead rows); dial in
the engine's pixel menu; crosstalk in the wx/terminal frontends.
