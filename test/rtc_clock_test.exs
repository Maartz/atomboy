defmodule Atomboy.RTCClockTest do
  use ExUnit.Case

  import ExUnit.CaptureIO

  alias Atomboy.CPU.CartLoop
  alias Atomboy.CPU.State
  alias Atomboy.Library
  alias Atomboy.Movie
  alias Atomboy.Play
  alias Atomboy.Screen

  @moduletag :tmp_dir

  # Three days, four hours, five minutes and six seconds into the future —
  # a shift with something in every one of the five registers.
  @shift 3 * 86_400 + 4 * 3600 + 5 * 60 + 6

  # The clock's own horizon: nine bits of days, and then it starts again.
  @wrap 512 * 86_400

  # Long enough that the served clock ticks inside the take (a second of
  # machine is 59.7 frames), short enough to run twice over.
  @frames 90

  # The gap between recording and replaying. A second and a half apart, the
  # wall clock's seconds register cannot possibly agree with itself — which
  # is exactly what a movie must not depend on.
  @gap 1_500

  setup do
    {:ok, null} = File.open("/dev/null", [:write, encoding: :unicode])
    Process.group_leader(self(), null)
    :ok
  end

  describe "the offset" do
    test "the console's clock is moved by exactly what it was told" do
      here = latched(0)
      ahead = latched(@shift)
      behind = latched(-@shift)

      # Two runs a fraction of a millisecond apart: the shift is the offset,
      # give or take the second that may have turned between them.
      assert rem(ahead - here + @wrap, @wrap) in @shift..(@shift + 1)
      assert rem(here - behind + @wrap, @wrap) in @shift..(@shift + 1)
    end

    test "the offset survives in the machine, not in the environment" do
      ram = CartLoop.set_rtc_offset(%{}, -90)

      assert CartLoop.rtc_offset(ram) == -90
      assert CartLoop.rtc_offset(%{}) == 0
      # The epoch a take is anchored on is that clock, read now.
      assert_in_delta CartLoop.rtc_epoch(ram), System.os_time(:second) - 90, 1
    end

    test "a latched clock stays where it was latched until it is latched again" do
      rom = rom()
      {_state, ram, _cycles} = play(rom, 0)
      frozen = ram[:rtc_latch]

      # The console jumps two hours forward under a cartridge that has
      # already taken its snapshot: the registers do not move.
      moved = CartLoop.rtc_virtual(ram, instant(frozen) + 7200)
      seconds = CartLoop.poke(moved, 0x4000, 0x08)

      assert CartLoop.peek(rom, seconds, 0xA000) == frozen[0x08]

      assert CartLoop.poke(moved, 0x4000, 0x0A) |> then(&CartLoop.peek(rom, &1, 0xA000)) ==
               frozen[0x0A]

      # Latch again — 0 then 1, as a game does — and the two hours arrive
      # all at once.
      relatched =
        seconds
        |> CartLoop.poke(0x6000, 0x00)
        |> CartLoop.poke(0x6000, 0x01)

      assert CartLoop.peek(rom, relatched, 0xA000) == frozen[0x08]
      assert relatched[:rtc_latch][0x0A] == rem(frozen[0x0A] + 2, 24)
    end

    test "the clock op reaches the machine, sign and all", %{tmp_dir: dir} do
      # The cartridge paints the day counter, which no test run is long
      # enough to see turn: two streams differ only if the op arrived.
      here = frames_of(dir, [])
      tomorrow = frames_of(dir, [{:clock, 86_400}])
      yesterday = frames_of(dir, [{:clock, -86_400}])

      assert tomorrow != here
      assert yesterday != here
      assert yesterday != tomorrow

      # The day register is eight bits and a ninth: 512 days on, the
      # cartridge is told the same thing it is told today. A mangled sign or
      # a truncated payload lands anywhere but here.
      assert frames_of(dir, [{:clock, @wrap}]) == here
      assert frames_of(dir, [{:clock, -@wrap}]) == here
    end
  end

  describe "the take's own hour" do
    test "time is counted in frames, from the anchor" do
      movie = Movie.new(rom(), {:boot, :none}, epoch: 1_000_000)

      assert Movie.epoch(movie) == 1_000_000
      assert Movie.clock(movie, 0) == 1_000_000
      # 59.7 frames to the second: the first one lands at 59, not at 60.
      assert Movie.clock(movie, 59) == 1_000_000
      assert Movie.clock(movie, 60) == 1_000_001
      # 216,000 frames is an hour and the sixteen seconds a 59.7 Hz panel
      # owes a clock that counts in sixties.
      assert Movie.clock(movie, 60 * 60 * 60) == 1_000_000 + 3616
    end

    test "a movie with no epoch falls back on the hour it was written" do
      movie = Movie.new(rom(), {:boot, :none}, created_at: "2026-08-08T22:39:00Z")

      assert Movie.epoch(%{movie | header: Map.delete(movie.header, :epoch)}) ==
               DateTime.to_unix(~U[2026-08-08 22:39:00Z])

      # Not even a date: the epoch itself, so that the take is at least the
      # same take on every machine.
      assert Movie.epoch(%Movie{}) == 0
    end
  end

  describe "the clock under a movie" do
    test "a take that reads the clock replays frame for frame, later", %{tmp_dir: dir} do
      ctx = Play.start_recording(console(dir), anchor: :boot, author: "the test")
      {ctx, recorded} = run(ctx, @frames)
      {movie, _ctx} = Play.stop_movie(ctx)

      # The machine ran the clock: the seconds it read moved during the take.
      assert Movie.frames(movie) == @frames

      Process.sleep(@gap)

      ctx = Play.start_replay(console(dir), movie)
      {_ctx, replayed} = run(ctx, @frames)

      assert replayed == recorded
    end

    test "a movie written before the header had an hour still plays", %{tmp_dir: dir} do
      ctx = Play.start_recording(console(dir), anchor: :boot, created_at: "2026-08-08T22:39:00Z")
      {ctx, _witnesses} = run(ctx, 20)
      {movie, _ctx} = Play.stop_movie(ctx)

      # A file as an older release wrote it: the field taken back out by
      # hand, which is exactly what a movie from Task 1 looks like.
      path = Path.join(dir, "before-the-clock.tas")
      assert :ok = Movie.write(%{movie | header: Map.delete(movie.header, :epoch)}, path)
      {:ok, old} = Movie.read(path)

      assert old.header.epoch == nil
      assert Movie.epoch(old) == DateTime.to_unix(~U[2026-08-08 22:39:00Z])

      {_ctx, once} = run(Play.start_replay(console(dir), old), 20)
      Process.sleep(@gap)
      {_ctx, twice} = run(Play.start_replay(console(dir), old), 20)

      assert twice == once
    end
  end

  # ── The bench ───────────────────────────────────────────────────────────────

  defp run(ctx, frames) do
    Enum.reduce(0..(frames - 1)//1, {ctx, []}, fn _n, {ctx, witnesses} ->
      ctx = Play.drive(%{ctx | max_frames: ctx.frame + 1})
      {ctx, witnesses ++ [witness(ctx)]}
    end)
  end

  # The same witness the movie tests weigh a frame with: the registers, every
  # write the machine has made — the latched clock included — the APU and the
  # pixels.
  defp witness(ctx),
    do: :erlang.crc32(:erlang.term_to_binary({ctx.state, ctx.ram, ctx.apu, ctx.last_frame}))

  # The clock ROM on the bare cartridge loop — no PPU, no frames, just the
  # program running long enough to latch and read.
  defp play(rom, offset) do
    ram = rom |> Screen.boot_ram() |> CartLoop.set_rtc_offset(offset)
    CartLoop.run(%State{pc: 0x100}, rom, ram, 2000)
  end

  defp latched(offset) do
    {_state, ram, _cycles} = play(rom(), offset)
    instant(ram[:rtc_latch])
  end

  # The five registers read back as the one number they describe: seconds
  # since a day 512 days ago, which is as far as an MBC3 can count.
  defp instant(latch) do
    latch[0x08] + 60 * latch[0x09] + 3600 * latch[0x0A] +
      86_400 * (latch[0x0B] + 256 * latch[0x0C])
  end

  # The pictures a server run puts on the wire, with the clock ops posted
  # ahead of the first drain — the day counter is what this cartridge paints,
  # and no test run is long enough to watch a day turn.
  defp frames_of(dir, ops) do
    path = Path.join(dir, "days.gb")
    File.write!(path, rom(0x0B))

    stream =
      capture_io([encoding: :latin1], fn ->
        Enum.each(ops, &send(self(), &1))
        assert :ok = Atomboy.Server.run(path, frames: 2, library: Path.join(dir, "library"))
      end)

    pictures(stream, [])
  end

  defp pictures(<<?F, rgb::binary-size(160 * 144 * 3), rest::binary>>, seen),
    do: pictures(rest, [rgb | seen])

  defp pictures(<<?A, n::16-big, _pcm::binary-size(n), rest::binary>>, seen),
    do: pictures(rest, seen)

  defp pictures(<<?P, _preset, rest::binary>>, seen), do: pictures(rest, seen)
  defp pictures(<<>>, seen), do: seen

  defp console(dir, opts \\ []) do
    path = Path.join(dir, "clock.gb")
    File.write!(path, rom())
    cartridge = Screen.load(path)
    lib = Library.open(cartridge, path, library: Path.join(dir, "library"))

    ctx = Play.context(cartridge, lib, Keyword.merge([frames: 0], opts))

    %{ctx | deadline: System.monotonic_time(:microsecond) - 1_000_000}
  end

  # An MBC3 cartridge that does nothing but ask the clock what time it is:
  # every frame it latches, reads the seconds and the minutes, sums them into
  # WRAM and lays the total on the background palette — so the time the
  # console believes it is ends up in the registers, in the map and in the
  # pixels at once.
  defp rom(reg \\ 0x08, title \\ "ATOMBOY CLOCK") do
    code = <<
      # LD A,$91 / LDH ($40),A — the LCD on, the background drawn
      0x3E,
      0x91,
      0xE0,
      0x40,
      # LD A,$0A / LD ($0000),A — the cartridge's RAM window unlocked
      0x3E,
      0x0A,
      0xEA,
      0x00,
      0x00,
      # XOR A / LD ($6000),A / LD A,$01 / LD ($6000),A — 0 then 1: the latch
      0xAF,
      0xEA,
      0x00,
      0x60,
      0x3E,
      0x01,
      0xEA,
      0x00,
      0x60,
      # LD A,reg / LD ($4000),A / LD A,($A000) / LD B,A — the register asked for
      0x3E,
      reg,
      0xEA,
      0x00,
      0x40,
      0xFA,
      0x00,
      0xA0,
      0x47,
      # LD A,$0C / LD ($4000),A / LD A,($A000) / ADD A,B — and the high days
      0x3E,
      0x0C,
      0xEA,
      0x00,
      0x40,
      0xFA,
      0x00,
      0xA0,
      0x80,
      # LD ($C000),A / LDH ($47),A / JP $0159 — into WRAM, onto the palette
      0xEA,
      0x00,
      0xC0,
      0xE0,
      0x47,
      0xC3,
      0x59,
      0x01
    >>

    :binary.copy(<<0>>, 0x8000)
    |> put(0x100, <<0xC3, 0x50, 0x01>>)
    |> put(0x134, title |> String.pad_trailing(0x10, <<0>>) |> binary_part(0, 0x10))
    # 0x10: MBC3 with a timer, RAM and a battery — the clock's own cartridge.
    |> put(0x147, <<0x10>>)
    |> put(0x14D, <<0x5A>>)
    |> put(0x14E, <<0x91, 0xE2>>)
    |> put(0x150, code)
  end

  defp put(binary, at, chunk) do
    tail = at + byte_size(chunk)

    binary_part(binary, 0, at) <> chunk <> binary_part(binary, tail, byte_size(binary) - tail)
  end
end
