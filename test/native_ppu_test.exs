defmodule Atomboy.NativePPUTest do
  @moduledoc """
  The native renderer against the Elixir one, pixel for pixel.

  Three statements, in increasing order of how much they prove:

    * **the directed cases** -- one per DMG rule, so a failure names the rule
      rather than a column number;
    * **the random states** -- random VRAM, random OAM, random registers, which
      is what finds the rules nobody wrote down;
    * **the acid2 frame** -- the 144 scanlines of a real game, snapshotted line
      by line, whose concatenation is byte for byte the frame
      `Atomboy.ScreenTest` freezes under CRC `0x9F51DD25`.

  All three compare inside the guest: the image carries the expected scanlines
  and the guest reports only what disagreed. See `Atomboy.Native.PPUBench`.

  ## What it costs, measured

  On the acid2 frame, under `qemu -icount shift=0`:

      per scanline   2,954 lowest / 4,872 mean / 7,433 highest
      per frame      701,666 retired instructions
      at 60 fps      42 M instructions per second
      code           1,192 bytes, plus 200 bytes of scratch

  Against a 160 MHz ESP32-C6 that is about a quarter of the core for the
  rendering alone -- viable, and not comfortable. The 32 KB instruction-cache
  budget, which is the reason this whole campaign exists, is untroubled: the
  renderer is under 4% of it.
  """

  use ExUnit.Case, async: true

  import Bitwise

  alias Atomboy.Native.Asm
  alias Atomboy.Native.PPU
  alias Atomboy.Native.PPUBench

  @moduletag :qemu
  @moduletag timeout: 900_000

  @acid2 "test/fixtures/dmg-acid2.gb"
  @acid2_crc 0x9F51DD25

  # The mean measured on the acid2 frame, with room for a change that costs a
  # little. A regression of a third is not a detail on a budget this tight.
  @instret_budget 6500

  describe "the differential bench" do
    test "no divergence on the directed cases" do
      {names, cases} = Enum.unzip(PPUBench.directed_cases())

      assert {:ok, report} = PPUBench.run(cases)

      assert report.divergences == [], """
      #{length(report.divergences)} divergence(s) between Atomboy.Native.PPU and Atomboy.PPU:

      #{format(report.divergences, names)}
      """
    end

    test "no divergence over random VRAM, OAM and registers" do
      cases = PPUBench.random_cases(48, 20_260_730)

      assert {:ok, report} = PPUBench.run(cases)

      assert report.divergences == [], """
      #{length(report.divergences)} divergence(s) on random states:

      #{format(report.divergences, [])}

      #{inputs(report.divergences, cases)}
      """
    end
  end

  describe "the acid2 frame" do
    test "144 scanlines of a real game, natively, are the frame Elixir shows" do
      cases = PPUBench.golden_cases(@acid2, 120)

      # The expectation the guest was compared against *is* the golden frame:
      # without this the test could pass against a frame nobody recognises.
      assert :erlang.crc32(PPUBench.expected_frame(cases)) == @acid2_crc,
             "the per-line snapshots no longer reproduce Atomboy.ScreenTest's frame"

      assert {:ok, report} = PPUBench.run(cases)

      assert report.divergences == [], """
      #{length(report.divergences)} divergence(s) over the acid2 frame:

      #{format(report.divergences, [])}
      """

      assert length(report.instret) == 144

      counts = Enum.map(report.instret, &elem(&1, 1))
      mean = div(Enum.sum(counts), length(counts))

      # Not a benchmark: a guard. The number decides whether the renderer fits
      # inside a 60 Hz frame on a 160 MHz core, so it belongs in the suite
      # rather than in a commit message.
      assert mean < @instret_budget,
             "a scanline now costs #{mean} instructions on average (budget #{@instret_budget}), " <>
               "worst line #{Enum.max(counts)} -- #{mean * 144 * 60} instructions per second at 60 fps"

      # A line that renders nothing at all would also stay under budget.
      assert Enum.min(counts) > 1000
    end
  end

  describe "the bench itself" do
    test "the directed cases are named once each" do
      {names, _cases} = Enum.unzip(PPUBench.directed_cases())

      assert names == Enum.uniq(names)
      assert length(names) >= 50, "the directed set has shrunk to #{length(names)} cases"
    end

    test "every payload is exactly one stride" do
      {_names, cases} = Enum.unzip(PPUBench.directed_cases())

      for {c, index} <- Enum.with_index(cases) do
        assert byte_size(PPUBench.payload(c)) == PPUBench.stride(),
               "case #{index} does not fill its stride"
      end
    end

    test "the sprite cases actually put a sprite on the line" do
      # The trap this test exists for: OAM Y is biased by 16, so a sprite
      # written at the scanline's own coordinate misses it by sixteen lines. The
      # comparison then passes on a picture with no sprite in it, and the whole
      # sprite path goes unverified. Turning LCDC bit 1 off has to change the
      # rendering -- if it does not, no sprite was ever drawn.
      for {name, c} <- PPUBench.directed_cases(),
          String.starts_with?(to_string(name), ["sprite_", "tall_", "overlap_", "behind_"]),
          name not in [:sprite_fully_left, :sprite_off_right, :sprite_blank_tile, :sprites_off] do
        {with_sprites, _} = Atomboy.PPU.render_line(c.ram, c.ly, c.window_line)
        without = Map.update!(c.ram, 0xFF40, &band(&1, bnot(0x02)))
        {without_sprites, _} = Atomboy.PPU.render_line(without, c.ly, c.window_line)

        assert with_sprites != without_sprites,
               "#{name} renders the same with sprites off: nothing was drawn"
      end
    end

    test "the sprite cases that draw nothing are the ones meant to" do
      for name <- [:sprite_fully_left, :sprite_off_right] do
        {_, c} = Enum.find(PPUBench.directed_cases(), &(elem(&1, 0) == name))
        {with_sprites, _} = Atomboy.PPU.render_line(c.ram, c.ly, c.window_line)
        without = Map.update!(c.ram, 0xFF40, &band(&1, bnot(0x02)))
        {without_sprites, _} = Atomboy.PPU.render_line(without, c.ly, c.window_line)

        assert with_sprites == without_sprites,
               "#{name} is supposed to fall entirely outside the screen"
      end
    end

    test "the window cases actually show a window" do
      shows_window? = fn c ->
        {_line, out} = Atomboy.PPU.render_line(c.ram, c.ly, c.window_line)
        out != c.window_line
      end

      cases = PPUBench.directed_cases()

      for name <- [:window_wx7, :window_wx0, :window_mid_line, :window_wx166, :window_at_wy] do
        {_, c} = Enum.find(cases, &(elem(&1, 0) == name))
        assert shows_window?.(c), "#{name} shows no window at all"
      end

      # And the ones testing the counter *not* moving must not move it.
      for name <- [
            :window_wx167,
            :window_wx255,
            :window_before_wy,
            :window_disabled,
            :background_off_window_frozen
          ] do
        {_, c} = Enum.find(cases, &(elem(&1, 0) == name))
        refute shows_window?.(c), "#{name} advanced the window counter"
      end
    end

    test "random cases land sprites on the scanline often enough" do
      cases = PPUBench.random_cases(20, 7)

      drawn =
        Enum.count(cases, fn c ->
          {with_sprites, _} = Atomboy.PPU.render_line(c.ram, c.ly, c.window_line)
          without = Map.update!(c.ram, 0xFF40, &band(&1, bnot(0x02)))
          {without_sprites, _} = Atomboy.PPU.render_line(without, c.ly, c.window_line)
          with_sprites != without_sprites
        end)

      assert drawn > 12, "only #{drawn} of 20 random cases drew a sprite"
    end

    test "a case pins the registers the oracle would otherwise default" do
      # `Atomboy.PPU` defaults LCDC to 0x91 and the three palettes to 0xE4 when
      # the key is missing. The guest reads a flat memory where missing means
      # zero, so a case that leaves them out compares two different states.
      ram = PPUBench.ram(%{})

      for address <- [0xFF40, 0xFF47, 0xFF48, 0xFF49] do
        assert Map.has_key?(ram, address),
               "0x#{Integer.to_string(address, 16)} is defaulted by the oracle and must be pinned"
      end
    end

    test "from_screen drops the keys that are not addresses" do
      ram = PPUBench.from_screen(%{:cgb => true, :mbc => :mbc1, 0x8000 => 0x42})

      refute Map.has_key?(ram, :cgb)
      refute Map.has_key?(ram, :mbc)
      assert ram[0x8000] == 0x42
      assert ram[0xFF40] == 0x91
    end
  end

  describe "the routines" do
    test "the entry point is emitted, and the scratch with it" do
      image = Asm.assemble([PPU.routines(), PPU.data()], 0x8000_0000)

      assert Map.has_key?(image.labels, PPU.label())
      assert Map.has_key?(image.labels, :ppu_sprite_layer)
    end

    test "the renderer stays a rounding error against the instruction cache" do
      image = Asm.assemble([PPU.routines(), PPU.data()], 0x8000_0000)

      # 32 KB is the C6's instruction cache and the reason this project exists.
      # The renderer measured 1,392 bytes including its scratch; 4 KB leaves room
      # for the unrolling the moduledoc argues for without hiding a blow-up.
      assert image.size < 4096,
             "the PPU now takes #{image.size} bytes of a 32 KB instruction cache"
    end

    test "the sprite layer's marker byte says what the routine encodes" do
      assert PPU.sprite_marker(0, false) == 0x80
      assert PPU.sprite_marker(3, false) == 0x83
      assert PPU.sprite_marker(2, true) == 0xC2

      # Never zero: zero is how the combine pass recognises an empty column.
      for shade <- 0..3, behind? <- [true, false] do
        assert PPU.sprite_marker(shade, behind?) != 0
      end
    end
  end

  # ── Reporting ───────────────────────────────────────────────────────────────

  defp format(divergences, names) do
    divergences
    |> Enum.take(12)
    |> Enum.map_join("\n", fn d ->
      name = Enum.at(names, d.case, d.case)

      case d do
        %{kind: :pixel, x: x, got: got, expected: want} ->
          "  #{name}: x=#{x} rendered shade #{got}, expected #{want}"

        %{kind: :window_line, got: got, expected: want} ->
          "  #{name}: window counter came back #{got}, expected #{want}"
      end
    end)
  end

  # A random case's inputs cannot be named, so they are spelled out: enough to
  # rebuild the failure without re-running the bench.
  defp inputs(divergences, cases) do
    divergences
    |> Enum.map(& &1.case)
    |> Enum.uniq()
    |> Enum.take(4)
    |> Enum.map_join("\n", fn index ->
      c = Enum.at(cases, index)

      registers =
        for {name, address} <- [
              lcdc: 0xFF40,
              scy: 0xFF42,
              scx: 0xFF43,
              bgp: 0xFF47,
              obp0: 0xFF48,
              obp1: 0xFF49,
              wy: 0xFF4A,
              wx: 0xFF4B
            ],
            do: "#{name}=0x#{Integer.to_string(Map.get(c.ram, address, 0), 16)}"

      "  case #{index}: ly=#{c.ly} window_line=#{c.window_line} " <> Enum.join(registers, " ")
    end)
  end
end
