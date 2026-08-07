defmodule Atomboy.LCD do
  @moduledoc """
  The panel, not the palette.

  A Game Boy frame leaves the PPU as an index — a shade from 0 to 3, or a
  colour in RGB555. What the player saw was that index *through a screen*:
  a reflective STN panel, its own gamma, its own warmth, its own dial. The
  `#9BBC0F` green everyone quotes is a myth of the web; photographs of real
  units show a far greyer, far warmer thing.

  This module models the panel as a chain of per-pixel operations —
  contrast dial, gamma, saturation, warm bias, contrast, brightness, black
  lift — and then *throws the chain away*. Every step here is a function of
  the pixel's value alone, so the whole thing collapses into a table: four
  colours for a DMG frame, thirty-two thousand for a colour one. Compiled
  once at boot, the panel costs nothing per frame, and the terminal, the
  window and the `--server` shell all get it for free.

  ## What is not here

  Three of the effects the panel really has are *not* functions of the
  pixel alone, and none of them belong in a lookup table:

    * the STN mixing with neighbouring pixels, and the column crosstalk of
      a passive matrix — spatial, they need the frame around the pixel;
    * the response curve — the pixel approaches its target exponentially,
      quickly when darkening (τ ≈ 21 ms), slowly when brightening
      (τ ≈ 61 ms), which is the asymmetry that makes real hardware feel the
      way it does. Temporal: it needs a state buffer between frames;
    * the dot structure — the grid, the reflector showing through the gaps,
      the shadow each dot casts. That one lives at *display* resolution,
      not at 160×144, and belongs on a GPU.

  ## The constants

  Empirical, and mine: starting points chosen by eye against photo-matched
  palettes, not measurements. They are meant to be moved. The one set with
  a real pedigree is the colour matrix — the correction ares applies to CGB
  output, verified coefficient for coefficient against ares/gb/ppu/color.cpp.
  """

  import Bitwise

  defstruct preset: :raw, shades: nil, colors: nil

  @type preset :: :raw | :dmg | :pocket | :cgb
  @type t :: %__MODULE__{
          preset: preset(),
          shades: {binary(), binary(), binary(), binary()},
          colors: binary() | nil
        }

  @presets [:raw, :dmg, :pocket, :cgb]

  @doc "The panels on offer, in menu order."
  @spec presets() :: [preset()]
  def presets, do: @presets

  @doc "The next panel in the cycle — what the menu's left/right does."
  @spec next(preset(), -1 | 1) :: preset()
  def next(preset, direction) do
    i = Enum.find_index(@presets, &(&1 == preset)) || 0
    Enum.at(@presets, rem(i + direction + length(@presets), length(@presets)))
  end

  @doc """
  Compiles a panel into its tables.

  `palette` only matters for `:raw`, which is the absence of a panel — the
  shades stay exactly what `Screen.to_rgb/2` has always produced. Every
  other preset carries its own four colours and ignores the choice.

  `color?` says whether the cartridge runs in colour: the 32768-entry table
  costs a moment to build and a hundred kilobytes to hold, and a monochrome
  game will never read a single entry of it.
  """
  @spec compile(preset(), :dmg | :gray, boolean()) :: t()
  def compile(preset, palette \\ :dmg, color? \\ false)

  def compile(:raw, palette, _color?),
    do: %__MODULE__{preset: :raw, shades: raw_shades(palette), colors: nil}

  def compile(preset, _palette, color?) when preset in @presets do
    profile = profile(preset)

    %__MODULE__{
      preset: preset,
      shades: compile_shades(profile),
      colors: if(color?, do: compile_colors(profile))
    }
  end

  # The two palettes as they have always been: the web's green, and the
  # greys. `:raw` promises no change at all, so the bytes are the old ones.
  defp raw_shades(:dmg),
    do: {<<0x9B, 0xBC, 0x0F>>, <<0x8B, 0xAC, 0x0F>>, <<0x30, 0x62, 0x30>>, <<0x0F, 0x38, 0x0F>>}

  defp raw_shades(_gray),
    do: {<<0xFF, 0xFF, 0xFF>>, <<0xAA, 0xAA, 0xAA>>, <<0x55, 0x55, 0x55>>, <<0x00, 0x00, 0x00>>}

  # ── The profiles ────────────────────────────────────────────────────────────

  # `base` is the panel lit by ambient light, before the chain runs;
  # `background` the reflector with nothing driven onto it — where the dial
  # pulls the image when it is turned down. `density` is the dial itself:
  # 0.5 neutral, up towards ink, down towards bare reflector.
  defp profile(:dmg) do
    %{
      base: [0xC4CFA1, 0x8B956D, 0x4D533C, 0x1F1F1F],
      background: 0xD2DCB0,
      density: 0.56,
      gamma: 1.05,
      saturation: 1.12,
      warm: {1.00, 1.00, 0.94},
      contrast: 1.08,
      brightness: 0.98,
      lift: 0.02,
      matrix: nil
    }
  end

  # The Pocket's FSTN: the green gone, the contrast far better, a paper
  # warmth left in the white.
  defp profile(:pocket) do
    %{
      base: [0xE0DBCD, 0xA89F94, 0x706B66, 0x2B2B26],
      background: 0xEDE9DC,
      density: 0.50,
      gamma: 1.00,
      saturation: 0.85,
      warm: {1.02, 1.00, 0.97},
      contrast: 1.12,
      brightness: 1.00,
      lift: 0.01,
      matrix: nil
    }
  end

  # The Color: no dial to turn, a panel that darkens and desaturates, and
  # the whites that never quite arrive — the matrix caps them at 240.
  defp profile(:cgb) do
    %{
      base: [0xF0F0E8, 0xB0B0A6, 0x686860, 0x24241E],
      background: 0xF4F4EC,
      density: 0.50,
      gamma: 1.06,
      saturation: 0.96,
      warm: {1.00, 1.00, 1.01},
      contrast: 1.02,
      brightness: 1.00,
      lift: 0.02,
      # The correction ares applies to CGB output (ares/gb/ppu/color.cpp,
      # verified against the source): a channel mix clamped at 960 on a
      # 10-bit scale — which is why a CGB white tops out around 94%, never
      # at full brightness.
      matrix: {{26, 4, 2}, {0, 24, 8}, {6, 4, 22}}
    }
  end

  # ── The tables ──────────────────────────────────────────────────────────────

  defp compile_shades(profile) do
    profile.base
    |> Enum.map(&(&1 |> unpack() |> chain(profile) |> pack()))
    |> List.to_tuple()
  end

  # RGB555 in, RGB888 out, all 32768 of them: three bytes per entry, read
  # back by offset. Built once — a hundred kilobytes and a moment of boot.
  defp compile_colors(profile) do
    for c <- 0..0x7FFF, into: <<>> do
      {c &&& 0x1F, bsr(c, 5) &&& 0x1F, bsr(c, 10) &&& 0x1F}
      |> matrix(profile.matrix)
      |> chain(profile)
      |> pack()
    end
  end

  # The five-bit channels through the colour matrix, or simply widened to
  # eight bits when the profile carries none. Either way the chain that
  # follows works in 0..1.
  defp matrix({r, g, b}, nil), do: {x8(r) / 255, x8(g) / 255, x8(b) / 255}

  defp matrix({r, g, b}, {{rr, rg, rb}, {gr, gg, gb}, {br, bg, bb}}) do
    {mix5(r * rr + g * rg + b * rb), mix5(r * gr + g * gg + b * gb),
     mix5(r * br + g * bg + b * bb)}
  end

  # Each row of the matrix sums to 32, so a saturated channel reaches 992:
  # clamped at 960 and normalised from the 10-bit scale, exactly as ares
  # does (image::normalize(min(960, v), 10, 16)).
  defp mix5(v), do: min(960, v) / 1023

  # Five bits widened to eight: the high bits copied into the low ones.
  defp x8(v), do: bsl(v, 3) ||| bsr(v, 2)

  # ── The chain ───────────────────────────────────────────────────────────────

  # The order is the panel's, and it is not commutative: the dial acts on
  # the raw colour, the gamma on what the dial left, and the black lift has
  # the last word because nothing on a reflective screen is ever truly
  # black.
  defp chain(rgb, profile) do
    rgb
    |> dial(profile)
    |> gamma(profile)
    |> saturation(profile)
    |> warm(profile)
    |> contrast(profile)
    |> brightness(profile)
    |> lift(profile)
  end

  # The dial the player could actually turn, and the one asymmetry that
  # matters: turned up, everything slides towards the darkest shade — which
  # is already there and so does not move, while shade 0 moves most.
  defp dial(rgb, %{density: d}) when d == 0.5, do: rgb

  defp dial(rgb, %{density: d} = profile) do
    if d > 0.5 do
      blend(rgb, unpack(List.last(profile.base)), (d - 0.5) * 2.0)
    else
      blend(rgb, unpack(profile.background), (0.5 - d) * 2.0)
    end
  end

  defp gamma(rgb, %{gamma: g}), do: map3(rgb, &:math.pow(max(&1, 0.0), g))

  defp saturation({r, g, b}, %{saturation: s}) do
    luma = 0.299 * r + 0.587 * g + 0.114 * b
    {luma + (r - luma) * s, luma + (g - luma) * s, luma + (b - luma) * s}
  end

  defp warm({r, g, b}, %{warm: {wr, wg, wb}}), do: {r * wr, g * wg, b * wb}

  defp contrast(rgb, %{contrast: k}), do: map3(rgb, &((&1 - 0.5) * k + 0.5))

  defp brightness(rgb, %{brightness: v}), do: map3(rgb, &(&1 * v))

  defp lift(rgb, %{lift: l}), do: map3(rgb, &(l + &1 * (1.0 - l)))

  # ── Small change ────────────────────────────────────────────────────────────

  defp blend({r1, g1, b1}, {r2, g2, b2}, t),
    do: {r1 + (r2 - r1) * t, g1 + (g2 - g1) * t, b1 + (b2 - b1) * t}

  defp map3({r, g, b}, f), do: {f.(r), f.(g), f.(b)}

  defp unpack(hex),
    do: {(bsr(hex, 16) &&& 0xFF) / 255, (bsr(hex, 8) &&& 0xFF) / 255, (hex &&& 0xFF) / 255}

  defp pack({r, g, b}), do: <<byte(r), byte(g), byte(b)>>

  defp byte(v), do: round(min(1.0, max(0.0, v)) * 255)
end
