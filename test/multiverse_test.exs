defmodule Atomboy.MultiverseTest do
  use ExUnit.Case

  import Bitwise
  import ExUnit.CaptureIO

  alias Atomboy.APU
  alias Atomboy.LCD
  alias Atomboy.Library
  alias Atomboy.Movie
  alias Atomboy.Screen

  @moduletag :tmp_dir

  # 160×144 in RGB24 — the size a frame takes on the wire, tagged or not.
  @picture 160 * 144 * 3

  # How long a comparison run lasts. Long enough that the four universes
  # have somewhere to drift to, short enough that a file of these tests
  # stays a handful of seconds: the loop paces itself at 59.7 Hz whether it
  # runs one machine or four.
  @frames 20

  # Where a mid-run operation is posted, in milliseconds. Comfortably inside
  # @frames of wall clock (~400 ms) and comfortably past the first frame, so
  # a run cut here has both halves in it.
  @midway 120

  # The four verbs of the `?S` operation, as the shell sends them.
  @fork 0x00
  @focus 0x10
  @commit 0x20
  @abort 0x30

  describe "the fork" do
    test "universe 0 is the run that would have happened anyway", %{tmp_dir: dir} do
      plain = timeline(run(dir, []))

      assert length(plain) == @frames

      # Forked before the first frame and never resolved: every frame of the
      # run is one of four, and universe 0's are the unsplit run's.
      split = run(dir, [{:key, ?S, @fork}])
      assert length(universes(split, 0)) == @frames
      assert timeline(split) == plain

      # And forked, then aborted halfway: the seam back into single-machine
      # play is not a seam at all — the frames carry straight on.
      resolved = run(dir, [{:key, ?S, @fork}], [{:key, ?S, @abort}])
      assert universes(resolved, 0) != []
      assert plain_frames(resolved) != []
      assert timeline(resolved) == plain
    end

    test "the other three universes draw different luck", %{tmp_dir: dir} do
      split = run(dir, [{:key, ?S, @fork}])
      zero = universes(split, 0)

      assert length(zero) == @frames

      for universe <- 1..3 do
        drawn = universes(split, universe)

        assert length(drawn) == @frames
        assert drawn != zero, "universe #{universe} never left universe 0"

        # Bounded: the nudge is a phase shift on the divider, and this
        # cartridge reads DIV every time round its loop — the two part
        # company inside the first handful of frames, not eventually.
        parted = Enum.find_index(Enum.zip(drawn, zero), fn {a, b} -> a != b end)
        assert parted < 10, "universe #{universe} took #{parted} frames to diverge"
      end

      # And they are three different futures, not one future drawn thrice.
      assert length(Enum.uniq(for u <- 1..3, do: universes(split, u))) == 3
    end

    test "the four are always at the same frame count", %{tmp_dir: dir} do
      split = run(dir, [{:key, ?S, @fork}])

      # The stream's own proof of lockstep: the universe bytes come out as
      # 0, 1, 2, 3 and start again — a machine that fell a frame behind
      # would break the cycle, and one that ran ahead would double a number.
      tags = for {:universe, u, _rgb} <- split, do: u

      assert tags == Enum.take(Stream.cycle([0, 1, 2, 3]), @frames * 4)
    end
  end

  describe "commit" do
    test "the machine that carries on is machine k, and no other", %{tmp_dir: dir} do
      # The reference: the same fork left to run, so every universe's frames
      # are on record from the fork to the end of the budget.
      reference = run(dir, [{:key, ?S, @fork}])

      for k <- 0..3 do
        committed = run(dir, [{:key, ?S, @fork}], [{:key, ?S, @commit ||| k}])
        split_for = length(universes(committed, k))

        # A run that never resolved, or one that resolved before it ever
        # forked, would let this test pass on nothing at all.
        assert split_for > 0 and split_for < @frames

        # What the single machine draws after the commit is what universe k
        # was drawing before it: the frames continue that timeline and no
        # other, frame for frame to the end of the run.
        assert plain_frames(committed) ==
                 reference |> universes(k) |> Enum.drop(split_for)
      end
    end

    test "abort is commit 0, exactly", %{tmp_dir: dir} do
      plain = timeline(run(dir, []))

      aborted = run(dir, [{:key, ?S, @fork}], [{:key, ?S, @abort}])
      zeroth = run(dir, [{:key, ?S, @fork}], [{:key, ?S, @commit ||| 0}])

      # Both land on the future that would have happened anyway — which is
      # the unsplit run, from the first frame to the last.
      assert timeline(aborted) == plain
      assert timeline(zeroth) == plain

      assert answers(aborted) == [{1, 0}, {0, 0}]
      assert answers(zeroth) == [{1, 0}, {0, 0}]
    end

    test "the take's stamp is not invented on the way out of a split", %{tmp_dir: dir} do
      path = rom_file(dir)

      capture_io([encoding: :latin1], fn ->
        post([{:key, ?S, @fork}])
        later([{:key, ?S, @abort}, {:key, ?R, 1}, {:key, ?R, 0}])
        assert :ok = Atomboy.Server.run(path, frames: 40, library: library(dir))
      end)

      # The take is anchored on the machine the commit installed. A commit
      # that stamped what it installed — or a fork that copied a stamped map
      # — would have left the loop's bookkeeping sitting in this anchor.
      assert {:snapshot, _state, ram, _apu} = newest_take(dir, path).anchor
      refute Map.has_key?(ram, :movie_take)
    end
  end

  describe "the sound" do
    test "the PCM is the focused universe's, and only one universe's", %{tmp_dir: dir} do
      plain = run(dir, [])
      heard = run(dir, [{:key, ?S, @fork}])

      # Four machines, one voice: a split that mixed all four, or emitted
      # four streams, would multiply what comes out.
      assert_in_delta pcm_bytes(heard), pcm_bytes(plain), pcm_bytes(plain) * 0.5

      # This cartridge gates the master switch on a bit of its own running
      # total, so every frame is either audible or digitally silent — the
      # sound carries the machine's identity, frame by frame.
      assert length(silences(plain)) == @frames
      assert length(silences(heard)) == @frames
      assert silences(heard) == silences(plain)

      elsewhere = run(dir, [{:key, ?S, @fork}, {:key, ?S, @focus ||| 1}])
      assert silences(elsewhere) != silences(heard)
    end

    test "switching focus switches the source, on the frame it is asked", %{tmp_dir: dir} do
      zero = silences(run(dir, [{:key, ?S, @fork}]))
      one = silences(run(dir, [{:key, ?S, @fork}, {:key, ?S, @focus ||| 1}]))

      switched = run(dir, [{:key, ?S, @fork}], [{:key, ?S, @focus ||| 1}])
      # The answer to the focus op sits in the stream between two frames:
      # everything before it was heard from universe 0, everything after it
      # from universe 1.
      at = Enum.count(Enum.take_while(switched, &(not match?({:split, 1, 1}, &1))), &pcm?/1)

      assert at > 0 and at < @frames

      heard = silences(switched)
      assert Enum.take(heard, at) == Enum.take(zero, at)
      assert Enum.drop(heard, at) == Enum.drop(one, at)
    end
  end

  describe "the refusals" do
    test "a fork is refused, and the machine does not move", %{tmp_dir: dir} do
      plain = timeline(run(dir, []))

      # While a take is being written, and while one is being read back.
      recording = run(dir, [{:key, ?R, 1}, {:key, ?S, @fork}])
      assert answers(recording) == [{0, 0}]
      assert universes(recording, 0) == []
      assert timeline(recording) == plain

      replaying = run(dir, [{:movie, :replay, a_take(dir)}, {:key, ?S, @fork}])
      assert answers(replaying) == [{0, 0}]
      assert universes(replaying, 0) == []

      # While turbo is engaged — the pacing a fork inherits has to be the
      # pacing the player was playing at.
      sprinting = run(dir, [{:key, ?T, 2}, {:key, ?+, ?T}, {:key, ?S, @fork}])
      assert answers(sprinting) == [{0, 0}]
      assert universes(sprinting, 0) == []

      # And while the reality is already split: the second fork is answered
      # with the truth about the first, and the four machines run on.
      twice = run(dir, [{:key, ?S, @fork}, {:key, ?S, @fork}])
      assert answers(twice) == [{1, 0}, {1, 0}]
      assert timeline(twice) == plain
    end

    test "a fork is refused with the cable plugged in", %{tmp_dir: dir} do
      port = 45_000 + :rand.uniform(2_000)
      {:ok, listening} = :gen_tcp.listen(port, [:binary, packet: :raw, active: false])
      partner = Task.async(fn -> :gen_tcp.accept(listening, 10_000) end)

      stream =
        capture_io([encoding: :latin1], fn ->
          post([{:key, ?S, @fork}])

          assert :ok =
                   Atomboy.Server.run(rom_file(dir),
                     frames: 3,
                     link: "127.0.0.1:#{port}",
                     library: library(dir)
                   )
        end)

      {:ok, peer} = Task.await(partner, 15_000)
      :gen_tcp.close(peer)
      :gen_tcp.close(listening)

      records = records(stream)
      assert answers(records) == [{0, 0}]
      assert universes(records, 0) == []
    end

    # Every operation a split has no answer for, refused from inside one.
    # The witness is the same in every case: universe 0 keeps drawing the
    # frames the unsplit run drew, so nothing the operation would have done
    # to the machine was done to it.
    test "a split refuses everything that would ask which universe", %{tmp_dir: dir} do
      plain = timeline(run(dir, []))
      saved = a_state(dir)

      refused = [
        {"a second fork", [{:key, ?S, @fork}]},
        {"recording", [{:key, ?R, 1}]},
        {"replay", [{:movie, :replay, a_take(dir)}]},
        {"a state written", [{:library, :save, "in-the-split"}]},
        {"a state loaded", [{:library, :load, saved}]},
        {"the rewind key", [{:key, ?+, ?W}]},
        {"turbo", [{:key, ?T, 2}, {:key, ?+, ?T}]}
      ]

      for {what, ops} <- refused do
        split = run(dir, [{:key, ?S, @fork} | ops])

        assert length(universes(split, 0)) == @frames, "#{what} cost the split its frames"
        assert timeline(split) == plain, "#{what} moved the machine"
        # Nothing the movie machinery does is announced, because nothing of
        # it happened: a refused take never reaches `?R` at all.
        assert movie_states(split) == [], "#{what} moved the take"
      end

      # And the state the split refused to write was not written.
      refute "in-the-split" in Enum.map(states(dir), & &1.name)
    end
  end

  describe "the price" do
    @tag timeout: 120_000
    test "what four futures cost per frame", %{tmp_dir: dir} do
      rom = Screen.load(rom_file(dir))
      lcd = LCD.compile(:raw, :dmg, false, nil)
      machine = warmed(rom)

      one = per_frame(fn -> step(rom, lcd, [machine]) end)
      four = per_frame(fn -> step(rom, lcd, List.duplicate(machine, 4)) end)

      IO.puts("""

      the multiverse, measured — #{inspect(:erlang.system_info(:schedulers_online))} schedulers online
        one machine  #{Float.round(one / 1000, 3)} ms/frame
        four in step #{Float.round(four / 1000, 3)} ms/frame  (×#{Float.round(four / one, 2)})
        the budget   16.742 ms/frame\
      """)

      assert four > 0
    end
  end

  # ── The bench ───────────────────────────────────────────────────────────────

  # A server run, with `ops` posted before the first drain and `after_ops`
  # posted into the middle of it. What comes back is the stream, parsed.
  defp run(dir, ops, after_ops \\ []) do
    path = rom_file(dir)

    stream =
      capture_io([encoding: :latin1], fn ->
        post(ops)
        later(after_ops)
        assert :ok = Atomboy.Server.run(path, frames: @frames, library: library(dir))
      end)

    records(stream)
  end

  # The loop drains its mailbox before the first frame, and the stdin reader
  # is nothing but a process filling that mailbox: an op posted here arrives
  # exactly as one read off the wire would.
  defp post(ops), do: Enum.each(ops, &send(self(), &1))

  # An op posted to arrive while the game is already running. @midway is far
  # enough into a @frames run that both halves of it hold frames.
  defp later(ops) do
    ops
    |> Enum.with_index()
    |> Enum.each(fn {op, n} -> Process.send_after(self(), op, @midway + n * 20) end)
  end

  # The stream taken apart by its own lengths — the only way to know that a
  # byte in it is an operation and not a pixel that happens to be one.
  defp records(<<?F, rgb::binary-size(@picture), rest::binary>>),
    do: [{:frame, :erlang.crc32(rgb)} | records(rest)]

  defp records(<<?U, universe, rgb::binary-size(@picture), rest::binary>>),
    do: [{:universe, universe, :erlang.crc32(rgb)} | records(rest)]

  defp records(<<?A, n::16-big, pcm::binary-size(n), rest::binary>>),
    do: [{:pcm, n, pcm == :binary.copy(<<0>>, n)} | records(rest)]

  defp records(<<?J, n::32-big, _json::binary-size(n), rest::binary>>), do: records(rest)
  defp records(<<?P, _preset, rest::binary>>), do: records(rest)
  defp records(<<?R, state, rest::binary>>), do: [{:movie, state} | records(rest)]
  defp records(<<?S, split, focus, rest::binary>>), do: [{:split, split, focus} | records(rest)]
  defp records(<<>>), do: []

  # The single machine's own timeline: the frames of universe 0 while the
  # reality is split, and the bare frames either side of it. A run that
  # forked, drifted and came home draws exactly what a run that never forked
  # drew — that is the whole of the null-perturbation proof.
  defp timeline(records) do
    Enum.flat_map(records, fn
      {:frame, crc} -> [crc]
      {:universe, 0, crc} -> [crc]
      _other -> []
    end)
  end

  defp universes(records, universe),
    do: for({:universe, ^universe, crc} <- records, do: crc)

  defp plain_frames(records), do: for({:frame, crc} <- records, do: crc)

  defp answers(records), do: for({:split, split, focus} <- records, do: {split, focus})

  defp movie_states(records), do: for({:movie, state} <- records, do: state)

  # One boolean per frame of sound: whether the record the frame put on the
  # wire was digital silence. The cartridge gates the APU's master switch on
  # its own running total, so this sequence is the machine's signature —
  # deterministic frame by frame, and different in every universe.
  defp silences(records), do: for({:pcm, _n, silent?} <- records, do: silent?)

  defp pcm_bytes(records), do: Enum.sum(for {:pcm, n, _silent?} <- records, do: n)

  defp pcm?({:pcm, _n, _silent?}), do: true
  defp pcm?(_record), do: false

  # ── What the refusals need to have something to refuse ───────────────────────

  # A take of this cartridge on disk, to be refused a replay of.
  defp a_take(dir) do
    path = Path.join(dir, "somebody-elses-run.tas")
    movie = %{Movie.new(Screen.load(rom_file(dir)), {:boot, :none}) | track: <<0, 0, 0, 0>>}
    :ok = Movie.write(movie, path)
    path
  end

  # A state written by a session that never forked, to be refused a load of.
  # It is taken a few frames in, so a load that went through would be
  # visible: the machine would jump somewhere the straight run never stood.
  defp a_state(dir) do
    capture_io([encoding: :latin1], fn ->
      later([{:library, :save, "before-the-fork"}])
      assert :ok = Atomboy.Server.run(rom_file(dir), frames: @frames, library: library(dir))
    end)

    "before-the-fork"
  end

  defp states(dir) do
    rom_path = rom_file(dir)
    rom = Screen.load(rom_path)
    Library.list(Library.open(rom, rom_path, library: library(dir)))
  end

  defp newest_take(dir, rom_path) do
    rom = Screen.load(rom_path)
    lib = Library.open(rom, rom_path, library: library(dir))
    [path | _older] = Library.movies(lib)
    {:ok, movie} = Movie.read(path)
    movie
  end

  defp library(dir), do: Path.join(dir, "library")

  # ── The measurement ─────────────────────────────────────────────────────────

  # The split's own step, lifted out of the loop: the machines in parallel,
  # each rendering its own frame and turning it into RGB where the work can
  # be spread. Timed here without the loop's pacing, which would hide it.
  defp step(rom, lcd, machines) do
    machines
    |> Enum.map(fn {state, ram, apu} ->
      Task.async(fn ->
        {pixels, state, ram} = Screen.frame(state, rom, ram, true)
        {Screen.to_rgb(pixels, :dmg, lcd), state, ram, apu}
      end)
    end)
    |> Task.await_many(30_000)
  end

  defp per_frame(work) do
    # A warm-up round out of the measurement: the first pass pays for code
    # loading and for the schedulers waking up.
    work.()
    {us, _} = :timer.tc(fn -> Enum.each(1..20, fn _ -> work.() end) end)
    us / 20
  end

  # A machine a few frames past power-on: the memory map has been written
  # to, which is what makes a step cost what it costs.
  defp warmed(rom) do
    machine = {Screen.boot_state(rom), Screen.boot_ram(rom), %APU{}}

    Enum.reduce(1..10, machine, fn _n, {state, ram, apu} ->
      {_pixels, state, ram} = Screen.frame(state, rom, ram, true)
      {state, ram, apu}
    end)
  end

  # ── The cartridge ───────────────────────────────────────────────────────────

  defp rom_file(dir) do
    path = Path.join(dir, "split.gb")
    File.write!(path, rom())
    path
  end

  # A cartridge that does nothing but ask what time the divider says it is.
  # Every turn of its loop it reads DIV, adds it to a running total in WRAM,
  # and spends the total three ways at once:
  #
  #   * onto the background palette, so it colours the picture;
  #   * into tile 0's first row, so it draws a pattern in the picture;
  #   * one bit of it onto the APU's master switch, so the frame is either
  #     audible or digitally silent.
  #
  # Which makes it the one cartridge that can answer every question this
  # file asks: a divider read a shade out of phase ends up in the pixels
  # and in the PCM, and two universes that have parted company say so on
  # the wire in both.
  defp rom(title \\ "ATOMBOY SPLIT") do
    boot = <<
      # LD A,$91 / LDH ($40),A — the LCD on, the background drawn
      0x3E,
      0x91,
      0xE0,
      0x40,
      # XOR A / LDH ($47),A — the palette starts black
      0xAF,
      0xE0,
      0x47,
      # LD A,$80 / LDH ($26),A — NR52: the APU powered up
      0x3E,
      0x80,
      0xE0,
      0x26,
      # LD A,$FF / LDH ($25),A — NR51: every voice, both sides
      0x3E,
      0xFF,
      0xE0,
      0x25,
      # LD A,$77 / LDH ($24),A — NR50: the master volume, full
      0x3E,
      0x77,
      0xE0,
      0x24,
      # LD A,$80 / LDH ($11),A — NR11: half duty, no length
      0x3E,
      0x80,
      0xE0,
      0x11,
      # LD A,$F0 / LDH ($12),A — NR12: volume 15, and no envelope to lose it
      0x3E,
      0xF0,
      0xE0,
      0x12,
      # XOR A / LDH ($13),A — NR13: the low half of the period
      0xAF,
      0xE0,
      0x13,
      # LD A,$87 / LDH ($14),A — NR14: the high half, and the trigger
      0x3E,
      0x87,
      0xE0,
      0x14
    >>

    loop = <<
      # LDH A,($04) / LD B,A — the divider, as the machine has it now
      0xF0,
      0x04,
      0x47,
      # LD A,($C000) / ADD A,B / LD ($C000),A — the running total
      0xFA,
      0x00,
      0xC0,
      0x80,
      0xEA,
      0x00,
      0xC0,
      # LDH ($47),A — onto the background palette
      0xE0,
      0x47,
      # LD ($8000),A — and into tile 0's first row, where it draws
      0xEA,
      0x00,
      0x80,
      # AND $01 / RRCA / LDH ($26),A — one bit of it onto the master switch
      0xE6,
      0x01,
      0x0F,
      0xE0,
      0x26,
      # JP — round again, forever
      0xC3,
      0x50 + byte_size(boot),
      0x01
    >>

    :binary.copy(<<0>>, 0x8000)
    |> put(0x100, <<0xC3, 0x50, 0x01>>)
    |> put(0x134, title |> String.pad_trailing(0x10, <<0>>) |> binary_part(0, 0x10))
    |> put(0x14D, <<0x5A>>)
    |> put(0x14E, <<0x91, 0xE2>>)
    |> put(0x150, boot <> loop)
  end

  defp put(binary, at, chunk) do
    tail = at + byte_size(chunk)

    binary_part(binary, 0, at) <> chunk <> binary_part(binary, tail, byte_size(binary) - tail)
  end
end
