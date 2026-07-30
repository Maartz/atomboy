defmodule Atomboy.Screen do
  @moduledoc """
  The frame loop: the CPU advances scanline by scanline, LY lives, the PPU
  renders.

  This is the structure the brief called for: the CPU runs for 456 T-cycles
  — one scanline — then the simulated hardware moves up a notch. Here "the
  hardware" boils down to LY (0xFF44), which games poll while waiting for
  vblank; the register is written into the map between two slices, exactly
  where the phase-3 PPU came to plug itself in.

  Rendering happens line by line during the visible part of the last frame
  requested — so the scroll registers are read at the scanline, as on the
  panel, not frozen at the end of the frame.
  """

  import Bitwise

  alias Atomboy.CPU.CartLoop
  alias Atomboy.CPU.State
  alias Atomboy.PPU

  @line_cycles 456
  @visible 144
  @lines 154

  @doc """
  Runs `frames` frames from the boot state and returns the last one.

  Returns `{frame, state, ram}`.
  """
  @spec run(Path.t(), pos_integer(), keyword()) :: {PPU.frame(), State.t(), map()}
  def run(rom_path, frames, opts \\ []) do
    rom = load(rom_path)
    dmg? = Keyword.get(opts, :dmg, false)
    state = boot_state(rom, dmg?)
    ram = boot_ram(rom, dmg?)

    Enum.reduce(1..frames, {<<>>, state, ram}, fn frame_index, {_frame, state, ram} ->
      render? = frame_index == frames
      frame(state, rom, ram, render?)
    end)
  end

  @doc """
  The state of the registers on leaving the DMG boot ROM — the starting
  point of every game.
  """
  @spec boot_state() :: State.t()
  def boot_state do
    %State{
      a: 0x01,
      f: 0xB0,
      b: 0x00,
      c: 0x13,
      d: 0x00,
      e: 0xD8,
      h: 0x01,
      l: 0x4D,
      sp: 0xFFFE,
      pc: 0x0100
    }
  end

  @doc """
  The starting memory map: the number of banks, the MBC family (header
  0x147: MBC3 for 0x0F-0x13, MBC5 for 0x19-0x1E, MBC1 otherwise) and color
  mode (0x143: 0x80 "enhanced", 0xC0 "only").

  `dmg?` forces the monochrome machine — the equivalent of slotting the
  cartridge into a real DMG.
  """
  @spec boot_ram(binary(), boolean()) :: map()
  def boot_ram(rom, dmg? \\ false) do
    mbc =
      case :binary.at(rom, 0x147) do
        t when t in 0x0F..0x13 -> :mbc3
        t when t in 0x19..0x1E -> :mbc5
        _ -> :mbc1
      end

    base = %{rom_banks: div(byte_size(rom), 0x4000), mbc: mbc}

    if not dmg? and :binary.at(rom, 0x143) in [0x80, 0xC0] do
      Map.put(base, :cgb, true)
    else
      base
    end
  end

  @doc """
  The boot state according to the cartridge: A is 0x11 on a Game Boy Color —
  that is how "enhanced" games choose their colors.
  """
  @spec boot_state(binary(), boolean()) :: State.t()
  def boot_state(rom, dmg? \\ false) do
    if not dmg? and :binary.at(rom, 0x143) in [0x80, 0xC0] do
      %{boot_state() | a: 0x11}
    else
      boot_state()
    end
  end

  @doc """
  One machine frame: 154 scanlines, rendered if `render?`.
  Returns `{pixels, state, ram}` — pixels is empty without rendering.
  """
  @spec frame(State.t(), binary(), map(), boolean()) :: {PPU.frame(), State.t(), map()}
  def frame(state, rom, ram, render?) do
    {pixels, state, ram, _window_line} =
      Enum.reduce(0..(@lines - 1), {<<>>, state, ram, 0}, fn ly,
                                                             {pixels, state, ram, window_line} ->
        {state, ram} = step_line(state, rom, ram, ly)

        if render? and ly < @visible do
          {line, window_line} = PPU.render_line(ram, ly, window_line)
          {pixels <> line, state, ram, window_line}
        else
          {pixels, state, ram, window_line}
        end
      end)

    {pixels, state, ram}
  end

  @doc """
  One machine scanline: LY advances, vblank rises at line 144, the CPU runs
  456 T-cycles, the timer catches up with them. The common brick of every
  frame loop — Screen, the blargg runner, and phase 3 one day.
  """
  @spec step_line(State.t(), binary(), map(), 0..153) :: {State.t(), map()}
  def step_line(state, rom, ram, ly) do
    lcd_on? = band(Map.get(ram, 0xFF40, 0x91), 0x80) != 0
    ram = ppu_line(ram, ly, lcd_on?)

    # At double speed (KEY1, GBC) the CPU swallows twice as many cycles per
    # scanline — the PPU keeps its own rhythm.
    budget = @line_cycles * Map.get(ram, :speed, 1)
    {state, ram, cycles} = CartLoop.run(state, rom, ram, budget)

    # A GDMA posted during the line is consumed as soon as the line is done
    # — at worst 456 cycles behind the hardware, which copies on the spot.
    ram = gdma(rom, ram)
    ram = hdma(rom, ram, ly, lcd_on?)

    # The link cable resolves at the scanline — real hardware latency.
    ram = if :erlang.is_map_key(:link, ram), do: Atomboy.Link.line(ram), else: ram
    {state, Atomboy.Timer.advance(ram, cycles)}
  end

  # The general transfer (GDMA): posted by the write to HDMA5, executed here
  # — the source may sit in banked ROM, which only this loop holds.
  defp gdma(rom, ram) do
    case Map.get(ram, :gdma) do
      nil ->
        ram

      {src, dst, blocks} ->
        ram = copy(rom, Map.delete(ram, :gdma), src, dst, blocks * 16)
        ram
    end
  end

  # HDMA: one sixteen-byte block per HBlank of a visible line, screen on.
  # Once finished, HDMA5 reads back as 0xFF.
  defp hdma(rom, ram, ly, lcd_on?) do
    case Map.get(ram, :hdma) do
      {src, dst, blocks} when lcd_on? and ly < @visible ->
        ram = copy(rom, ram, src, dst, 16)

        if blocks == 1 do
          ram |> Map.delete(:hdma) |> Map.put(0xFF55, 0xFF)
        else
          Map.put(ram, :hdma, {src + 16, dst + 16, blocks - 1})
        end

      _ ->
        ram
    end
  end

  defp copy(rom, ram, src, dst, len) do
    Enum.reduce(0..(len - 1), ram, fn i, ram ->
      CartLoop.poke(ram, dst + i, CartLoop.peek(rom, ram, src + i))
    end)
  end

  # Screen off: the PPU no longer scans. LY stays at zero, no vblank, no
  # coincidence — the hardware stops the generator, not just the display.
  #
  # This is a trap with far-reaching consequences: games turn the screen off
  # to reload VRAM (Pokémon does it on every map change, staircases
  # included) and keep calling their sound engine from the main loop, with
  # interrupts open. A phantom vblank then re-enters that engine on top of
  # itself: its shared channel counter restarts from zero, the outer loop no
  # longer stops at eight, its structure pointer walks all the way into the
  # stack, and the CPU ends up executing dialogue text — illegal opcode E3,
  # seconds away from its cause.
  defp ppu_line(ram, _ly, false) do
    ram
    |> Map.put(0xFF44, 0)
    |> Map.put(0xFF41, band(Map.get(ram, 0xFF41, 0), 0xF8))
  end

  defp ppu_line(ram, ly, true) do
    ram = Map.put(ram, 0xFF44, ly)

    # Entering vblank raises bit 0 of IF — the interrupt games wait for
    # before touching VRAM. The servicing itself lives in the loop's fetch.
    ram =
      if ly == @visible do
        Map.update(ram, 0xFF0F, 0x01, &bor(&1, 0x01))
      else
        ram
      end

    # The LY=LYC coincidence: bit 2 of STAT reflects it, and if the game has
    # armed bit 6 the STAT interrupt fires — this is the tool of raster
    # effects, and dmg-acid2 used to fall asleep on it.
    stat = Map.get(ram, 0xFF41, 0)

    if ly == Map.get(ram, 0xFF45, 0) do
      ram = Map.put(ram, 0xFF41, bor(stat, 0x04))

      if band(stat, 0x40) != 0 do
        Map.update(ram, 0xFF0F, 0x02, &bor(&1, 0x02))
      else
        ram
      end
    else
      Map.put(ram, 0xFF41, band(stat, 0xFB))
    end
  end

  @doc """
  Loads a ROM: small ones are padded to 32 KB; large ones keep their banks
  as they are, and CartLoop's MBC1 does the rest.
  """
  @spec load(Path.t()) :: binary()
  def load(path) do
    rom = File.read!(path)

    if byte_size(rom) < 0x8000 do
      rom <> :binary.copy(<<0xFF>>, 0x8000 - byte_size(rom))
    else
      rom
    end
  end

  @doc """
  The frame as text for the terminal: two scanlines per character row, the
  half block `▀` carrying the top line as foreground and the bottom one as
  background, four ANSI grays for the four shades.

  The color sequence is only emitted when the pair changes — flat areas,
  which dominate a game frame, cost one byte per cell. That is what lets a
  terminal keep up with 60 frames per second.
  """
  @spec to_text(PPU.frame(), :gray | :dmg) :: String.t()
  def to_text(frame, palette \\ :gray)

  # The color frame: half blocks in truecolor, via the RGB of the game's palettes.
  def to_text(frame, palette) when byte_size(frame) == 2 * 160 * 144 do
    rgb = to_rgb(frame, palette)
    {width, height} = PPU.dimensions()

    rows =
      for row <- 0..(div(height, 2) - 1) do
        top = :binary.part(rgb, row * 2 * width * 3, width * 3)
        bottom = :binary.part(rgb, (row * 2 + 1) * width * 3, width * 3)

        {cells, _} =
          Enum.map_reduce(0..(width - 1), nil, fn x, prev ->
            <<r1, g1, b1>> = :binary.part(top, x * 3, 3)
            <<r2, g2, b2>> = :binary.part(bottom, x * 3, 3)
            pair = {r1, g1, b1, r2, g2, b2}

            if pair == prev do
              {"▀", prev}
            else
              {"\e[38;2;#{r1};#{g1};#{b1};48;2;#{r2};#{g2};#{b2}m▀", pair}
            end
          end)

        [cells, "\e[0m\n"]
      end

    IO.iodata_to_binary(rows)
  end

  def to_text(frame, palette) do
    {width, height} = PPU.dimensions()
    colors = colors(palette)

    rows =
      for row <- 0..(div(height, 2) - 1) do
        top = :binary.part(frame, row * 2 * width, width)
        bottom = :binary.part(frame, (row * 2 + 1) * width, width)

        {cells, _} =
          Enum.map_reduce(0..(width - 1), nil, fn x, prev ->
            fg = elem(colors, :binary.at(top, x))
            bg = elem(colors, :binary.at(bottom, x))
            pair = {fg, bg}

            if pair == prev do
              {"▀", prev}
            else
              {"\e[38;#{fg};48;#{bg}m▀", pair}
            end
          end)

        [cells, "\e[0m\n"]
      end

    IO.iodata_to_binary(rows)
  end

  # The shades precompiled as SGR parameters: 256 colors for the grays,
  # truecolor for the green of the original DMG panel.
  defp colors(:gray), do: {"5;255", "5;250", "5;243", "5;236"}

  defp colors(:dmg) do
    {"2;155;188;15", "2;139;172;15", "2;48;98;48", "2;15;56;15"}
  end

  @doc """
  The frame in the kitty graphics protocol: a real image in the terminal.

  The DMG pixel becomes an RGB pixel transmitted in APC (`ESC _ G … ESC \\`),
  zlib then base64 — a four-shade frame compresses down to ~2 KB. The `r=`
  placement lets the terminal pick the width while keeping the aspect ratio;
  `C=1` nails the cursor down; `q=2` silences the acknowledgements. Two ids
  alternate as a double buffer: the new image lands on top of the old one,
  which is only erased afterwards — no gap, no flicker.
  """
  @spec to_kitty(PPU.frame(), :gray | :dmg, pos_integer(), pos_integer()) :: iodata()
  def to_kitty(frame, palette, id, rows) do
    payload = frame |> to_rgb(palette) |> :zlib.compress() |> Base.encode64()

    {width, height} = PPU.dimensions()
    head = "a=T,i=#{id},f=24,s=#{width},v=#{height},o=z,q=2,C=1,r=#{rows}"

    case chunks(payload) do
      [only] ->
        ["\e_G", head, ";", only, "\e\\"]

      [first | rest] ->
        {middle, [last]} = Enum.split(rest, -1)

        [
          ["\e_G", head, ",m=1;", first, "\e\\"],
          Enum.map(middle, &["\e_Gm=1;", &1, "\e\\"]),
          ["\e_Gm=0;", last, "\e\\"]
        ]
    end
  end

  @doc """
  The frame in 24-bit RGB — three bytes per pixel. A DMG frame (one byte per
  pixel) goes through the chosen palette; a color frame (RGB555, two bytes
  per pixel) expands to RGB888, the game's own palette being authoritative.
  """
  @spec to_rgb(PPU.frame(), :gray | :dmg) :: binary()
  def to_rgb(frame, palette) when byte_size(frame) == 160 * 144 do
    rgb = rgb_palette(palette)
    for <<shade <- frame>>, into: <<>>, do: elem(rgb, shade)
  end

  def to_rgb(frame, _palette) do
    for <<c::16-little <- frame>>, into: <<>> do
      <<x8(c &&& 0x1F), x8(bsr(c, 5) &&& 0x1F), x8(bsr(c, 10) &&& 0x1F)>>
    end
  end

  # 5 bits widened to 8: the high bits copied into the low ones, exact scale.
  defp x8(v), do: bsl(v, 3) ||| bsr(v, 2)

  # The protocol caps payload chunks at 4096 bytes.
  defp chunks(<<chunk::binary-size(4096), rest::binary>>), do: [chunk | chunks(rest)]
  defp chunks(last), do: [last]

  # The four shades in RGB: the original panel's green, or the grays.
  defp rgb_palette(:dmg),
    do: {<<0x9B, 0xBC, 0x0F>>, <<0x8B, 0xAC, 0x0F>>, <<0x30, 0x62, 0x30>>, <<0x0F, 0x38, 0x0F>>}

  defp rgb_palette(:gray),
    do: {<<0xFF, 0xFF, 0xFF>>, <<0xAA, 0xAA, 0xAA>>, <<0x55, 0x55, 0x55>>, <<0x00, 0x00, 0x00>>}

  @doc """
  The frame as binary PGM (P5) — readable by any image viewer.
  """
  @spec to_pgm(PPU.frame()) :: binary()
  def to_pgm(frame) when byte_size(frame) == 160 * 144 do
    {width, height} = PPU.dimensions()
    shades = {0xFF, 0xAA, 0x55, 0x00}
    pixels = for <<shade <- frame>>, into: <<>>, do: <<elem(shades, shade)>>
    "P5\n#{width} #{height}\n255\n" <> pixels
  end

  # The color frame as PPM (P6) — true color, readable everywhere.
  def to_pgm(frame) do
    {width, height} = PPU.dimensions()
    "P6\n#{width} #{height}\n255\n" <> to_rgb(frame, :dmg)
  end
end
