# From Elixir to a cartridge

One line of a game, followed all the way down.

```elixir
if pressed?(:right), do: x = x + 1
```

That is Elixir. It parses as Elixir, it is formatted by `mix format` as Elixir,
and it never runs as Elixir. What follows is what happens to it instead, and
every listing below was produced by the compiler rather than typed out — the
script that made them is four calls into `Potion.Compiler` and `Potion.Assembler`.

---

## 1. The source

```elixir
defmodule Pong do
  use Potion

  defactor :player do
    variables x: 80, y: 72

    every_frame do
      if pressed?(:right), do: x = x + 1
    end
  end
end
```

`use Potion` imports seven words — `defactor`, `variables`, `every_frame`,
`tiles`, `state`, `on_enter`, `routine` — and registers a `@before_compile`
hook. Nothing else about the module is special, and `Pong` is a perfectly
ordinary Elixir module that happens to have `rom/0` on it when the compiler is
done.

Those seven are the only ones imported, and the reason is stage 2: everything
else a game writes — `sprite`, `background`, `text`, `become`, `fade`,
`pressed?`, and a call to one of the actor's own routines — is never expanded,
so it needs no definition to import. The seven exist as functions purely so that
writing one in the wrong place says so.

## 2. The tree, unexpanded

`defactor` is a macro, so what it receives is the body as a **quoted tree**:

```elixir
{:if, [line: 1],
 [
   {:pressed?, [line: 1], [:right]},
   [
     do: {:=, [line: 1],
      [{:x, [line: 1], nil}, {:+, [line: 1], [{:x, [line: 1], nil}, 1]}]}
   ]
 ]}
```

This is the load-bearing decision of the whole language, and it is a decision
not to do something: **the tree is never expanded**. `Macro.expand` is never
called on it, the `if` is never turned into a `case`, `pressed?/1` is never
resolved to a function. The compiler reads the shape and nothing looks it up.

Three things follow from that. Elixir's `if` can be used without colliding with
`Kernel.if`, because the two never meet. `pressed?/1` needs no definition
anywhere — it is a word in the grammar, not a call. And a sentence the compiler
does not recognise is a `Potion.CompileError` naming the rejected tree, not a
`FunctionClauseError` from somewhere in a macro.

## 3. The allocation

A variable is a cell of WRAM. `Potion.Compiler.allocate/2` hands them out in
declaration order from the page the kernel leaves free:

```elixir
%{cells: %{x: 0xC100, y: 0xC101}, installed: 0xC102}
```

`installed` is the cell the game never declares and never sees. It answers a
question the BEAM does not have: an actor has no startup — the kernel calls it
once a frame and that is all — so *where do the initial values go?* The first
frame has to recognise itself, and the only state it can count on is the zero
the init left in the page. An actor with states keeps two more cells here: which
state it is in, and which it has already entered.

## 4. The fragment

`Potion.Compiler.compile/2` turns the tree into a list of tuples in the
`Potion.Assembler` format. Not bytes — tuples, which can be printed, sliced,
counted and compared in a test:

```elixir
{:ld, :a, {:mem, 0xC102}}                 # the installed flag
{:and, :a, :a}
{:jp, :nz, {:label, :potion_installed}}   # already set: skip the initial values
{:ld, :a, 1}
{:ld, {:mem, 0xC102}, :a}
{:ld, :a, 80}
{:ld, {:mem, 0xC100}, :a}                 # x = 80
{:ld, :a, 72}
{:ld, {:mem, 0xC101}, :a}                 # y = 72
{:label, :potion_installed}
{:ld, :a, {:mem, 0xC0A0}}                 # the pad cell the kernel keeps
{:bit, 0, :a}                             # bit 0 is Right
{:jp, :z, {:label, :potion_end_0}}        # not held: jump past the body
{:ld, :a, {:mem, 0xC100}}
{:add, :a, 1}
{:ld, {:mem, 0xC100}, :a}                 # x = x + 1
{:label, :potion_end_0}
{:ret}
```

Two shapes worth naming, because they are the ones a reader trips on.

**A condition emits the jumps that leave when it is *false*.** `if pressed?` is
`BIT 0, A` followed by a jump taken when the bit is clear. Saying it that way
rather than "jump when true" is what lets `if` with and without an `else` share
one shape, and what makes `and` free — two conditions in a row leave when either
is false, so `a and b` is the concatenation of their two emissions and nothing
else.

**Every jump that leaves an `if` is a `JP`, not a `JR`.** A relative jump reaches
127 bytes and an `if` body is whatever the game wrote; Pong's collision found
that cliff at 152. The absolute jump costs a byte and four cycles and cannot
fail. The one exception is `<=`, which jumps three bytes to a label the compiler
placed itself.

## 5. The bytes

`Potion.Assembler.assemble/2` walks the list twice: once to measure, which is
what resolves the labels to addresses, and once to emit. Thirty-nine bytes:

```
FA 02 C1  A7  C2 66 01  3E 01  EA 02 C1  3E 50  EA 00 C1  3E 48  EA 01 C1
FA A0 C0  CB 47  CA 76 01  FA 00 C1  C6 01  EA 00 C1  C9
```

Read the second line, which is the `if`:

| bytes | instruction | |
|---|---|---|
| `FA A0 C0` | `LD A, (0xC0A0)` | the pad, as the kernel recomposed it |
| `CB 47` | `BIT 0, A` | Right |
| `CA 76 01` | `JP Z, 0x0176` | not held — past the body |
| `FA 00 C1` | `LD A, (0xC100)` | x |
| `C6 01` | `ADD A, 1` | |
| `EA 00 C1` | `LD (0xC100), A` | back into x |

Sixteen bytes. The other twenty-three are the first-frame prologue that lays the
initial values down, and they run once.

That table is also where the language's semantics stop being a claim. `x = x + 1`
is `ADD A, 1` on a byte — so 255 + 1 is 0, and nothing is emitted to notice. An
assignment is an effect and not a value, because `LD (x), A` is. Two `x = …` in
one frame write the same cell twice and the second wins. None of that is a
compromise; it is what the instruction does.

## 6. The cartridge

`Potion.ROM.build/2` puts the program at 0x0150, writes the header — title,
cartridge type 0x00, the Nintendo logo the boot ROM checks, both checksums — and
pads to 32,768 bytes. The vblank vector at 0x0040 gets a jump to the kernel's
handler; without it the first serviced interrupt would execute padding.

```elixir
Pong.rom()        # 32,768 bytes, ready to burn or to hand to Atomboy.Screen
Pong.program()    # the tuples above, for reading
Pong.addresses()  # %{x: 0xC100, y: 0xC101}
```

---

## The three other pipelines

**A drawing.** `tiles from: "art/pong.png"` runs while the module compiles:
`Potion.PNG` reads the file down to `{r, g, b, a}` per pixel, `Potion.Tiles`
bands the brightness into four shades and cuts 8x8 tiles into the console's
two-byte-a-row bitplanes, and the bytes go into the cartridge where the init
copies them to VRAM. The names are handed out in reading order, and a game never
writes a tile number.

**A routine.** `routine :bounce do … end` is a labelled block ending in `RET`,
laid after the actor's body where nothing falls into it, and `bounce()` is a
`CALL`. No parameters: an actor's cells are the only storage there is, so a
caller sets them first — which is what an argument would have compiled to. The
call graph is walked at compile time and a circle is refused, because a `CALL`
that goes round grows the stack by two bytes a lap until it reaches the actor's
own cells.

**An index.** `bullets[2]` is an address the compiler works out itself and
costs nothing; `bullets[n]` is a sixteen-bit add — index into L, zero into H,
base into BC, `ADD HL, BC` — and then the ordinary load. Writing through one
pushes the value first, because the address goes through HL and the expression
being stored is free to use HL as well: `bullets[n] = bullets[n] + 1` uses it
twice.

**A pool.** `defactor :bullet, count: 4` is one body run four times. Each of the
actor's own names becomes four consecutive cells, and the compiler rewrites
every mention of them into a subscript by `me` before anything else happens — so
what loops is exactly the code a single actor would have been. Another actor
sees those same names as ordinary arrays, which is how one gets spawned.

**A tune.** `music :theme, lead: "c4 . e4 -", bass: "c2 . . ."` becomes three bytes a step — frequency,
frequency-with-trigger, frames — laid into the cartridge, and the kernel reads
one step a frame between the pad and the actors. A game says `play(:theme)`
once and never feeds it. A hold is a longer step rather than a repeated one,
because retriggering a note restarts it and the ear hears that as a stutter. `gap:` is cut here rather than played: a note of ten frames with a gap of three
becomes a note of seven and a rest of three, so the kernel plays what it always
played and a tune costs twice the bytes. `duty:` travels in a kernel cell that
`play` writes, because the player rewrites the duty register on every note. The
bass is compiled against its own table: the wave channel counts its period twice
as slowly, so the same note is a different number there — and it reaches an
octave lower, which is why a bass may say `c1` and a lead may not.

**A knock.** `noise(:hit)` is six writes to channel 4, which is a shift register
rather than an oscillator — there is no pitch to name, only how coarsely it is
clocked. The four names are that continuum: measured, `:tick` changes the output
some three hundred times a frame and `:boom` five.

**A note.** `beep(:c5)` is four writes to channel 2 and nothing kept. The
console has no pitch register — it has an eleven-bit number `x` where
`f = 131072 / (2048 - x)` — so the table is that formula run backwards at
compile time, and `:a4` is `2048 - 131072/440`. The envelope is what makes four
writes enough: the channel starts at full volume and steps down on its own, so
the sound ends without the game coming back to end it.

**A word.** `text(3, 7, "PRESS START")` becomes eleven `LD` pairs, one a square,
at compile time. There is no string at run time — there are letters that were
already decided. A space is not a glyph but tile 1, the empty tile the init
already filled the map with, and digits are the font the score has been using
since the beginning.

## Where it lives

| | |
|---|---|
| `lib/potion.ex` | the macros, the tree capture, `rom/0` |
| `lib/potion/compiler.ex` | tree to fragment, and every refusal message |
| `lib/potion/runtime.ex` | the kernel: init, vblank, DMA, pad, the loop that calls actors |
| `lib/potion/assembler.ex` | tuples to bytes, labels resolved |
| `lib/potion/rom.ex` | the 32 KB cartridge, header and checksums |
| `lib/potion/png.ex` | a PNG down to its pixels |
| `lib/potion/tiles.ex` | pixels to tiles |

## When it refuses

At `mix compile`, always. `x = x * 2` does not compile, because the SM83 has no
multiplication and there is nothing honest to emit. `if vx < 0` does not compile,
because `CP` is an unsigned subtraction and no byte is below zero that way — it
would be a branch never taken, silently. A tile name that was never drawn does
not compile, and the message lists the ones that were.

A ROM that compiles is a ROM every line of which exists in SM83. That is the
whole of the guarantee, and it is worth more than it sounds: there is no such
thing as Potion failing at run time for this class of mistake, because at run
time there is no Potion left — only a cartridge.
