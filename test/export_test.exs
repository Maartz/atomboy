defmodule Atomboy.ExportTest do
  use ExUnit.Case

  alias Atomboy.Export
  alias Atomboy.Library
  alias Atomboy.Movie
  alias Atomboy.Play
  alias Atomboy.Screen
  alias Mix.Tasks.Atomboy.Export, as: ExportTask

  @moduletag :tmp_dir

  # A scripted track: directions and buttons, overlapping and alone. A run of
  # zeros would replay identically no matter what the seam did with it.
  @track [
    0x00,
    0x00,
    0x01,
    0x01,
    0x11,
    0x11,
    0x10,
    0x00,
    0x02,
    0x22,
    0x20,
    0x00,
    0x84,
    0x44,
    0x40,
    0x08,
    0x88,
    0x80,
    0x05,
    0x55,
    0x50,
    0x00,
    0xFF,
    0x00
  ]

  # The APU's own arithmetic: 70,224 machine cycles a frame, 128 per sample,
  # the remainder carried — so the count is exact over any number of frames,
  # and a sample is four bytes (stereo, s16le).
  @frame_cycles 70_224
  @cycles_per_sample 128

  # The loop draws every frame it runs; these tests want the machine
  # underneath the pixels, so the drawing goes where drawing goes to die.
  setup do
    {:ok, null} = File.open("/dev/null", [:write, encoding: :unicode])
    Process.group_leader(self(), null)
    :ok
  end

  describe "the replay" do
    test "lands on the very frames the loop's own replay lands on", %{tmp_dir: dir} do
      movie = movie(dir)

      assert exported_frames(dir, movie) == loop_frames(dir, movie)
    end

    test "renders every frame of the track, and no other", %{tmp_dir: dir} do
      movie = movie(dir)
      frames = exported_frames(dir, movie)

      assert length(frames) == length(@track)

      # Every frame is a whole 160×144 in RGB24 — the export ships pixels,
      # never a frame it decided to skip and repeat.
      assert Enum.all?(sizes(dir, movie), &(&1 == 160 * 144 * 3))
    end

    test "the sound is the frame's own, not the wall clock's", %{tmp_dir: dir} do
      movie = movie(dir)

      pcm =
        Export.replay(movie, cartridge(dir), [], 0, fn {_rgb, pcm}, total ->
          total + byte_size(pcm)
        end)

      assert pcm == 4 * div(length(@track) * @frame_cycles, @cycles_per_sample)

      # 548.625 samples a frame: a count fixed by the machine's cycles, and
      # the same for a movie exported on a slow laptop or a fast one.
      assert pcm == 4 * 13_167
    end

    test "a boot anchor replays on the battery the take embedded", %{tmp_dir: dir} do
      # A cartridge that paints its saved game onto the screen: the battery
      # the anchor carries is visible in the very first frame, so a movie
      # exported with the wrong one — or with none — cannot look right.
      rom = battery_cartridge(dir)

      saved = battery_frames(rom, :binary.copy(<<0x5A>>, 0x2000))
      other = battery_frames(rom, :binary.copy(<<0xE4>>, 0x2000))
      bare = battery_frames(rom, :none)

      assert saved == battery_frames(rom, :binary.copy(<<0x5A>>, 0x2000))
      refute saved == other
      refute saved == bare
    end
  end

  describe "the arguments" do
    test "a movie without a cartridge is refused, and says what it needs", %{tmp_dir: dir} do
      tas = written(dir, movie(dir))

      assert_raise Mix.Error, ~r/--rom is required/, fn ->
        ExportTask.run([tas, "--out", Path.join(dir, "run.mp4")])
      end
    end

    test "an export without a destination is refused", %{tmp_dir: dir} do
      tas = written(dir, movie(dir))

      assert_raise Mix.Error, ~r/--out is required/, fn ->
        ExportTask.run([tas, "--rom", rom_path(dir)])
      end
    end

    test "a format nobody asked for is refused by name", %{tmp_dir: dir} do
      tas = written(dir, movie(dir))

      assert_raise Mix.Error, ~r/\.webm is neither \.mp4 nor \.gif/, fn ->
        ExportTask.run([tas, "--rom", rom_path(dir), "--out", Path.join(dir, "run.webm")])
      end
    end

    test "a movie recorded on another cartridge never runs a frame", %{tmp_dir: dir} do
      tas = written(dir, movie(dir))

      stranger = Path.join(dir, "stranger.gb")
      File.write!(stranger, rom("SOMETHING ELSE"))

      assert_raise Mix.Error, ~r/recorded on another cartridge/, fn ->
        ExportTask.run([tas, "--rom", stranger, "--out", Path.join(dir, "run.mp4")])
      end
    end

    test "no movie at that path", %{tmp_dir: dir} do
      assert_raise Mix.Error, ~r/no movie at/, fn ->
        ExportTask.run([
          Path.join(dir, "ghost.tas"),
          "--rom",
          rom_path(dir),
          "--out",
          Path.join(dir, "run.mp4")
        ])
      end
    end

    test "without ffmpeg, the tool is named and nothing is replayed", %{tmp_dir: dir} do
      tas = written(dir, movie(dir))
      path = System.get_env("PATH")
      on_exit(fn -> System.put_env("PATH", path || "") end)
      System.put_env("PATH", Path.join(dir, "nothing-here"))

      assert_raise Mix.Error, ~r/ffmpeg is not on the PATH/, fn ->
        ExportTask.run([tas, "--rom", rom_path(dir), "--out", Path.join(dir, "run.mp4")])
      end
    end
  end

  # The encode itself, when the machine has the tool for it — the arguments
  # are only right if ffmpeg agrees, and it is the only witness that can say
  # so. Skipped where ffmpeg is missing, the way the suite skips qemu.
  if System.find_executable("ffmpeg") && System.find_executable("ffprobe") do
    describe "the encode" do
      @describetag :ffmpeg

      test "an mp4 comes out, video and sound in one file", %{tmp_dir: dir} do
        tas = written(dir, movie(dir))
        out = Path.join(dir, "run.mp4")

        ExportTask.run([tas, "--rom", rom_path(dir), "--out", out])

        assert File.regular?(out)
        # 160×144 doubled: the default scale for a video meant to be watched.
        assert probe(out, "v", "codec_name,width,height") == "h264,320,288"
        # AAC's rate grid has no 32,768, so ffmpeg resamples the console's
        # rate onto the nearest one it knows — same sound, same pitch.
        assert probe(out, "a", "codec_name,sample_rate,channels") == "aac,32000,2"
      end

      test "a gif comes out silent, at the scale it was asked for", %{tmp_dir: dir} do
        tas = written(dir, movie(dir))
        out = Path.join(dir, "run.gif")

        ExportTask.run([tas, "--rom", rom_path(dir), "--out", out, "--scale", "3"])

        assert File.regular?(out)
        assert <<"GIF89a", width::16-little, height::16-little, _rest::binary>> = File.read!(out)
        assert {width, height} == {480, 432}
      end
    end
  end

  # ── The bench ───────────────────────────────────────────────────────────────

  # What ffprobe says of one stream of the file — the only witness that can
  # confirm ffmpeg understood the arguments it was given.
  defp probe(path, stream, entries) do
    {out, 0} =
      System.cmd(
        "ffprobe",
        ~w(-v error -select_streams #{stream} -show_entries stream=#{entries} -of csv=p=0) ++
          [path]
      )

    String.trim(out)
  end

  # The export's replay, one CRC per frame — the strongest witness a picture
  # can give, and the same one the loop is asked for below.
  defp exported_frames(dir, movie) do
    movie
    |> Export.replay(cartridge(dir), [], [], fn {rgb, _pcm}, acc -> [:erlang.crc32(rgb) | acc] end)
    |> Enum.reverse()
  end

  defp sizes(dir, movie) do
    movie
    |> Export.replay(cartridge(dir), [], [], fn {rgb, _pcm}, acc -> [byte_size(rgb) | acc] end)
    |> Enum.reverse()
  end

  # The same movie through the loop proper: `Play.context/4`, the loop's own
  # `start_replay/2`, and `drive/1` a frame at a time. If the export's
  # stepping ever parts company with the console's, it parts here.
  defp loop_frames(dir, movie) do
    ctx = Play.start_replay(console(dir), movie)

    {frames, _ctx} =
      Enum.map_reduce(0..(Movie.frames(movie) - 1)//1, ctx, fn _n, ctx ->
        ctx = Play.drive(%{ctx | max_frames: ctx.frame + 1})
        {:erlang.crc32(Screen.to_rgb(ctx.last_frame, ctx.palette, ctx.lcd)), ctx}
      end)

    frames
  end

  # A short take on the battery cartridge, as pixels.
  defp battery_frames(rom, sram) do
    movie = track(Movie.new(rom, {:boot, sram}), [0x00, 0x00, 0x00, 0x00])

    Export.replay(movie, rom, [], [], fn {rgb, _pcm}, acc -> [:erlang.crc32(rgb) | acc] end)
  end

  defp movie(dir),
    do: track(Movie.new(cartridge(dir), {:boot, :none}, author: "the test"), @track)

  defp track(movie, bytes), do: Enum.reduce(bytes, movie, &Movie.append_frame(&2, &1))

  defp written(dir, movie) do
    path = Path.join(dir, "run.tas")
    :ok = Movie.write(movie, path)
    path
  end

  defp rom_path(dir) do
    path = Path.join(dir, "pad.gb")
    unless File.regular?(path), do: File.write!(path, rom())
    path
  end

  defp cartridge(dir), do: Screen.load(rom_path(dir))

  defp battery_cartridge(dir) do
    path = Path.join(dir, "battery.gb")
    File.write!(path, battery_rom())
    Screen.load(path)
  end

  # A console at its first frame, its library in the temp dir and its
  # deadline long past: every frame is already late, so the loop never
  # sleeps and the suite keeps its speed.
  defp console(dir) do
    path = rom_path(dir)
    lib = Library.open(cartridge(dir), path, library: Path.join(dir, "library"))
    ctx = Play.context(cartridge(dir), lib, frames: 0)

    %{ctx | deadline: System.monotonic_time(:microsecond) - 1_000_000}
  end

  # A cartridge that does nothing but read the pad and show it: both halves
  # of the joypad matrix, summed into WRAM, and the running total written to
  # the background palette — so every button ever held ends up in the
  # pixels. It never halts, so the frame boundary falls mid-loop and
  # cycle-exactness is part of the test.
  defp rom(title \\ "ATOMBOY PAD") do
    code = <<
      # LD A,$91 / LDH ($40),A — the LCD on, the background drawn
      0x3E,
      0x91,
      0xE0,
      0x40,
      # XOR A / LDH ($47),A — the palette starts black
      0xAF,
      0xE0,
      0x47,
      # LD A,$20 / LDH ($00),A / LDH A,($00) / AND $0F / LD B,A — the d-pad
      0x3E,
      0x20,
      0xE0,
      0x00,
      0xF0,
      0x00,
      0xE6,
      0x0F,
      0x47,
      # LD A,$10 / … / SWAP A / OR B — the buttons, in the high nibble
      0x3E,
      0x10,
      0xE0,
      0x00,
      0xF0,
      0x00,
      0xE6,
      0x0F,
      0xCB,
      0x37,
      0xB0,
      # LD C,A / LD A,($C000) / ADD A,C / LD ($C000),A — the running total
      0x4F,
      0xFA,
      0x00,
      0xC0,
      0x81,
      0xEA,
      0x00,
      0xC0,
      # LDH ($47),A / JP $0157 — onto the palette, and round again
      0xE0,
      0x47,
      0xC3,
      0x57,
      0x01
    >>

    :binary.copy(<<0>>, 0x8000)
    |> put(0x100, <<0xC3, 0x50, 0x01>>)
    |> put(0x134, title |> String.pad_trailing(0x10, <<0>>) |> binary_part(0, 0x10))
    |> put(0x147, <<0x03>>)
    |> put(0x14D, <<0x5A>>)
    |> put(0x14E, <<0x91, 0xE2>>)
    |> put(0x150, code)
  end

  # A cartridge whose saved game is its picture: SRAM enabled, the byte at
  # 0xA000 laid onto the background palette, forever. Every shade on screen
  # comes from the battery — which is exactly what a boot anchor promises to
  # reproduce.
  defp battery_rom do
    code = <<
      # LD A,$91 / LDH ($40),A — the LCD on
      0x3E,
      0x91,
      0xE0,
      0x40,
      # LD A,$0A / LD ($0000),A — the cartridge RAM answers now
      0x3E,
      0x0A,
      0xEA,
      0x00,
      0x00,
      # LD A,($A000) / LDH ($47),A / JP $0159 — the saved byte, on the palette
      0xFA,
      0x00,
      0xA0,
      0xE0,
      0x47,
      0xC3,
      0x59,
      0x01
    >>

    :binary.copy(<<0>>, 0x8000)
    |> put(0x100, <<0xC3, 0x50, 0x01>>)
    |> put(0x134, "ATOMBOY SAVE" |> String.pad_trailing(0x10, <<0>>) |> binary_part(0, 0x10))
    |> put(0x147, <<0x03>>)
    |> put(0x14D, <<0x5A>>)
    |> put(0x14E, <<0x91, 0xE3>>)
    |> put(0x150, code)
  end

  defp put(binary, at, chunk) do
    tail = at + byte_size(chunk)

    binary_part(binary, 0, at) <> chunk <> binary_part(binary, tail, byte_size(binary) - tail)
  end
end
