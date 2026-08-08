defmodule Mix.Tasks.Atomboy.Export do
  @shortdoc "Renders a .tas movie into an MP4 or a GIF"

  @moduledoc """
  The reel leaves the machine: a movie replayed headlessly, straight into
  ffmpeg.

      mix atomboy.export run.tas --rom zelda.gb --out run.mp4
      mix atomboy.export run.tas --rom zelda.gb --out run.gif --scale 3

  A movie is an anchor and one joypad byte per frame, and the emulation core
  touches no wall clock and no randomness: replaying it produces the very
  frames the player saw, however long the encode takes. Nothing here is
  captured in real time — the machine runs as fast as the BEAM can, and the
  video that comes out is frame-perfect by construction rather than by luck.

  Fast-forward's habits are all dropped for the occasion: every frame is
  rendered and every frame's sound is generated. Turbo draws one frame in
  four because drawing is what it costs, which is exactly the wrong trade
  when the frames *are* the product.

  ## What it needs

  A movie carries its cartridge's title and checksums, never the cartridge
  itself, so `--rom` is not optional — and a movie handed the wrong dump is
  refused before a single frame runs rather than desynchronising thirty
  seconds in.

  `ffmpeg` must be on the PATH (`brew install ffmpeg`), the same tool
  `ffplay` ships with.

  ## Options

    * `--rom game.gb` — the cartridge the movie was recorded on. Required.
    * `--out run.mp4` — the file to write; the extension picks the format,
      `.mp4` (H.264 video, AAC sound) or `.gif` (silent, as GIFs are).
      Required.
    * `--scale N` — an integer nearest-neighbour upscale. The Game Boy's
      panel is 160×144, which is a postage stamp on a modern screen: MP4
      defaults to 2, GIF to 1 (where every pixel is paid for twice over).

  ## Two streams, two temp files

  ffmpeg is handed a raw video file and a raw PCM file rather than two
  pipes. Two pipes into one process is a deadlock waiting for a slow frame:
  ffmpeg reads the inputs in the order its timestamps demand, and a BEAM
  writing both must guess that order — fill the wrong pipe's buffer and the
  writer blocks while ffmpeg waits on the other. Files have no such opinion,
  and they let the replay finish before the encode begins, so a failing
  encode never costs the replay.

  The bill is disk: raw RGB24 at 160×144 is 69,120 bytes a frame — about
  250 MB a minute — written under `System.tmp_dir!/0` and removed on the way
  out, whether the encode worked or not.

  ## Two clocks that agree

  The APU produces 548.625 samples a frame — 32,768 Hz against the panel's
  59.7275 — so the two streams are cut from the same crystal and need no
  resampling to stay in step. AAC's own rate grid has no 32,768 in it, so
  the encoder lands the sound on the nearest rate it knows; the pitch and
  the sync are untouched, and the GIF path never hears any of this.

  ## The GIF's clock

  GIF frame delays are counted in hundredths of a second, and a Game Boy
  frame lasts 1.674 of them. The delay is rounded, so a GIF runs a few
  percent off the console's pace where the MP4 is exact — GIFs are for short
  clips, and short clips is what the rounding suits.
  """

  use Mix.Task

  alias Atomboy.APU
  alias Atomboy.Codes
  alias Atomboy.Joypad
  alias Atomboy.Library
  alias Atomboy.Movie
  alias Atomboy.Play
  alias Atomboy.Screen

  # The panel's own cadence — 4,194,304 ÷ 70,224 — and the rate the APU
  # produces at. 32,768 ÷ 59.7275 is 548.625 samples a frame: the two
  # streams are cut from the same clock and need no resampling to agree.
  @fps "59.7275"
  @rate 32_768
  @width 160
  @height 144

  @switches [rom: :string, out: :string, scale: :integer]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    case plan(args) do
      {:ok, plan} -> export(plan)
      {:error, message} -> Mix.raise(message)
    end
  end

  # ── The replay ──────────────────────────────────────────────────────────────

  @doc false
  # Every frame of `movie` against `rom`, handed one at a time to `fun` as
  # `{rgb, pcm}` — 69,120 bytes of RGB24 and the frame's stereo s16le — and
  # folded onto `acc`. The mix task writes both into files; the tests count
  # them and take their CRC.
  #
  # The machine is the play loop's own (`Play.context/4`), and the anchor is
  # installed by the loop's own `Play.start_replay/2`, so a movie starts here
  # exactly where it starts in the console. The frame itself is stepped here
  # rather than through `Play.drive/1` for three reasons the interactive loop
  # is right to have and an export is right to refuse: the loop's sound is
  # slaved to the wall clock (an export's must be slaved to the frame), the
  # loop discards the APU triggers when no player is listening (an export
  # needs every one of them), and the loop flushes the cartridge battery as
  # it goes (an export must leave the player's save exactly as it found it).
  # The ordering below is `Play.step/1`'s, seam for seam, and the tests pin
  # it against a replay driven through the loop proper.
  @spec replay(Movie.t(), binary(), keyword(), acc, ({binary(), binary()}, acc -> acc)) :: acc
        when acc: term()
  def replay(%Movie{} = movie, rom, opts, acc, fun) do
    ctx = machine(movie, rom, opts)
    last = Movie.frames(movie) - 1

    {_ctx, acc} =
      Enum.reduce(0..last//1, {ctx, acc}, fn frame, {ctx, acc} ->
        {dpad, btns} = Movie.to_lines(Movie.at(movie.track, frame))

        ram =
          ctx.ram
          |> Joypad.set(dpad, btns)
          |> Codes.applique()

        {pixels, state, ram} = Screen.frame(ctx.state, ctx.rom, ram, true)
        {pcm, ram, apu} = APU.frame(ram, ctx.apu)
        rgb = Screen.to_rgb(pixels, ctx.palette, ctx.lcd)

        {%{ctx | state: state, ram: ram, apu: apu}, fun.({rgb, pcm}, acc)}
      end)

    acc
  end

  # The machine one instant before the movie's first frame. A boot anchor
  # wants the battery the recording began with and nothing else, so the
  # embedded SRAM is written into a throwaway library and loaded the way the
  # engine loads any `.sav` — one code path for batteries, and the player's
  # own library never opened, let alone written.
  defp machine(movie, rom, opts) do
    scratch = scratch_dir("machine")

    try do
      lib = Library.open(rom, Path.join(scratch, "movie.gb"), library: scratch)
      install_battery(movie.anchor, Library.sav_path(lib))

      ctx =
        rom
        |> Play.context(lib, Keyword.merge([frames: 0], opts))
        |> Play.start_replay(movie)

      # The codes poked the machine every frame of the take, so they are
      # part of what is being replayed — the header is the record of that,
      # and it wins over whatever a snapshot anchor happens to carry.
      %{ctx | ram: Codes.installe(ctx.ram, movie.header.codes)}
    after
      File.rm_rf(scratch)
    end
  end

  defp install_battery({:boot, sram}, sav) when is_binary(sram), do: File.write!(sav, sram)
  defp install_battery({:boot, :none}, sav), do: File.rm_rf!(sav)
  defp install_battery({:snapshot, _state, _ram, _apu}, _sav), do: :ok

  # ── The export ──────────────────────────────────────────────────────────────

  defp export(plan) do
    scratch = scratch_dir("streams")
    video = Path.join(scratch, "frames.rgb")
    audio = Path.join(scratch, "sound.pcm")

    try do
      {frames, bytes} = record(plan, video, audio)
      encode(plan, video, audio, scratch)

      Mix.shell().info(
        "#{plan.out} — #{frames} frames, #{div(bytes, 4)} samples, " <>
          "#{Float.round(frames / 59.7275, 1)} s"
      )
    after
      File.rm_rf(scratch)
    end
  end

  # The whole take onto disk, one frame at a time: the video and the sound
  # never live in memory together, which is what lets a ten-minute movie
  # export on a laptop.
  defp record(plan, video_path, audio_path) do
    video = File.open!(video_path, [:write, :binary, :raw, :delayed_write])
    audio = File.open!(audio_path, [:write, :binary, :raw, :delayed_write])
    total = Movie.frames(plan.movie)

    try do
      {frames, bytes} =
        replay(plan.movie, plan.rom, [], {0, 0}, fn {rgb, pcm}, {frames, bytes} ->
          :ok = :file.write(video, rgb)
          :ok = :file.write(audio, pcm)
          progress(frames + 1, total)

          {frames + 1, bytes + byte_size(pcm)}
        end)

      IO.write(:stderr, "\r\e[K")
      {frames, bytes}
    after
      File.close(video)
      File.close(audio)
    end
  end

  # The replay's own progress, on stderr — a movie is minutes of machine and
  # a silent terminal reads as a hang. Every thirtieth frame: half a second
  # of play, and no line drawn faster than an eye can read it.
  defp progress(frame, total) when rem(frame, 30) == 0 or frame == total,
    do: IO.write(:stderr, "\r  replaying #{frame}/#{total} frames")

  defp progress(_frame, _total), do: :ok

  # ── ffmpeg ──────────────────────────────────────────────────────────────────

  defp encode(%{format: :mp4} = plan, video, audio, _scratch) do
    ffmpeg(plan, video_input(video) ++ audio_input(audio) ++ mp4_args(plan))
  end

  # The GIF in two passes: one to learn the 256 colours the clip actually
  # uses, one to draw it with them. A single pass would quantise blind and
  # band every gradient the panel has.
  defp encode(%{format: :gif} = plan, video, _audio, scratch) do
    palette = Path.join(scratch, "palette.png")

    ffmpeg(
      plan,
      video_input(video) ++
        ["-vf", "#{scale_filter(plan)},palettegen=stats_mode=diff", palette]
    )

    ffmpeg(
      plan,
      video_input(video) ++
        ["-i", palette] ++
        [
          "-lavfi",
          "[0:v]#{scale_filter(plan)}[v];[v][1:v]paletteuse=dither=bayer:bayer_scale=3",
          "-loop",
          "0",
          plan.out
        ]
    )
  end

  defp video_input(path) do
    ~w(-f rawvideo -pixel_format rgb24 -video_size #{@width}x#{@height} -framerate #{@fps} -i) ++
      [path]
  end

  defp audio_input(path), do: ~w(-f s16le -ar #{@rate} -ac 2 -i) ++ [path]

  defp mp4_args(plan) do
    ~w(-vf #{scale_filter(plan)} -c:v libx264 -preset medium -crf 18 -pix_fmt yuv420p) ++
      ~w(-c:a aac -b:a 192k -shortest) ++ [plan.out]
  end

  # Nearest neighbour, always: a Game Boy pixel is a square of one colour,
  # and any interpolation between two of them is a colour the console never
  # displayed. At 1 the filter is the identity and costs a copy.
  defp scale_filter(%{scale: n}), do: "scale=iw*#{n}:ih*#{n}:flags=neighbor"

  defp ffmpeg(plan, args) do
    args = ~w(-hide_banner -loglevel error -y) ++ args

    case System.cmd(plan.ffmpeg, args, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> Mix.raise("ffmpeg failed (status #{status}):\n#{String.trim(output)}")
    end
  end

  # ── The arguments ───────────────────────────────────────────────────────────

  # Everything that can be refused, refused before a frame is run: an export
  # is minutes of work, and none of it should be discovered wasted.
  defp plan(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: @switches)

    with :ok <- no_invalid(invalid),
         {:ok, tas} <- positional(rest),
         {:ok, rom_path} <- rom_path(opts),
         {:ok, out} <- out_path(opts),
         {:ok, format} <- format(out),
         {:ok, scale} <- scale(opts, format),
         {:ok, rom} <- cartridge(rom_path),
         {:ok, movie} <- movie(tas),
         :ok <- Movie.verify(movie, rom) |> mismatch(tas, rom_path),
         {:ok, ffmpeg} <- ffmpeg_path() do
      {:ok, %{movie: movie, rom: rom, out: out, format: format, scale: scale, ffmpeg: ffmpeg}}
    end
  end

  defp no_invalid([]), do: :ok

  defp no_invalid(invalid) do
    {:error,
     "unknown option#{if length(invalid) > 1, do: "s"}: " <>
       Enum.map_join(invalid, ", ", &elem(&1, 0)) <> "\n\n" <> usage()}
  end

  defp positional([tas]), do: {:ok, tas}

  defp positional([]),
    do: {:error, "which movie? a .tas file is the first argument.\n\n" <> usage()}

  defp positional(many),
    do: {:error, "one movie at a time — got #{length(many)}.\n\n" <> usage()}

  defp rom_path(opts) do
    case Keyword.fetch(opts, :rom) do
      {:ok, path} ->
        {:ok, path}

      :error ->
        {:error,
         "--rom is required: a movie carries its cartridge's title and\n" <>
           "checksums, never the cartridge itself — the ROM it was recorded\n" <>
           "on has to be named.\n\n" <> usage()}
    end
  end

  defp out_path(opts) do
    case Keyword.fetch(opts, :out) do
      {:ok, path} -> {:ok, path}
      :error -> {:error, "--out is required: the file to write.\n\n" <> usage()}
    end
  end

  defp format(out) do
    case out |> Path.extname() |> String.downcase() do
      ".mp4" -> {:ok, :mp4}
      ".gif" -> {:ok, :gif}
      "" -> {:error, "#{out} has no extension: .mp4 or .gif says what to write."}
      other -> {:error, "#{other} is neither .mp4 nor .gif — those are the two formats."}
    end
  end

  defp scale(opts, format) do
    case Keyword.get(opts, :scale, if(format == :mp4, do: 2, else: 1)) do
      n when is_integer(n) and n >= 1 -> {:ok, n}
      n -> {:error, "--scale #{n}: a whole number of pixels per pixel, 1 or more."}
    end
  end

  defp cartridge(path) do
    if File.regular?(path),
      do: {:ok, Screen.load(path)},
      else: {:error, "no cartridge at #{path}"}
  end

  defp movie(path) do
    case Movie.read(path) do
      {:ok, movie} ->
        if Movie.frames(movie) > 0,
          do: {:ok, movie},
          else: {:error, "#{path} holds no frames — there is nothing to export."}

      {:error, :corrupt} ->
        {:error, "#{path} is not an atomboy movie (or comes from a newer release)."}

      {:error, :enoent} ->
        {:error, "no movie at #{path}"}

      {:error, reason} ->
        {:error, "#{path} could not be read: #{:file.format_error(reason)}"}
    end
  end

  defp mismatch(:ok, _tas, _rom_path), do: :ok

  defp mismatch({:error, :wrong_rom}, tas, rom_path) do
    {:error,
     "#{tas} was recorded on another cartridge than #{rom_path}.\n" <>
       "A movie replayed against the wrong dump desynchronises within\n" <>
       "seconds, so it is refused here instead."}
  end

  defp ffmpeg_path do
    case System.find_executable("ffmpeg") do
      nil ->
        {:error,
         "ffmpeg is not on the PATH, and the encoding is its work.\n" <>
           "    brew install ffmpeg"}

      path ->
        {:ok, path}
    end
  end

  defp usage, do: "    mix atomboy.export run.tas --rom game.gb --out run.mp4"

  # A directory of our own under the system's, named so that two exports at
  # once cannot meet.
  defp scratch_dir(kind) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "atomboy-export-#{kind}-#{System.system_time(:second)}-#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    dir
  end
end
