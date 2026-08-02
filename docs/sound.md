# Sound in Potion

The console has four channels. Potion spends all of them, and the split is the
first thing to know because everything else follows from it:

| channel | hardware | who owns it |
|---|---|---|
| 1 | pulse, with a frequency sweep | `music` — the lead |
| 2 | pulse | `music` — the harmony, **borrowed by `beep`** |
| 3 | wave — 32 programmable samples | `music` — the bass |
| 4 | noise — a clocked shift register | `noise` |

Two pulses and the wave carry the music; the noise carries the knocks. Channel
2 is shared, and the sharing is settled by letting it happen rather than by
coordinating anything: a `beep` takes the harmony's voice for as long as it
lasts, and the harmony comes back at its next step, because the next note
simply writes over the effect. That is what a Game Boy game sounds like — four
channels, and more than four things to say.

---

## Sound effects

Two statements, both fire-and-forget: they write a handful of registers and the
hardware sees the sound out. Nothing is kept, so a `beep` inside an `if` is a
sound effect and the frame after it has nothing to remember.

```elixir
beep(:c5)        # a note on channel 2 — :c2 up to :b7, sharps as `cs`
noise(:hit)      # a knock on channel 4 — :tick, :hit, :thud, :boom
```

**`beep`** strikes a note at full volume and lets the envelope walk it down —
about a quarter of a second from full to silence. The console has no pitch
register: it has an eleven-bit number `x` where `f = 131072 / (2048 - x)`, and
the note table is that formula run backwards at compile time. Below C2 the
number would be negative, so the range ends there and a note past it is refused
by name.

**`noise`** has no pitch at all — channel 4 is a shift register, and what a
game chooses is how *coarsely* it is clocked. The four names are that
continuum, and it is measured rather than described: counting how often the
output changes value in a frame,

```
:tick   295 changes/frame    bright, short — a wall tapped
:hit     44                  a knock — a paddle struck
:thud    12                  low, a beat longer
:boom     5                  the lowest rumble the chip has
```

Numbers were deliberately not exposed. `noise(4, 2)` is a register spelled out,
which an author picks blind — and this project has already paid a full
afternoon for one number chosen that way.

---

## Music

```elixir
@motif "c4 e4 [g4 a4 c5] . | c5 . . ."

music :theme,
      [
        lead: @motif <> " " <> @motif,
        harmony: "e3 g3 c4 . | e3 g3 c4 .",
        bass: "c2 . . . | g1 . . ."
      ],
      beat: 10,
      duty: :eighth,
      gap: 3,
      vibrato: :gentle,
      envelope: :pluck

play(:theme)     # started once; the kernel keeps the beat
silence()        # and stopped — all three voices, and the notes with them
```

The kernel reads one step per frame for each voice, called between the pad and
the actors — so a game says `play` once and never feeds it, the same way it
never feeds the vblank. A tune with no music costs three instructions a frame
and no thought: a pointer of zero is silence, and zero is what the init's
clearing leaves.

### The notation

One token is one beat, and a beat is a count of frames — the console counts
frames and so does this; there is no tempo underneath it.

| token | meaning |
|---|---|
| `c4` `fs5` `as3` | a note — letter, optional `s` for the sharp, octave |
| `.` | hold: the note before it goes on sounding |
| `-` | a rest: the voice is silenced |
| `\|` | a bar line — ink for the reader, the parser walks past it |
| `[c4 e4 g4]` | a group: its notes packed into one beat, as equal slices |

A hold lengthens a step rather than repeating it, and that is the one decision
worth defending: retriggering a note restarts it, which the ear hears as a
stutter and not as a held note. `c4 . . .` is one step of four beats and the
channel is left alone for all of them.

A group is how a melody says pickup notes and triplets without speeding the
whole tune up. The beat must divide by the group's size — refused rather than
rounded, because a lost frame per group is a tune that drifts against its own
bass slowly enough that nobody suspects the notation. Only the last member
takes the gap: a triplet is one gesture, slurred inside, breathing at the end.

Motifs are ordinary Elixir. The notation is evaluated when the module compiles,
so module attributes, `<>` and `Enum.join` are the pattern language — there is
no `defpattern`, on purpose. A plain variable from the module body is out of
reach (a macro never sees bindings) and the refusal says to make it an
attribute.

### The voices

`lead:` is channel 1, `harmony:` channel 2, `bass:` the wave channel. One line
of text instead of a keyword list is the lead alone. Each voice is monophonic —
chords are spelled across voices, the harmony a third under the lead being the
classic — and each loops on its own terminator, which has a consequence worth
underlining: **voices of unequal length drift apart**, one beat per pass. Write
them the same number of beats.

The bass is not a third pulse. The wave channel steps a 32-sample table where a
pulse toggles a duty, so its frequency is `65536 / (2048 - x)` — half the
number for the same note, and an octave deeper at the bottom: `c1` is a note
there and not on the lead. Its waveform is a triangle, sixteen bytes the init
copies into `0xFF30`; a triangle rather than a saw because a bass sits under a
square lead and a saw fights it. The day a game wants its own timbre, that
table is the thing it will choose instead of.

### The settings

| setting | values | what it is |
|---|---|---|
| `beat:` | 1–255, default 12 | frames per token — five beats a second by default |
| `duty:` | `:eighth` `:quarter` `:half` | which square the pulses are: the fraction of each period the wave is high. The eighth is the thin, nasal classic; the half sounds like a test tone |
| `gap:` | 0 to beat−1 | every note ends this many frames early — the difference between notes that run into each other and notes with a rhythm. Cut at compile time: a note becomes a shorter note and a rest, and nothing new runs |
| `vibrato:` | `:none` `:gentle` `:deep` | the kernel bends a sounding note's pitch every frame, trigger bit clear so it never restarts. The wobble table opens on four zeros — a note is struck in tune and walks into it — so short notes never wobble at all |
| `envelope:` | `:organ` `:pluck` | organ holds a note until the next one; pluck lets it die away on its own, the way a struck string does |

The duty and the envelope reach both pulses and not the bass; the vibrato
likewise. Named rather than numbered throughout, and for the vibrato the reason
is the hardware: the register holds a *period*, so the same deviation is four
hertz at c5 and a third of one at c2 — a number would mean something different
on every note.

### What is in the cartridge

Three bytes per step — frequency low, frequency high with the trigger bit,
frames — and a step of length zero ends the tune and sends the cursor back to
its base, which is why a tune loops without being asked to. A rest carries no
trigger; it takes the envelope to zero instead, so the note already sounding
stops rather than being replaced.

---

## Hearing it

```
ELIXIR_ERL_OPTIONS="-noinput" mix atomboy.tune "c4 . e4 . [g4 a4 c5] ."
mix atomboy.tune "c4 . e4 -" --bytes
```

A bar, heard without writing a game around it — it loops until `q`. `--bytes`
reads the compiled steps back as note names, which is where a hold shows itself:
`c4 . e4` is a c4 of twenty-four frames, not two of twelve.

For a tune inside a game, `mix atomboy.live` reloads the cartridge on save with
the console running. One caveat follows from the state machine: `play` in an
`on_enter` has already run, and a reload does not re-enter the state — a
changed tune is heard the next time something starts it.

## What there is not, and why

- **No per-note volume track.** A parallel `volume: "15 12 10"` string would be
  a second line to keep aligned with the first, and a misalignment is a wrong
  tune that says nothing. The envelope covers most of what dynamics are for; an
  accent notation on the note itself would be the next step, not a track.
- **No percussion voice.** The noise channel is one-shot by design; a game
  makes a rhythm the way it makes everything else — counting frames and saying
  `noise(:tick)` on the ones it means.
- **No note below C2** on the pulses (C1 on the bass), no step longer than 255
  frames, no tempo other than the frame counter.
