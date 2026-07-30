defmodule Mix.Tasks.Atomboy.Corpus do
  @shortdoc "Fetches the SingleStepTests/sm83 vector corpus"

  @moduledoc """
  Fetches the SingleStepTests corpus for the SM83.

      mix atomboy.corpus

  502 files, about 160 MB uncompressed, one per opcode, ~1,000 vectors each.
  Shallow clone — the history is of no use here.

  ## Why this corpus before blargg

  blargg's test ROMs are integration tests: they answer "`cpu_instrs` fails",
  not "`SBC A, (HL)` sets the half-carry the wrong way round when carry comes
  in at 1". On a decoder still being written, that difference costs days.

  SingleStepTests gives, for every opcode, a thousand complete machine states
  before and after — registers, flags, memory touched, bus accesses. A failure
  names the opcode and the bit. blargg stays indispensable, but **afterwards**:
  it covers what unit vectors never see (sequences, timers, interrupts).

  The corpus lands in `test/fixtures/sm83/`, ignored by git: it is a test
  dependency, not project code.
  """

  use Mix.Task

  @repo "https://github.com/SingleStepTests/sm83.git"
  @dir "test/fixtures/sm83"

  @roms_repo "https://github.com/retrio/gb-test-roms.git"
  @roms_dir "test/fixtures/gb-test-roms"

  @doc "Where blargg's test ROMs live."
  @spec roms_dir() :: Path.t()
  def roms_dir, do: @roms_dir

  @doc "The individual cpu_instrs ROMs present on disk."
  @spec cpu_instrs_roms() :: [Path.t()]
  def cpu_instrs_roms do
    @roms_dir
    |> Path.join("cpu_instrs/individual/*.gb")
    |> Path.wildcard()
    |> Enum.sort()
  end

  @doc """
  Where the corpus lives.

  Resolved here rather than in the test harness: this is build tooling, and it
  keeps `Atomboy.SingleStep` out of the compiled application — hence out of the
  packbeam flashed onto the ESP32.
  """
  @spec dir() :: Path.t()
  def dir, do: @dir

  @doc """
  The byte that prefixes the extended table. Legitimately implemented,
  legitimately without a vector file.
  """
  @spec prefix_opcode() :: 0xCB
  def prefix_opcode, do: 0xCB

  @doc "Is the corpus present?"
  @spec available?() :: boolean()
  def available?, do: File.dir?(Path.join(@dir, "v1"))

  @doc """
  The opcodes covered by the corpus, as `{prefix, opcode}`.

  244 of the 256 encodings in the base table have a file. The twelve missing
  ones fall into two categories that must not be confused:

    * `0xCB` — this is the **prefix** of the extended table, not an
      instruction. It will indeed be implemented, as a second fetch. See
      `prefix_opcode/0`.
    * The eleven invalid encodings `0xD3`, `0xDB`, `0xDD`, `0xE3`, `0xE4`,
      `0xEB`, `0xEC`, `0xED`, `0xF4`, `0xFC`, `0xFD` — they do not exist on the
      SM83 and lock the CPU up. A clause covering them comes from a Z80 table.

  The list is read from disk rather than hard-coded: verifiable data rather
  than a hand transcription.
  """
  @spec opcodes() :: MapSet.t({nil | :cb, 0..0xFF})
  def opcodes do
    @dir
    |> Path.join("v1/*.json")
    |> Path.wildcard()
    |> MapSet.new(fn path ->
      case Path.basename(path, ".json") do
        "cb " <> hex -> {:cb, String.to_integer(hex, 16)}
        hex -> {nil, String.to_integer(hex, 16)}
      end
    end)
  end

  @impl true
  def run(_args) do
    fetch(dir(), @repo, "SingleStepTests vectors (~160 MB)", "v1")
    fetch(@roms_dir, @roms_repo, "blargg & mooneye test ROMs", "cpu_instrs")

    fetch_file(
      "test/fixtures/dmg-acid2.gb",
      "https://github.com/mattcurrie/dmg-acid2/releases/download/v1.0/dmg-acid2.gb",
      "dmg-acid2, the PPU acceptance test"
    )

    Mix.shell().info("Corpus ready. `mix test`; blargg: `mix test --include blargg`.")
  end

  defp fetch_file(path, url, label) do
    if File.regular?(path) do
      Mix.shell().info("#{label}: already there.")
    else
      Mix.shell().info("Downloading #{label}...")

      case System.cmd("curl", ["-sSL", "--max-time", "60", "-o", path, url]) do
        {_, 0} -> :ok
        {_, code} -> Mix.raise("curl failed (code #{code})")
      end
    end
  end

  defp fetch(dir, repo, label, proof) do
    if File.dir?(Path.join(dir, proof)) do
      Mix.shell().info("#{label}: already there in #{dir}.")
    else
      File.mkdir_p!(Path.dirname(dir))
      Mix.shell().info("Cloning #{repo} into #{dir} — #{label}...")

      case System.cmd("git", ["clone", "--depth", "1", repo, dir], into: IO.stream()) do
        {_, 0} -> :ok
        {_, code} -> Mix.raise("git clone failed (code #{code})")
      end
    end
  end
end
