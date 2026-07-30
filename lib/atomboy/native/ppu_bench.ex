defmodule Atomboy.Native.PPUBench do
  @moduledoc """
  The rendering differential test: `Atomboy.Native.PPU` against `Atomboy.PPU`,
  scanline by scanline, compared inside the guest.

  ## Why in-guest, again

  The same arithmetic as `Atomboy.Native.Bench`. A case is 160 bytes out; a
  useful run is a few hundred cases; an emulated 16550 UART moves one byte per
  polling loop. Pushing the pictures out and diffing them in Elixir would spend
  its whole time in `putc`. So the image carries the **expected** scanlines,
  computed by `Atomboy.PPU`, and the guest reports only what disagrees: six
  bytes per wrong pixel, three bytes for a clean run.

  A divergence names the case, the column, the shade produced and the shade
  expected. With the case's inputs still in the Elixir side's hands, that is
  enough to reconstruct the failure without re-running anything.

  ## What a case is

  One case is one call to `render_line`: a memory state, an LY, and an incoming
  window line counter. The memory the PPU can see is small and fixed -- 8 KB of
  VRAM, 160 bytes of OAM, twelve I/O registers -- so a case carries 8,528 bytes
  and the driver scatters them into the 64 KB space before each call. The copy is
  measured out of the instruction count: the counter is read either side of the
  call and of nothing else.

  Cases come from three places, and the mix matters more than the count:

    * `random_cases/2` -- random VRAM, random tilemaps, random OAM, random
      registers. Finds the things nobody thought to look at.
    * `directed_cases/0` -- the edges, one case per rule: SCX wrapping at the map
      seam, `WX = 7` and `WX = 0` and `WX >= 167`, a sprite hanging off the left
      edge, eleven sprites competing for ten slots, 8x16 with both flips,
      "behind the background" over colour 0 and over colour 2, every LCDC bit
      down in turn.
    * `frame_cases/1` -- the 144 scanlines of one fixed state, threaded through
      the window counter exactly as `Atomboy.PPU.render_frame/1` threads it.
    * `golden_cases/2` -- the same 144 scanlines of a *running* game, each
      carrying the memory as it stood when that line was drawn. Their
      expectations concatenate into the frame `Atomboy.ScreenTest` freezes under
      a CRC, which makes this the strongest statement the bench can make.

  ## The protocol

      0xE5 index:16 instret:32   the instructions one scanline retired
      0xE6 index:16 got want     the window counter came back wrong
      0xE7 index:16 x got want   one pixel disagrees
      0xFF count:16              the end, and how many divergences

  `instret` is only true under `qemu -icount shift=0`; `run/2` passes it.
  """

  import Bitwise

  alias Atomboy.Native.Asm
  alias Atomboy.Native.Image
  alias Atomboy.Native.PPU
  alias Atomboy.Native.Qemu
  alias Atomboy.Native.Regs
  alias Atomboy.Native.RV32

  @instret_magic 0xE5
  @window_magic 0xE6
  @pixel_magic 0xE7
  @stop 0xFF
  @max_divergences 64

  @instret 0xC02
  @memory 0x10000
  @width PPU.width()

  # ══ The case payload ═════════════════════════════════════════════════════════
  #
  # Every offset the driver loads from stays under 2048, which is what a load's
  # immediate holds -- hence the small fields first and the 8 KB of VRAM last.

  @off_ly 0
  @off_window_in 1
  @off_window_out 2
  @off_io 4
  @off_oam 16
  @off_expected 176
  @off_vram 336
  @stride 8528

  @io_range 0xFF40..0xFF4B
  @oam_range 0xFE00..0xFE9F
  @vram_range 0x8000..0x9FFF

  # The registers `Atomboy.PPU` defaults when a key is missing. A case must pin
  # them, or the two sides read different memory and the comparison means
  # nothing. Which four they are is this module's business; what they hold is
  # `Atomboy.Native.Boot`'s, so that the machine loop's harness and this one
  # cannot drift apart on a palette.
  @io_defaults Map.take(Atomboy.Native.Boot.io_state(), [0xFF40, 0xFF47, 0xFF48, 0xFF49])

  @doc "How many bytes one case occupies in the image."
  @spec stride() :: pos_integer()
  def stride, do: @stride

  @doc """
  A case's payload: the inputs, the expected output, and the memory to render.

  The expectation is `Atomboy.PPU.render_line/3`'s, computed here and baked into
  the image -- the guest never learns what the answer should have been, it only
  learns whether it matched.
  """
  @spec payload(map()) :: binary()
  def payload(%{payload: bytes}), do: bytes

  def payload(%{ram: ram, ly: ly, window_line: window_line}) do
    {expected, window_out} = Atomboy.PPU.render_line(ram, ly, window_line)

    <<ly, window_line, window_out, 0>> <>
      bytes(ram, @io_range) <>
      bytes(ram, @oam_range) <>
      expected <>
      bytes(ram, @vram_range)
  end

  defp bytes(ram, range) do
    for address <- range, into: <<>>, do: <<Map.get(ram, address, 0)>>
  end

  @doc """
  A case's memory, from the fields that name a PPU state.

  Absent keys stay absent, which means zero on both sides -- except the four
  registers `Atomboy.PPU` gives a non-zero default, which are always written.
  """
  @spec ram(map()) :: map()
  def ram(fields) do
    registers = %{
      0xFF40 => Map.get(fields, :lcdc, @io_defaults[0xFF40]),
      0xFF42 => Map.get(fields, :scy, 0),
      0xFF43 => Map.get(fields, :scx, 0),
      0xFF47 => Map.get(fields, :bgp, @io_defaults[0xFF47]),
      0xFF48 => Map.get(fields, :obp0, @io_defaults[0xFF48]),
      0xFF49 => Map.get(fields, :obp1, @io_defaults[0xFF49]),
      0xFF4A => Map.get(fields, :wy, 0),
      0xFF4B => Map.get(fields, :wx, 0)
    }

    registers
    |> Map.merge(Map.get(fields, :vram, %{}))
    |> Map.merge(Map.get(fields, :oam, %{}))
  end

  @doc """
  Turns an `Atomboy.Screen` memory map into one a case can carry.

  Two things happen. The non-integer keys go -- `:cgb`, `:mbc`, `:rom_banks`:
  the native renderer is the DMG one, and a `:cgb` left in place would send the
  oracle down the colour path and make the comparison meaningless. And the four
  defaulted registers are materialised, so a game that never wrote LCDC does not
  give the oracle `0x91` and the guest a zero.
  """
  @spec from_screen(map()) :: map()
  def from_screen(ram) do
    kept = for {address, byte} <- ram, is_integer(address), into: %{}, do: {address, byte}

    Enum.reduce(@io_defaults, kept, fn {address, default}, acc ->
      Map.put_new(acc, address, default)
    end)
  end

  # ══ The cases ════════════════════════════════════════════════════════════════

  @doc """
  `count` random cases, from a seed -- the same seed gives the same cases.

  Everything is random: the whole of VRAM (so tile data and tilemaps both), the
  40 OAM entries, the registers. The Y coordinates are drawn around the scanline
  rather than uniformly, otherwise a random sprite lands on the line about three
  times in a hundred and the sprite path never gets exercised.
  """
  @spec random_cases(pos_integer(), integer()) :: [map()]
  def random_cases(count, seed) do
    :rand.seed(:exsss, {seed, seed * 7 + 1, seed * 13 + 3})

    for _ <- 1..count do
      ly = :rand.uniform(144) - 1

      vram = for address <- @vram_range, into: %{}, do: {address, :rand.uniform(256) - 1}

      oam =
        for index <- 0..39, reduce: %{} do
          acc ->
            base = 0xFE00 + index * 4

            y =
              if :rand.uniform(3) == 1 do
                :rand.uniform(256) - 1
              else
                min(255, max(0, ly + 16 - :rand.uniform(24) + 8))
              end

            acc
            |> Map.put(base, y)
            |> Map.put(base + 1, :rand.uniform(176) - 1)
            |> Map.put(base + 2, :rand.uniform(256) - 1)
            |> Map.put(base + 3, :rand.uniform(256) - 1)
        end

      # One case in eight takes LCDC entirely as it comes -- screen possibly off,
      # background possibly off. The other seven force bit 7, bit 1 and bit 0, so
      # the sprite and background paths are actually walked: with a uniform LCDC
      # half the cases would compare two blank layers.
      lcdc =
        case :rand.uniform(8) do
          1 -> :rand.uniform(256) - 1
          _ -> 0x83 ||| :rand.uniform(128) - 1
        end

      %{
        ly: ly,
        window_line: :rand.uniform(144) - 1,
        ram:
          ram(%{
            lcdc: lcdc,
            scx: :rand.uniform(256) - 1,
            scy: :rand.uniform(256) - 1,
            wy: :rand.uniform(160) - 1,
            wx: :rand.uniform(176) - 1,
            bgp: :rand.uniform(256) - 1,
            obp0: :rand.uniform(256) - 1,
            obp1: :rand.uniform(256) - 1,
            vram: vram,
            oam: oam
          })
      }
    end
  end

  @doc """
  The edge cases, one per rule -- named, because a failing index should say what
  broke rather than sending the reader back to the generator.

  Returns `[{name, case}]`; `cases/1` drops the names for the image and the test
  puts them back when reporting.
  """
  @spec directed_cases() :: [{atom(), map()}]
  def directed_cases do
    [
      # The background alone, no scroll: the plainest possible picture, and the
      # one whose failure means nothing else can be trusted.
      {:plain_background, base_case(%{})},

      # The map seam. At SCX 250 the first six pixels come from column 31 and the
      # rest from column 0, so a missing `& 31` shows up as the wrong tile at
      # x = 6.
      {:scx_seam, base_case(%{scx: 250})},
      {:scx_seam_mid_tile, base_case(%{scx: 253, scy: 7})},
      {:scy_seam, base_case(%{scy: 250, ly: 8})},
      {:second_map, base_case(%{lcdc: 0x91 ||| 0x08})},

      # Signed tile addressing: LCDC bit 4 down puts index 0x80 at 0x8800 and
      # index 0x00 at 0x9000.
      {:signed_tiles, base_case(%{lcdc: 0x91 &&& bnot(0x10)})},
      {:signed_tiles_high, base_case(%{lcdc: 0x91 &&& bnot(0x10), map_fill: 0x85})},

      # The window's left edge, every way it can fall.
      {:window_wx7, window_case(%{wx: 7})},
      {:window_wx0, window_case(%{wx: 0})},
      {:window_wx3, window_case(%{wx: 3})},
      {:window_mid_line, window_case(%{wx: 87})},
      {:window_wx166, window_case(%{wx: 166})},
      {:window_wx167, window_case(%{wx: 167})},
      {:window_wx255, window_case(%{wx: 255})},
      {:window_before_wy, window_case(%{wy: 100, ly: 40})},
      {:window_at_wy, window_case(%{wy: 40, ly: 40})},
      {:window_counter_advanced, window_case(%{window_line: 17})},
      {:window_counter_high, window_case(%{window_line: 143})},
      {:window_disabled, window_case(%{lcdc: 0xF1 &&& bnot(0x20)})},
      {:window_first_map, window_case(%{lcdc: 0xB1})},

      # Sprites. All of these render LY 40, and `sprite/3` takes *screen*
      # coordinates -- the OAM bias of 16 and 8 is applied for us, because
      # getting it wrong the other way round is silent: the sprite simply misses
      # the line and the comparison passes on an empty picture.
      {:sprite_row_first, sprite_case([sprite(40, 40)])},
      {:sprite_row_middle, sprite_case([sprite(36, 40)])},
      {:sprite_row_last, sprite_case([sprite(33, 40)])},
      {:sprite_left_edge, sprite_case([sprite(36, -4)])},
      {:sprite_left_one_pixel, sprite_case([sprite(36, -7)])},
      {:sprite_fully_left, sprite_case([sprite(36, -8)])},
      {:sprite_right_edge, sprite_case([sprite(36, 157)])},
      {:sprite_off_right, sprite_case([sprite(36, 160)])},
      {:sprite_top_clipped, sprite_case([sprite(-4, 40)], %{ly: 0})},
      {:sprite_flip_x, sprite_case([sprite(36, 40, flags: 0x20)])},
      {:sprite_flip_y, sprite_case([sprite(36, 40, flags: 0x40)])},
      {:sprite_flip_both, sprite_case([sprite(36, 40, flags: 0x60)])},
      {:sprite_obp1, sprite_case([sprite(36, 40, flags: 0x10)])},
      {:sprite_blank_tile, sprite_case([sprite(36, 40, tile: 0x40)])},

      # Tall sprites: the row runs 0..15, bit 0 of the index is ignored, and the
      # flip happens before that masking -- which is what makes the bottom half
      # of a flipped 8x16 read from the even tile.
      {:tall_upper_half, sprite_case([sprite(36, 40, tile: 0x11)], %{lcdc: 0x97})},
      {:tall_lower_half, sprite_case([sprite(28, 40, tile: 0x11)], %{lcdc: 0x97})},
      {:tall_flip_y_upper, sprite_case([sprite(36, 40, tile: 0x11, flags: 0x40)], %{lcdc: 0x97})},
      {:tall_flip_y_lower, sprite_case([sprite(28, 40, tile: 0x11, flags: 0x40)], %{lcdc: 0x97})},
      {:tall_flip_both, sprite_case([sprite(28, 40, tile: 0x11, flags: 0x60)], %{lcdc: 0x97})},
      {:tall_clipped_top, sprite_case([sprite(-6, 40, tile: 0x11)], %{lcdc: 0x97, ly: 4})},

      # Priority between sprites: the smallest X wins, the lowest OAM index
      # breaks the tie. One pair where X decides, one where it cannot, and one
      # where the winner is transparent so the loser shows through.
      {:overlap_x_decides, sprite_case([sprite(36, 44, tile: 2), sprite(36, 40, tile: 3)])},
      {:overlap_index_decides, sprite_case([sprite(36, 40, tile: 2), sprite(36, 40, tile: 3)])},
      {:overlap_three,
       sprite_case([sprite(36, 44, tile: 2), sprite(36, 40, tile: 3), sprite(36, 42, tile: 4)])},

      # "Behind the background" yields to colours 1-3 and shows through colour 0
      # -- and it must yield to the *background*, not to a lower-priority sprite
      # that already painted the pixel. `map_fill: 0x40` is the blank tile, so
      # the background there is colour 0 everywhere.
      {:behind_over_zero, sprite_case([sprite(36, 40, flags: 0x80)], %{map_fill: 0x40})},
      {:behind_over_colour, sprite_case([sprite(36, 40, flags: 0x80)])},
      {:behind_over_sprite,
       sprite_case([sprite(36, 40, tile: 2, flags: 0x80), sprite(36, 42, tile: 3)])},

      # Ten per line, in OAM order: the eleventh entry does not show even with
      # the smallest X of the lot.
      {:eleven_sprites,
       sprite_case(
         for(i <- 0..9, do: sprite(36, 20 + i * 12, tile: 2)) ++ [sprite(36, 0, tile: 3)]
       )},
      {:ten_overlapping,
       sprite_case(for i <- 0..11, do: sprite(36, 30 + i * 3, tile: 2 + rem(i, 5)))},

      # Every switch, down.
      {:lcd_off, sprite_case([sprite(36, 40)], %{lcdc: 0x13})},
      {:background_off, sprite_case([sprite(36, 40)], %{lcdc: 0x92})},
      {:background_off_bgp, sprite_case([sprite(36, 40)], %{lcdc: 0x92, bgp: 0xE1})},
      {:background_off_behind, sprite_case([sprite(36, 40, flags: 0x80)], %{lcdc: 0x92})},
      {:background_off_window_frozen, window_case(%{lcdc: 0xF1 &&& bnot(0x01)})},
      {:sprites_off, sprite_case([sprite(36, 40)], %{lcdc: 0x91})},
      {:palettes_inverted, sprite_case([sprite(36, 40)], %{bgp: 0x1B, obp0: 0x1B})},

      # The window and the sprites at once: the layer the sprite lands on is the
      # window's, and its raw colour is the one the priority test must read.
      {:window_and_sprites,
       sprite_case([sprite(36, 40), sprite(36, 100, flags: 0x80)], %{
         lcdc: 0xF3,
         wy: 0,
         wx: 87
       })}
    ]
  end

  @doc """
  The 144 scanlines of one memory state, the window counter threaded through.

  This is the frame-level golden: the same reduction
  `Atomboy.PPU.render_frame/1` performs, cut into independent cases so the bench
  can run them the way it runs every other one.
  """
  @spec frame_cases(map()) :: [map()]
  def frame_cases(ram) do
    {cases, _window_line} =
      Enum.map_reduce(0..143, 0, fn ly, window_line ->
        {_line, next} = Atomboy.PPU.render_line(ram, ly, window_line)
        {%{ly: ly, window_line: window_line, ram: ram}, next}
      end)

    cases
  end

  @doc """
  The 144 scanlines of a ROM's `frames`-th frame, each carrying the memory as it
  stood **when that line was drawn**.

  `Atomboy.Screen` renders a line between two 456-cycle slices of CPU, so the
  registers a line sees are the ones in force at that line. That is not
  pedantry: dmg-acid2 moves the window mid-frame, and a golden built from the
  memory as it stood at the *end* of the frame draws a different picture -- a
  legitimate one, just not the one the panel showed. Snapshotting per line is
  what makes the native frame comparable to `Atomboy.ScreenTest`'s CRC, which is
  the strongest statement available here: 23,040 pixels of a real game, produced
  by generated RISC-V, identical to the frame the Elixir emulator displays.

  The payload is baked immediately rather than kept as a memory map: 144
  snapshots of a game's address space held at once is a hundred megabytes, and
  the binary is eight kilobytes.
  """
  @spec golden_cases(Path.t(), pos_integer()) :: [map()]
  def golden_cases(rom_path, frames) when frames > 1 do
    rom = Atomboy.Screen.load(rom_path)
    {_pixels, state, ram} = Atomboy.Screen.run(rom_path, frames - 1)

    {cases, _} =
      Enum.map_reduce(0..143, {state, ram, 0}, fn ly, {state, ram, window_line} ->
        {state, ram} = Atomboy.Screen.step_line(state, rom, ram, ly)
        snapshot = from_screen(ram)
        {_line, next} = Atomboy.PPU.render_line(snapshot, ly, window_line)

        payload = payload(%{ram: snapshot, ly: ly, window_line: window_line})
        {%{ly: ly, window_line: window_line, payload: payload}, {state, ram, next}}
      end)

    cases
  end

  @doc """
  The scanlines a set of cases expects, concatenated -- a frame, when the cases
  are a frame's.

  Read back out of the payloads rather than recomputed, so what the test
  compares against a CRC is byte for byte what the guest was asked to match.
  """
  @spec expected_frame([map()]) :: binary()
  def expected_frame(cases) do
    for c <- cases, into: <<>> do
      binary_part(payload(c), @off_expected, @width)
    end
  end

  # A background-only state: 32x32 of one tile, and a tile whose eight rows are
  # all different so a wrong row shows immediately.
  defp base_case(fields) do
    fill = Map.get(fields, :map_fill, 0x05)

    ram =
      ram(
        Map.merge(
          %{
            lcdc: 0x91,
            bgp: 0xE4,
            vram: Map.merge(tile_bank(), tilemap(fill))
          },
          Map.drop(fields, [:ly, :window_line, :map_fill])
        )
      )

    %{ly: Map.get(fields, :ly, 40), window_line: Map.get(fields, :window_line, 0), ram: ram}
  end

  # The same, plus a window drawn from the *other* map, holding another tile:
  # which of the two layers drew a pixel is then readable from the pixel itself.
  # LCDC 0xF1 is the default here -- bit 5 for the window, bit 6 for its map.
  defp window_case(fields) do
    fill = Map.get(fields, :map_fill, 0x05)

    ram =
      ram(
        Map.merge(
          %{
            lcdc: 0xF1,
            bgp: 0xE4,
            wy: 0,
            wx: 7,
            vram:
              tile_bank()
              |> Map.merge(tilemap(fill))
              |> Map.merge(tilemap(0x0C, 0x9C00))
          },
          Map.drop(fields, [:ly, :window_line, :map_fill])
        )
      )

    %{ly: Map.get(fields, :ly, 40), window_line: Map.get(fields, :window_line, 0), ram: ram}
  end

  defp sprite_case(sprites, fields \\ %{}) do
    oam =
      sprites
      |> Enum.with_index()
      |> Enum.reduce(%{}, fn {{y, x, tile, flags}, index}, acc ->
        base = 0xFE00 + index * 4

        acc
        |> Map.put(base, y)
        |> Map.put(base + 1, x)
        |> Map.put(base + 2, tile)
        |> Map.put(base + 3, flags)
      end)

    fill = Map.get(fields, :map_fill, 0x05)

    ram =
      ram(
        Map.merge(
          %{
            lcdc: 0x93,
            bgp: 0xE4,
            obp0: 0xE4,
            obp1: 0x1B,
            vram:
              tile_bank()
              |> Map.merge(sprite_tiles())
              |> Map.merge(tilemap(fill)),
            oam: oam
          },
          Map.drop(fields, [:ly, :window_line, :map_fill])
        )
      )

    %{ly: Map.get(fields, :ly, 40), window_line: Map.get(fields, :window_line, 0), ram: ram}
  end

  # Screen coordinates in, OAM bytes out: OAM Y is biased by 16 and OAM X by 8,
  # so a sprite can hang off the top and the left of the screen. Negative
  # coordinates wrap into the byte, which is exactly what the hardware sees.
  defp sprite(screen_y, screen_x, opts \\ []) do
    {screen_y + 16 &&& 0xFF, screen_x + 8 &&& 0xFF, Keyword.get(opts, :tile, 0x01),
     Keyword.get(opts, :flags, 0x00)}
  end

  # Irregular data over the whole of the tile area, 0x8000-0x97FF: both
  # addressing modes then land on something, which matters because a blank tile
  # makes a wrong address look right. Tile 0x40 is left at zero -- that is the
  # sprite transparency case.
  defp tile_bank do
    for address <- 0x8000..0x97FF, into: %{} do
      byte = if address in 0x8400..0x840F, do: 0, else: noise(address)
      {address, byte}
    end
  end

  defp noise(address) do
    bxor(bxor(address * 37, bsr(address, 3)), 0x5A) &&& 0xFF
  end

  # The tiles the sprite cases use, with the low plane full: every pixel then
  # carries at least colour 1, so a sprite clipped down to a single column still
  # draws something. Without that the clipping cases pass on an empty picture --
  # they did, until the meta-test in `Atomboy.NativePPUTest` caught it.
  #
  # Tile 5 is the exception, and deliberately: `0x3C / 0x18` gives colours
  # 0,0,1,3,3,1,0,0, which is transparency *inside* a sprite. Tile 0x40 stays
  # blank, which is transparency over the whole of one.
  defp sprite_tiles do
    for tile <- [1, 2, 3, 4, 5, 0x10, 0x11], row <- 0..7, reduce: %{} do
      acc ->
        base = 0x8000 + tile * 16 + row * 2
        {low, high} = if tile == 5, do: {0x3C, 0x18}, else: {0xFF, tile * 37 + row * 11 &&& 0xFF}

        acc |> Map.put(base, low) |> Map.put(base + 1, high)
    end
  end

  defp tilemap(fill, base \\ 0x9800) do
    # Not uniform: one column and one row differ, so a column or row that is one
    # off cannot hide behind a repeating map.
    for index <- 0..0x3FF, into: %{} do
      value =
        cond do
          rem(index, 32) == 0 -> fill + 1
          div(index, 32) == 0 -> fill + 2
          true -> fill
        end

      {base + index, value &&& 0xFF}
    end
  end

  # ══ The run ══════════════════════════════════════════════════════════════════

  @doc """
  Builds and runs a bench over `cases`; returns what disagreed and what it cost.

  `divergences` empty means the two renderers are indistinguishable over
  everything given. `instret` is the retired-instruction count of each scanline,
  in case order -- the number that decides whether this fits an ESP32-C6.
  """
  @spec run([map()], keyword()) :: {:ok, map()} | {:error, term()}
  def run(cases, opts \\ []) do
    image = image(cases)

    opts =
      opts
      |> Keyword.put_new(:timeout, 300_000)
      |> Keyword.put_new(:icount, true)

    case Qemu.run(image.code, opts) do
      %{status: :timeout, duration_us: us} ->
        {:error, {:timeout, us}}

      %{status: :ok, serial: serial, duration_us: us} ->
        with {:ok, report} <- decode(serial) do
          {:ok, Map.merge(report, %{duration_us: us, size: image.size})}
        end
    end
  end

  @doc "The bench image: the PPU, the driver, the cases and their expectations."
  @spec image([map()]) :: Asm.assembled()
  def image(cases) do
    Image.build(
      [driver(length(cases)), PPU.routines(), copy()],
      data(cases)
    )
  end

  # ── The driver ──────────────────────────────────────────────────────────────
  #
  # s0  the current case's payload     s5   its retired-instruction count
  # s1  the case index                 s6   the window counter it returned
  # s2  how many cases there are       s10  how many divergences so far
  # s4  the instruction counter's baseline
  # s11 the destination buffer
  #
  # `Atomboy.Native.PPU` gives everything except a0 and t0-t6 back untouched, so
  # none of this needs saving around the call -- which is the whole point of that
  # contract.
  defp driver(count) do
    [
      Asm.la(Regs.mem(), :ppu_memory),
      Asm.la(:s0, :ppu_cases),
      Asm.la(:s11, :ppu_destination),
      RV32.li(:s1, 0),
      RV32.li(:s2, count),
      RV32.li(:s10, 0),
      Asm.label(:case_loop),
      scatter(),
      RV32.lbu(:a0, :s0, @off_ly),
      RV32.lbu(:t0, :s0, @off_window_in),
      RV32.mv(:t1, :s11),
      RV32.csrrs(:s4, @instret, :zero),
      Asm.call(PPU.label()),
      RV32.csrrs(:t2, @instret, :zero),
      RV32.sub(:s5, :t2, :s4),
      RV32.mv(:s6, :a0),
      report_instret(),
      check_window(),
      check_pixels(),
      Asm.label(:next_case),
      RV32.li(:t0, @stride),
      RV32.add(:s0, :s0, :t0),
      RV32.addi(:s1, :s1, 1),
      Asm.blt(:s1, :s2, :case_loop),
      Asm.label(:bench_done),
      byte_out(RV32.li(:a0, @stop)),
      byte_out(RV32.mv(:a0, :s10)),
      byte_out(RV32.srli(:a0, :s10, 8)),
      Asm.j(:poweroff)
    ]
  end

  # VRAM, OAM and the six registers into the 64 KB space. Not measured: the
  # counter is read after this and before the call.
  defp scatter do
    [
      region(0x8000, @off_vram, 8192),
      region(0xFE00, @off_oam, 160),
      region(0xFF40, @off_io, 12)
    ]
  end

  defp region(address, offset, length) do
    [
      RV32.li(:t0, address),
      RV32.add(:a1, Regs.mem(), :t0),
      RV32.addi(:a2, :s0, offset),
      RV32.li(:a3, length),
      Asm.call(:ppu_copy)
    ]
  end

  defp report_instret do
    [
      byte_out(RV32.li(:a0, @instret_magic)),
      byte_out(RV32.mv(:a0, :s1)),
      byte_out(RV32.srli(:a0, :s1, 8)),
      byte_out(RV32.mv(:a0, :s5)),
      byte_out(RV32.srli(:a0, :s5, 8)),
      byte_out(RV32.srli(:a0, :s5, 16)),
      byte_out(RV32.srli(:a0, :s5, 24))
    ]
  end

  # `putc` clobbers t0, t1 and a0 and nothing else, so t2 carries the expected
  # value across the report.
  defp check_window do
    [
      RV32.lbu(:t2, :s0, @off_window_out),
      Asm.beq(:t2, :s6, :window_ok),
      byte_out(RV32.li(:a0, @window_magic)),
      byte_out(RV32.mv(:a0, :s1)),
      byte_out(RV32.srli(:a0, :s1, 8)),
      byte_out(RV32.mv(:a0, :s6)),
      byte_out(RV32.mv(:a0, :t2)),
      RV32.addi(:s10, :s10, 1),
      Asm.label(:window_ok)
    ]
  end

  defp check_pixels do
    [
      RV32.li(:t2, 0),
      RV32.addi(:t3, :s0, @off_expected),
      RV32.mv(:t4, :s11),
      Asm.label(:pixel_loop),
      RV32.lbu(:t5, :t3, 0),
      RV32.lbu(:t6, :t4, 0),
      Asm.beq(:t5, :t6, :pixel_next),
      byte_out(RV32.li(:a0, @pixel_magic)),
      byte_out(RV32.mv(:a0, :s1)),
      byte_out(RV32.srli(:a0, :s1, 8)),
      byte_out(RV32.mv(:a0, :t2)),
      byte_out(RV32.mv(:a0, :t6)),
      byte_out(RV32.mv(:a0, :t5)),
      RV32.addi(:s10, :s10, 1),

      # A renderer that is off by one pixel would otherwise emit a megabyte of
      # divergences and drown the first one.
      RV32.li(:t0, @max_divergences),
      Asm.bge(:s10, :t0, :bench_done),
      Asm.label(:pixel_next),
      RV32.addi(:t2, :t2, 1),
      RV32.addi(:t3, :t3, 1),
      RV32.addi(:t4, :t4, 1),
      RV32.li(:t0, @width),
      Asm.blt(:t2, :t0, :pixel_loop)
    ]
  end

  defp byte_out(load), do: [load, Asm.call(:putc)]

  # a1 destination, a2 source, a3 length. Clobbers t0 and its three arguments.
  defp copy do
    [
      Asm.label(:ppu_copy),
      Asm.beqz(:a3, :copy_done),
      Asm.label(:copy_loop),
      RV32.lbu(:t0, :a2, 0),
      RV32.sb(:t0, :a1, 0),
      RV32.addi(:a1, :a1, 1),
      RV32.addi(:a2, :a2, 1),
      RV32.addi(:a3, :a3, -1),
      Asm.bnez(:a3, :copy_loop),
      Asm.label(:copy_done),
      RV32.ret()
    ]
  end

  # ── The data ────────────────────────────────────────────────────────────────

  defp data(cases) do
    [
      {:align, 4},
      Asm.label(:ppu_destination),
      {:space, @width},
      {:align, 4},
      Asm.label(:ppu_memory),
      {:space, @memory},
      {:align, 4},
      Asm.label(:ppu_cases),
      Enum.map(cases, &payload/1),
      PPU.data()
    ]
  end

  # ══ The decoding ═════════════════════════════════════════════════════════════

  defp decode(serial), do: read(serial, %{divergences: [], instret: []})

  defp read(<<@stop, count::16-little, _rest::binary>>, acc) do
    divergences = Enum.reverse(acc.divergences)

    if length(divergences) != count do
      {:error, {:count_mismatch, count, length(divergences)}}
    else
      {:ok, %{divergences: divergences, instret: Enum.reverse(acc.instret)}}
    end
  end

  defp read(<<@instret_magic, index::16-little, instret::32-little, rest::binary>>, acc) do
    read(rest, %{acc | instret: [{index, instret} | acc.instret]})
  end

  defp read(<<@window_magic, index::16-little, got, want, rest::binary>>, acc) do
    divergence = %{case: index, kind: :window_line, got: got, expected: want}
    read(rest, %{acc | divergences: [divergence | acc.divergences]})
  end

  defp read(<<@pixel_magic, index::16-little, x, got, want, rest::binary>>, acc) do
    divergence = %{case: index, kind: :pixel, x: x, got: got, expected: want}
    read(rest, %{acc | divergences: [divergence | acc.divergences]})
  end

  defp read(other, _acc) do
    {:error,
     {:unreadable_stream, byte_size(other), binary_part(other, 0, min(32, byte_size(other)))}}
  end
end
