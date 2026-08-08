defmodule Atomboy.MovieTest do
  use ExUnit.Case, async: true

  alias Atomboy.CPU.State
  alias Atomboy.Movie

  @moduletag :tmp_dir

  describe "the joypad byte" do
    test "the documented bit order: directions low, buttons high, pressed is one" do
      # Nothing held: both nibbles all ones on the lines, all zeros here.
      assert Movie.from_lines(0x0F, 0x0F) == 0x00

      assert Movie.from_lines(0x0E, 0x0F) == 0x01
      assert Movie.from_lines(0x0D, 0x0F) == 0x02
      assert Movie.from_lines(0x0B, 0x0F) == 0x04
      assert Movie.from_lines(0x07, 0x0F) == 0x08
      assert Movie.from_lines(0x0F, 0x0E) == 0x10
      assert Movie.from_lines(0x0F, 0x0D) == 0x20
      assert Movie.from_lines(0x0F, 0x0B) == 0x40
      assert Movie.from_lines(0x0F, 0x07) == 0x80

      # Right and A together — the running jump.
      assert Movie.from_lines(0x0E, 0x0E) == 0x11
    end

    test "the lines survive the crossing, both ways, for every byte" do
      for byte <- 0..255 do
        {dpad, btns} = Movie.to_lines(byte)
        assert Movie.from_lines(dpad, btns) == byte
      end
    end
  end

  describe "the track" do
    test "at/2 hands back the byte that was appended for that frame" do
      movie =
        Enum.reduce([0x00, 0x11, 0x80, 0xFF, 0x04], new_movie(), fn byte, movie ->
          Movie.append_frame(movie, byte)
        end)

      assert Movie.at(movie, 0) == 0x00
      assert Movie.at(movie, 1) == 0x11
      assert Movie.at(movie, 2) == 0x80
      assert Movie.at(movie, 3) == 0xFF
      assert Movie.at(movie, 4) == 0x04

      # The bare track answers the same — that is what the replay cursor holds.
      assert Movie.at(movie.track, 1) == 0x11
    end

    test "past the end and before the beginning there is nothing, not a crash" do
      movie = Movie.append_frame(new_movie(), 0x22)

      assert Movie.at(movie, 1) == nil
      assert Movie.at(movie, 999) == nil
      assert Movie.at(movie, -1) == nil
      assert Movie.at(<<>>, 0) == nil
    end

    test "appending counts the frames, in the header as much as in the track" do
      movie = record(new_movie(), [1, 2, 3])

      assert Movie.frames(movie) == 3
      assert movie.header.frames == 3
    end
  end

  describe "truncation" do
    test "leaves exactly N frames, and the frame count says so" do
      movie = record(new_movie(), [10, 11, 12, 13, 14])
      cut = Movie.truncate(movie, 2)

      assert Movie.frames(cut) == 2
      assert cut.header.frames == 2
      assert cut.track == <<10, 11>>
      assert Movie.at(cut, 1) == 11
      assert Movie.at(cut, 2) == nil
    end

    test "the take continues from the cut, and the new frames win" do
      movie = record(new_movie(), [10, 11, 12, 13, 14])
      redone = movie |> Movie.truncate(2) |> record([99, 98])

      assert Movie.frames(redone) == 4
      assert redone.track == <<10, 11, 99, 98>>
      assert Movie.at(redone, 2) == 99
      assert Movie.at(redone, 3) == 98
      assert Movie.at(redone, 4) == nil
    end

    test "a cut beyond the end changes nothing, a negative one empties it" do
      movie = record(new_movie(), [1, 2, 3])

      assert Movie.truncate(movie, 3).track == <<1, 2, 3>>
      assert Movie.truncate(movie, 99).track == <<1, 2, 3>>
      assert Movie.truncate(movie, 0).track == <<>>
      assert Movie.truncate(movie, -5).track == <<>>
      assert Movie.truncate(movie, -5).header.frames == 0
    end

    test "the counter is the caller's to bump — truncation never touches it" do
      movie = record(new_movie(), [1, 2, 3])

      assert Movie.truncate(movie, 1).header.rerecords == 0

      assert movie
             |> Movie.truncate(1)
             |> Movie.rerecorded()
             |> Map.fetch!(:header)
             |> Map.fetch!(:rerecords) == 1

      assert movie |> Movie.rerecorded() |> Movie.rerecorded() |> Movie.frames() == 3
    end
  end

  describe "the file" do
    test "a whole take goes out and comes back the same", %{tmp_dir: dir} do
      path = Path.join(dir, "run.tas")
      anchor = {:snapshot, %State{pc: 0x1234, a: 0x42}, %{0xC000 => 7}, %Atomboy.APU{seq_step: 3}}

      movie =
        rom()
        |> Movie.new(anchor,
          codes: [{0xD116, 0xFF}],
          author: "maartz",
          created_at: "2026-08-08T10:00:00Z"
        )
        |> record([0x00, 0x11, 0x11, 0x80, 0x00])

      assert Movie.write(movie, path) == :ok
      assert {:ok, reloaded} = Movie.read(path)

      assert reloaded == movie
      assert reloaded.header.anchor == :snapshot
      assert reloaded.header.frames == 5
      assert reloaded.header.rerecords == 0
      assert reloaded.header.codes == [{0xD116, 0xFF}]
      assert reloaded.header.author == "maartz"
      assert reloaded.header.created_at == "2026-08-08T10:00:00Z"
      assert Movie.at(reloaded, 3) == 0x80
    end

    test "a boot anchor carries the battery it started with", %{tmp_dir: dir} do
      path = Path.join(dir, "pure.tas")
      sram = :binary.copy(<<0x5A>>, 0x2000)

      movie = rom() |> Movie.new({:boot, sram}) |> record([1, 2, 3])

      assert :ok = Movie.write(movie, path)
      assert {:ok, %Movie{anchor: {:boot, ^sram}} = reloaded} = Movie.read(path)
      assert reloaded.header.anchor == :boot
    end

    test "a cartridge with no battery records its absence", %{tmp_dir: dir} do
      path = Path.join(dir, "batteryless.tas")

      assert :ok = rom() |> Movie.new({:boot, :none}) |> Movie.write(path)
      assert {:ok, %Movie{anchor: {:boot, :none}}} = Movie.read(path)
    end

    test "the created-at is stamped when the caller does not supply one" do
      movie = Movie.new(rom(), {:boot, :none})

      assert {:ok, _at, _offset} = DateTime.from_iso8601(movie.header.created_at)
    end

    test "an anchor frozen by an older release still starts", %{tmp_dir: dir} do
      # Yesterday's structs: one field the code has since gained, one it has
      # since dropped. The same rescue Save.read_state/1 performs.
      old_state =
        %State{pc: 0x1234}
        |> Map.from_struct()
        |> Map.delete(:sp)
        |> Map.put(:removed_long_ago, :whatever)
        |> Map.put(:__struct__, State)

      path = Path.join(dir, "vintage.tas")
      header = %{rom: %{id: "OLD-0000", header_checksum: 0}, frames: 0}
      anchor = {:snapshot, old_state, %{}, %Atomboy.APU{}}
      File.write!(path, :erlang.term_to_binary({:atomboy_movie, 1, header, anchor, <<7, 8>>}))

      assert {:ok, movie} = Movie.read(path)
      assert {:snapshot, %State{} = state, %{}, %Atomboy.APU{}} = movie.anchor
      assert state.pc == 0x1234
      assert state.sp == %State{}.sp
      refute Map.has_key?(state, :removed_long_ago)

      # A header from before a field existed reads with today's default.
      assert movie.header.author == ""
      assert movie.header.codes == []
      assert movie.header.rerecords == 0

      # And a frame count that disagrees with the track loses to the track.
      assert movie.header.frames == 2
    end

    test "a file that is not there is not corrupt, it is absent", %{tmp_dir: dir} do
      assert Movie.read(Path.join(dir, "nowhere.tas")) == {:error, :enoent}
    end

    test "everything that is not a movie comes back corrupt, never raising", %{tmp_dir: dir} do
      good = rom() |> Movie.new({:boot, :none}) |> record([1, 2, 3])
      path = Path.join(dir, "broken.tas")

      bad = [
        "not an erlang term at all",
        <<131, 0xFF, 0xFF, 0xFF>>,
        :erlang.term_to_binary({:atomboy_state, 1, %State{}, %{}, %Atomboy.APU{}}),
        :erlang.term_to_binary({:atomboy_movie, 2, good.header, good.anchor, good.track}),
        :erlang.term_to_binary({:atomboy_movie, 1, good.header, good.anchor}),
        :erlang.term_to_binary({:atomboy_movie, 1, :not_a_map, good.anchor, good.track}),
        :erlang.term_to_binary({:atomboy_movie, 1, good.header, good.anchor, [1, 2, 3]}),
        :erlang.term_to_binary({:atomboy_movie, 1, good.header, :boot, good.track}),
        :erlang.term_to_binary(
          {:atomboy_movie, 1, good.header, {:snapshot, 1, 2, 3}, good.track}
        ),
        :erlang.term_to_binary({:error, :enoent}),
        binary_part(written(good, path), 0, 12)
      ]

      for data <- bad do
        File.write!(path, data)
        assert Movie.read(path) == {:error, :corrupt}, "expected corrupt for #{inspect(data)}"
      end
    end
  end

  describe "the ROM it belongs to" do
    test "the identity is the library's own key, plus the header checksum" do
      id = Movie.rom_id(rom())

      assert id.id == Atomboy.Library.game_id(rom())
      assert id.header_checksum == 0x5A
    end

    test "the cartridge it was recorded on is accepted" do
      assert Movie.verify(Movie.new(rom(), {:boot, :none}), rom()) == :ok
    end

    test "a flipped checksum byte is another dump, and is refused" do
      movie = Movie.new(rom(), {:boot, :none})

      # The header checksum (0x14D) — one byte, and the whole run desyncs.
      assert Movie.verify(movie, rom(header_checksum: 0x5B)) == {:error, :wrong_rom}

      # The global checksum (0x14E-0x14F) — the library's own key changes too.
      assert Movie.verify(movie, rom(global_checksum: <<0x91, 0xE3>>)) == {:error, :wrong_rom}

      # And a different game entirely.
      assert Movie.verify(movie, rom(title: "SOMETHING ELSE")) == {:error, :wrong_rom}
    end

    test "a binary too short to hold a cartridge header is not the ROM either" do
      assert Movie.verify(Movie.new(rom(), {:boot, :none}), <<0, 1, 2>>) == {:error, :wrong_rom}
    end

    test "a movie read back still refuses the wrong cartridge", %{tmp_dir: dir} do
      path = Path.join(dir, "identity.tas")
      :ok = rom() |> Movie.new({:boot, :none}) |> record([1]) |> Movie.write(path)

      assert {:ok, movie} = Movie.read(path)
      assert Movie.verify(movie, rom()) == :ok
      assert Movie.verify(movie, rom(header_checksum: 0x00)) == {:error, :wrong_rom}
    end
  end

  test "the extension movies wear" do
    assert Movie.extension() == ".tas"
  end

  # ── The bench ───────────────────────────────────────────────────────────────

  defp new_movie, do: Movie.new(rom(), {:boot, :none})

  defp record(movie, bytes), do: Enum.reduce(bytes, movie, &Movie.append_frame(&2, &1))

  defp written(movie, path) do
    :ok = Movie.write(movie, path)
    File.read!(path)
  end

  # A cartridge that is nothing but its header: title, header checksum,
  # global checksum, and 32 KB of zeros around them.
  defp rom(opts \\ []) do
    title = Keyword.get(opts, :title, "ATOMBOY TAS")

    :binary.copy(<<0>>, 0x8000)
    |> put(0x134, String.pad_trailing(title, 0x10, <<0>>) |> binary_part(0, 0x10))
    |> put(0x14D, <<Keyword.get(opts, :header_checksum, 0x5A)>>)
    |> put(0x14E, Keyword.get(opts, :global_checksum, <<0x91, 0xE2>>))
  end

  defp put(binary, at, chunk) do
    tail = at + byte_size(chunk)

    binary_part(binary, 0, at) <>
      chunk <> binary_part(binary, tail, byte_size(binary) - tail)
  end
end
