defmodule Mix.Tasks.Atomboy.Export do
  @shortdoc "Renders a .tas movie into an MP4 or a GIF"

  @moduledoc """
  The reel leaves the machine, from a terminal that has a checkout.

      mix atomboy.export run.tas --rom zelda.gb --out run.mp4
      mix atomboy.export run.tas --rom zelda.gb --out run.gif --scale 3

  This task is a door, not the room: the replay and the encode both live in
  `Atomboy.Export`, which the shipped executable reaches through
  `atomboy game.gb --replay run.tas --export run.mp4` and the app reaches
  through File → Export Movie…. Read that module for how a movie becomes a
  video; what follows is only what the command line adds.

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
  """

  use Mix.Task

  alias Atomboy.Export

  @switches [rom: :string, out: :string, scale: :integer]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    with {:ok, plan} <- plan(args),
         {:ok, note} <- Export.run(plan) do
      Mix.shell().info(note)
    else
      {:error, message} -> Mix.raise(message)
    end
  end

  # ── The arguments ───────────────────────────────────────────────────────────

  # What argv says, turned into the four things `Atomboy.Export.plan/1`
  # asks for. Everything the task can refuse on its own — an option nobody
  # offers, a missing file name — it refuses here with the usage line, since
  # the usage line is the one thing the library has no business knowing.
  defp plan(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: @switches)

    with :ok <- no_invalid(invalid),
         {:ok, tas} <- positional(rest),
         {:ok, rom} <- rom_path(opts),
         {:ok, out} <- out_path(opts) do
      Export.plan(tas: tas, rom: rom, out: out, scale: Keyword.get(opts, :scale))
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

  defp usage, do: "    mix atomboy.export run.tas --rom game.gb --out run.mp4"
end
