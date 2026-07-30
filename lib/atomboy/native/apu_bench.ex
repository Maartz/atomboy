defmodule Atomboy.Native.APUBench do
  @moduledoc """
  `Atomboy.Native.APU` against `Atomboy.APU`, sample for sample.

  One image, every case: each carries the 48 bytes of sound registers, the 144
  bytes of channel state to start from, and how many samples to ask for. The
  guest installs them, calls `:apu_samples`, and sends back what it produced
  followed by the state it stopped on. Elixir runs `Atomboy.APU.samples/3` over
  the same inputs and compares.

  ## Why the comparison is here and not in the guest

  `Atomboy.Native.PPUBench` compares inside the guest and reports only what
  disagreed, because 144 scanlines of 160 bytes across dozens of cases is far
  too much to push through an emulated UART a byte at a time. A frame of sound
  is 2,196 bytes. Thirty cases is 70 KB, which that UART carries in a couple of
  seconds, and comparing in Elixir means a divergence arrives as two binaries to
  diff rather than as an offset to decode. The cheaper harness is the right one
  here; it would not have been there.

  ## The state, in both directions

  A channel's booleans are 0 or -1 in the generated code, so that the inner loop
  spends an `and` where Elixir spends an `if`. `encode_state/1` and
  `decode_state/1` are the only places that know it, and they are inverses --
  which is itself worth testing, since a bench whose encoder is wrong reports
  divergences that are its own.

  `env_timer` is read back **signed**. A channel triggered with an envelope
  period of zero walks its timer negative, `Atomboy.APU` walks negative with it,
  and a bench that read the word unsigned would call two agreeing emulators
  different at the first wrap.
  """

  import Bitwise

  alias Atomboy.APU
  alias Atomboy.Native.APU, as: Native
  alias Atomboy.Native.Asm
  alias Atomboy.Native.Image
  alias Atomboy.Native.Qemu
  alias Atomboy.Native.Regs
  alias Atomboy.Native.RV32

  @memory 0x10000
  @regs_from 0xFF10
  @regs_to 0xFF3F
  @regs_bytes @regs_to - @regs_from + 1
  @state_bytes Native.state_bytes()
  @case_bytes @regs_bytes + @state_bytes + 4

  @magic 0xA5

  @typedoc """
  One case: the sound registers as they stand, the state to start from, how many
  samples to ask for, and which channels were triggered during the frame.
  """
  @type bench_case :: %{
          registers: binary(),
          state: APU.t(),
          count: non_neg_integer(),
          triggers: [1..4]
        }

  @doc "The bytes of the register window a case carries -- 0xFF10 to 0xFF3F."
  @spec register_bytes() :: 48
  def register_bytes, do: @regs_bytes

  @doc """
  Runs every case in one guest and returns what disagreed.

  `:samples` is the first byte offset at which the two streams differ, `:state`
  the fields whose final values differ. A case appears in `divergences` only if
  one of the two is non-empty.
  """
  @spec run([bench_case()], keyword()) :: {:ok, map()} | {:error, term()}
  def run(cases, opts \\ []) when cases != [] do
    image = image(cases)

    case Qemu.run(image.code, opts) do
      %{status: :timeout, duration_us: us} ->
        {:error, {:timeout, us}}

      %{status: :ok, serial: serial, duration_us: us} ->
        compare(cases, serial, us, image.size)
    end
  end

  # ══ The cases ════════════════════════════════════════════════════════════════

  @doc """
  One case per rule, so that a failure names the rule and not a byte offset.

  Returns `{names, cases}`: the names are only ever read by a failing test.
  """
  @spec directed_cases() :: {[String.t()], [bench_case()]}
  def directed_cases do
    powered = %{0xFF26 => 0x80, 0xFF24 => 0x77, 0xFF25 => 0xFF}

    named = [
      {"the APU switched off writes silence", registers(%{0xFF24 => 0x77}), %APU{}, 64, []},
      {"a powered APU with nothing playing", registers(powered), %APU{}, 64, []},

      # The two pulses: duty, volume, the envelope in both directions, and the
      # DAC that mutes a channel however hard it is triggered.
      {"pulse 1, duty 2, flat volume",
       registers(Map.merge(powered, %{0xFF11 => 0x80, 0xFF12 => 0xF0, 0xFF14 => 0x87})), %APU{},
       256, [1]},
      {"pulse 1, envelope falling",
       registers(Map.merge(powered, %{0xFF11 => 0x80, 0xFF12 => 0xF1, 0xFF14 => 0x87})), %APU{},
       1024, [1]},
      {"pulse 1, envelope rising",
       registers(Map.merge(powered, %{0xFF11 => 0x80, 0xFF12 => 0x01, 0xFF14 => 0x87})), %APU{},
       1024, [1]},
      {"pulse 1, envelope period zero -- the timer walks negative",
       registers(Map.merge(powered, %{0xFF11 => 0x80, 0xFF12 => 0xF0, 0xFF14 => 0x87})), %APU{},
       1024, [1]},
      {"pulse 2, the duty that is not symmetric",
       registers(Map.merge(powered, %{0xFF16 => 0xC0, 0xFF17 => 0xA3, 0xFF19 => 0x86})), %APU{},
       512, [2]},
      {"a DAC switched off mutes a triggered channel",
       registers(Map.merge(powered, %{0xFF11 => 0x80, 0xFF12 => 0x00, 0xFF14 => 0x87})), %APU{},
       256, [1]},

      # The length counter, which is what stops a note.
      {"length counts down and silences",
       registers(Map.merge(powered, %{0xFF11 => 0x3E, 0xFF12 => 0xF0, 0xFF14 => 0xC7})), %APU{},
       2048, [1]},
      {"length armed but already zero",
       registers(Map.merge(powered, %{0xFF11 => 0x00, 0xFF12 => 0xF0, 0xFF14 => 0xC7})), %APU{},
       2048, [1]},

      # The sweep, channel one alone: up, down, and the overflow that kills it.
      {"sweep sliding up",
       registers(
         Map.merge(powered, %{
           0xFF10 => 0x17,
           0xFF11 => 0x80,
           0xFF12 => 0xF0,
           0xFF13 => 0x00,
           0xFF14 => 0x86
         })
       ), %APU{}, 4096, [1]},
      {"sweep sliding down",
       registers(
         Map.merge(powered, %{
           0xFF10 => 0x1F,
           0xFF11 => 0x80,
           0xFF12 => 0xF0,
           0xFF13 => 0xFF,
           0xFF14 => 0x87
         })
       ), %APU{}, 4096, [1]},
      {"sweep overflowing past 2047 silences the channel",
       registers(
         Map.merge(powered, %{
           0xFF10 => 0x11,
           0xFF11 => 0x80,
           0xFF12 => 0xF0,
           0xFF13 => 0xFF,
           0xFF14 => 0x87
         })
       ), %APU{}, 4096, [1]},
      {"sweep with a shift of zero moves nothing",
       registers(
         Map.merge(powered, %{0xFF10 => 0x10, 0xFF11 => 0x80, 0xFF12 => 0xF0, 0xFF14 => 0x86})
       ), %APU{}, 2048, [1]},

      # The wave: its table, its four volume codes, its own DAC.
      {"the wave channel plays its table", wave_registers(powered, 0x20), %APU{}, 512, [3]},
      {"the wave at half volume", wave_registers(powered, 0x40), %APU{}, 512, [3]},
      {"the wave at a quarter", wave_registers(powered, 0x60), %APU{}, 512, [3]},
      {"the wave muted by NR32", wave_registers(powered, 0x00), %APU{}, 512, [3]},
      {"the wave with its DAC off",
       wave_registers(%{powered | 0xFF26 => 0x80} |> Map.put(0xFF1A, 0x00), 0x20), %APU{}, 512,
       [3]},

      # The noise: both LFSR widths, and the divisor that floors at eight.
      {"noise, wide LFSR",
       registers(Map.merge(powered, %{0xFF20 => 0x00, 0xFF21 => 0xF0, 0xFF22 => 0x44})), %APU{},
       1024, [4]},
      {"noise, narrow LFSR -- the metallic ring",
       registers(Map.merge(powered, %{0xFF20 => 0x00, 0xFF21 => 0xF0, 0xFF22 => 0x4C})), %APU{},
       1024, [4]},
      {"noise with divisor code zero -- eight cycles, not zero",
       registers(Map.merge(powered, %{0xFF20 => 0x00, 0xFF21 => 0xF0, 0xFF22 => 0x00})), %APU{},
       1024, [4]},
      {"noise at the slowest divisor",
       registers(Map.merge(powered, %{0xFF20 => 0x00, 0xFF21 => 0xF0, 0xFF22 => 0xD7})), %APU{},
       1024, [4]},

      # NR50 and NR51: the two ears, and a channel routed to one of them.
      {"NR51 routing channel 1 to the left only",
       registers(
         Map.merge(powered, %{
           0xFF25 => 0x10,
           0xFF11 => 0x80,
           0xFF12 => 0xF0,
           0xFF14 => 0x87
         })
       ), %APU{}, 256, [1]},
      {"NR50 at its quietest",
       registers(
         Map.merge(powered, %{0xFF24 => 0x00, 0xFF11 => 0x80, 0xFF12 => 0xF0, 0xFF14 => 0x87})
       ), %APU{}, 256, [1]},

      # All four at once, for a frame's worth -- the shape the console produces.
      {"four channels, one frame", everything(powered), %APU{}, max_samples(), [1, 2, 3, 4]},

      # And a count of zero, which still has to consume the triggers.
      {"zero samples still consumes the triggers",
       registers(Map.merge(powered, %{0xFF11 => 0x80, 0xFF12 => 0xF0, 0xFF14 => 0x87})), %APU{},
       0, [1]}
    ]

    {
      Enum.map(named, fn {name, _, _, _, _} -> name end),
      Enum.map(named, fn {_, regs, state, count, triggers} ->
        %{registers: regs, state: state, count: count, triggers: triggers}
      end)
    }
  end

  @doc """
  `count` cases of random registers over random channel state.

  The registers are random bytes, which is the point: every reserved bit, every
  nonsensical combination, and periods nobody would write on purpose. The state
  is random within the ranges the hardware can actually reach, because a state
  the emulator could never have produced would only prove the two implementations
  disagree about something neither will ever be asked.

  `seed` is fixed by callers so that a failure is reproducible.
  """
  @spec random_cases(pos_integer(), integer()) :: [bench_case()]
  def random_cases(count, seed) do
    :rand.seed(:exsss, {seed, seed * 2, seed * 3})

    for _ <- 1..count do
      registers =
        for _ <- 1..@regs_bytes, into: <<>> do
          <<:rand.uniform(256) - 1>>
        end

      # NR52's power bit on, or nothing below it would run at all.
      registers =
        put_byte(registers, 0xFF26, Bitwise.bor(:binary.at(registers, 0x26 - 0x10), 0x80))

      %{
        registers: registers,
        state: random_state(),
        count: Enum.random([1, 63, 64, 65, 128, 512, max_samples()]),
        triggers: Enum.filter(1..4, fn _ -> :rand.uniform(3) == 1 end)
      }
    end
  end

  defp random_state do
    %APU{
      ch1: random_pulse(),
      ch2: random_pulse(),
      ch3: %APU.Wave{
        enabled: :rand.uniform(2) == 1,
        timer: :rand.uniform(2048) - 1,
        pos: :rand.uniform(32) - 1,
        length: :rand.uniform(257) - 1
      },
      ch4: %APU.Noise{
        enabled: :rand.uniform(2) == 1,
        timer: :rand.uniform(2048) - 1,
        length: :rand.uniform(65) - 1,
        volume: :rand.uniform(16) - 1,
        env_timer: :rand.uniform(8) - 1,
        # Zero is a legal LFSR and a stuck one: the feedback of two zero bits is
        # zero forever. It is reachable, so it is generated.
        lfsr: :rand.uniform(0x8000) - 1
      },
      seq_acc: (:rand.uniform(64) - 1) * 128,
      seq_step: :rand.uniform(8) - 1,
      sample_acc: :rand.uniform(128) - 1
    }
  end

  defp random_pulse do
    %APU.Pulse{
      enabled: :rand.uniform(2) == 1,
      timer: :rand.uniform(2048) - 1,
      pos: :rand.uniform(8) - 1,
      length: :rand.uniform(65) - 1,
      volume: :rand.uniform(16) - 1,
      env_timer: :rand.uniform(8) - 1,
      sweep_timer: :rand.uniform(8) - 1,
      shadow: :rand.uniform(2048) - 1
    }
  end

  defp max_samples, do: Native.max_samples()

  defp registers(overrides) do
    for addr <- @regs_from..@regs_to, into: <<>> do
      <<Map.get(overrides, addr, 0)>>
    end
  end

  # A wave channel with a table worth hearing: a ramp up and back down, which is
  # what a game lays there for a bass note.
  defp wave_registers(base, nr32) do
    table =
      for i <- 0..15, into: %{} do
        {0xFF30 + i, Bitwise.bor(Bitwise.bsl(rem(i, 16), 4), rem(15 - i, 16))}
      end

    base
    |> Map.merge(%{
      0xFF1A => 0x80,
      0xFF1B => 0x00,
      0xFF1C => nr32,
      0xFF1D => 0x00,
      0xFF1E => 0x86
    })
    |> Map.merge(table)
    |> registers()
  end

  defp everything(base) do
    table = for i <- 0..15, into: %{}, do: {0xFF30 + i, Bitwise.bsl(i, 4) + (15 - i)}

    base
    |> Map.merge(%{
      0xFF10 => 0x15,
      0xFF11 => 0x80,
      0xFF12 => 0xF3,
      0xFF13 => 0x00,
      0xFF14 => 0x86,
      0xFF16 => 0x40,
      0xFF17 => 0xA2,
      0xFF18 => 0x80,
      0xFF19 => 0x87,
      0xFF1A => 0x80,
      0xFF1B => 0x00,
      0xFF1C => 0x20,
      0xFF1D => 0x00,
      0xFF1E => 0x85,
      0xFF20 => 0x10,
      0xFF21 => 0xC2,
      0xFF22 => 0x45,
      0xFF23 => 0x80
    })
    |> Map.merge(table)
    |> registers()
  end

  defp put_byte(binary, address, value) do
    offset = address - @regs_from
    <<before::binary-size(^offset), _::8, rest::binary>> = binary
    <<before::binary, value::8, rest::binary>>
  end

  # ══ The image ════════════════════════════════════════════════════════════════

  @doc "The image the guest runs, exposed for anyone wanting to size or dump it."
  @spec image([bench_case()]) :: Asm.assembled()
  def image(cases) do
    # Sized for the largest case, not for a frame. `Native.max_bytes/0` is what
    # the console produces between two vblanks, and the firmware is right to use
    # it; a bench that wants four thousand samples to watch an envelope decay is
    # asking a legitimate question of `apu_samples`, which generates exactly what
    # it is given.
    #
    # This was found the hard way. The buffer was one frame long, the case table
    # sat directly behind it, and a case asking for more than a frame wrote
    # straight through the counts of every case after it -- so each case passed
    # alone and eight together ran forever on a sample count read out of its own
    # overflow.
    widest = cases |> Enum.map(& &1.count) |> Enum.max() |> max(Native.max_samples())

    Image.build(
      [driver(length(cases))],
      [
        Native.data(),
        {:align, 4},
        Asm.label(:bench_samples),
        {:space, widest * 4},
        Asm.label(:bench_cases),
        Enum.map(cases, &encode_case/1),
        Asm.label(:bench_memory),
        {:space, @memory}
      ] ++ [Native.routines()]
    )
  end

  # The routines go into the data section behind the 64 KB rather than into the
  # code, which reads backwards and is not: `Image.build/2` puts data after code
  # so that no branch has to span the 64 KB, and the APU's own branches are all
  # inside itself. What must not happen is the driver branching *across* the
  # memory block, and it does not -- it only calls, and a call reaches a
  # megabyte.
  defp driver(count) do
    [
      Asm.la(Regs.mem(), :bench_memory),
      Asm.la(:s0, :bench_cases),
      RV32.li(:s1, count),
      RV32.li(:a0, @magic),
      Asm.call(:putc),
      Asm.label(:bench_case_loop),

      # The registers, into the 64 KB where the APU expects to read them.
      RV32.li(:t2, @regs_from),
      RV32.add(:t2, Regs.mem(), :t2),
      RV32.mv(:t3, :s0),
      RV32.addi(:t4, :s0, @regs_bytes),
      Asm.label(:bench_install_regs),
      RV32.lbu(:t5, :t3, 0),
      RV32.sb(:t5, :t2, 0),
      RV32.addi(:t3, :t3, 1),
      RV32.addi(:t2, :t2, 1),
      Asm.bne(:t3, :t4, :bench_install_regs),

      # The channel state, into the block the routines own.
      Asm.la(:t2, :apu_state),
      RV32.addi(:t4, :t3, @state_bytes),
      Asm.label(:bench_install_state),
      RV32.lw(:t5, :t3, 0),
      RV32.sw(:t5, :t2, 0),
      RV32.addi(:t3, :t3, 4),
      RV32.addi(:t2, :t2, 4),
      Asm.bne(:t3, :t4, :bench_install_state),

      # And the run itself.
      RV32.lw(:a0, :t3, 0),
      RV32.mv(:s2, :a0),
      Asm.la(:t0, :bench_samples),
      Asm.call(:apu_samples),

      # What came out: the samples, then the state they left behind.
      Asm.la(:s3, :bench_samples),
      RV32.slli(:s4, :s2, 2),
      Asm.label(:bench_emit_samples),
      Asm.beqz(:s4, :bench_emit_state),
      RV32.lbu(:a0, :s3, 0),
      Asm.call(:putc),
      RV32.addi(:s3, :s3, 1),
      RV32.addi(:s4, :s4, -1),
      Asm.j(:bench_emit_samples),
      Asm.label(:bench_emit_state),
      Asm.la(:s3, :apu_state),
      RV32.li(:s4, @state_bytes),
      Asm.label(:bench_emit_state_loop),
      Asm.beqz(:s4, :bench_case_done),
      RV32.lbu(:a0, :s3, 0),
      Asm.call(:putc),
      RV32.addi(:s3, :s3, 1),
      RV32.addi(:s4, :s4, -1),
      Asm.j(:bench_emit_state_loop),
      Asm.label(:bench_case_done),
      RV32.li(:t0, @case_bytes),
      RV32.add(:s0, :s0, :t0),
      RV32.addi(:s1, :s1, -1),
      Asm.bnez(:s1, :bench_case_loop),
      Asm.j(:poweroff)
    ]
  end

  defp encode_case(%{registers: registers, state: state, count: count, triggers: triggers}) do
    <<registers::binary-size(@regs_bytes), encode_state(state, triggers)::binary,
      count::32-little>>
  end

  # ══ The state, both ways ═════════════════════════════════════════════════════

  @doc """
  `Atomboy.APU`'s state as the generated code's 144 bytes.

  `triggers` becomes the four-bit mask the seam would have set -- see
  `Atomboy.Native.APU` on why a mask is enough where Elixir keeps a list.
  """
  @spec encode_state(APU.t(), [1..4]) :: binary()
  def encode_state(%APU{} = apu, triggers \\ []) do
    mask = Enum.reduce(triggers, 0, fn channel, acc -> Bitwise.bor(acc, 1 <<< (channel - 1)) end)

    <<channel(apu.ch1)::binary, channel(apu.ch2)::binary, channel(apu.ch3)::binary,
      channel(apu.ch4)::binary, apu.seq_acc::32-little, apu.seq_step::32-little,
      apu.sample_acc::32-little, mask::32-little>>
  end

  @doc "The inverse: the guest's 144 bytes back into a `%Atomboy.APU{}`."
  @spec decode_state(binary()) :: APU.t()
  def decode_state(
        <<c1::binary-size(32), c2::binary-size(32), c3::binary-size(32), c4::binary-size(32),
          seq_acc::32-little-signed, seq_step::32-little, sample_acc::32-little,
          _triggers::32-little>>
      ) do
    %APU{
      ch1: pulse(c1),
      ch2: pulse(c2),
      ch3: wave(c3),
      ch4: noise(c4),
      seq_acc: seq_acc,
      seq_step: seq_step,
      sample_acc: sample_acc
    }
  end

  defp channel(%APU.Pulse{} = ch) do
    <<flag(ch.enabled)::32-little, ch.timer::32-little, ch.pos::32-little, ch.length::32-little,
      ch.volume::32-little, ch.env_timer::32-little-signed, ch.sweep_timer::32-little-signed,
      ch.shadow::32-little>>
  end

  defp channel(%APU.Wave{} = ch) do
    <<flag(ch.enabled)::32-little, ch.timer::32-little, ch.pos::32-little, ch.length::32-little,
      0::32, 0::32, 0::32, 0::32>>
  end

  defp channel(%APU.Noise{} = ch) do
    <<flag(ch.enabled)::32-little, ch.timer::32-little, 0::32, ch.length::32-little,
      ch.volume::32-little, ch.env_timer::32-little-signed, 0::32, ch.lfsr::32-little>>
  end

  defp pulse(
         <<enabled::32-little, timer::32-little, pos::32-little, length::32-little-signed,
           volume::32-little, env::32-little-signed, sweep::32-little-signed, shadow::32-little>>
       ) do
    %APU.Pulse{
      enabled: enabled != 0,
      timer: timer,
      pos: pos,
      length: length,
      volume: volume,
      env_timer: env,
      sweep_timer: sweep,
      shadow: shadow
    }
  end

  defp wave(
         <<enabled::32-little, timer::32-little, pos::32-little, length::32-little-signed,
           _rest::binary>>
       ) do
    %APU.Wave{enabled: enabled != 0, timer: timer, pos: pos, length: length}
  end

  defp noise(
         <<enabled::32-little, timer::32-little, _pos::32, length::32-little-signed,
           volume::32-little, env::32-little-signed, _sweep::32, lfsr::32-little>>
       ) do
    %APU.Noise{
      enabled: enabled != 0,
      timer: timer,
      length: length,
      volume: volume,
      env_timer: env,
      lfsr: lfsr
    }
  end

  # `false` is zero and `true` is every bit, so a gate costs an `and` and not a
  # branch on the other side.
  defp flag(true), do: 0xFFFFFFFF
  defp flag(false), do: 0

  # ══ The comparison ═══════════════════════════════════════════════════════════

  defp compare(cases, <<@magic, stream::binary>>, duration_us, size) do
    {divergences, leftover} =
      cases
      |> Enum.with_index()
      |> Enum.reduce({[], stream}, fn {bench_case, index}, {acc, rest} ->
        bytes = bench_case.count * 4

        case rest do
          <<samples::binary-size(^bytes), state::binary-size(@state_bytes), tail::binary>> ->
            {report(acc, bench_case, index, samples, decode_state(state)), tail}

          short ->
            {[%{index: index, truncated: byte_size(short)} | acc], <<>>}
        end
      end)

    {:ok,
     %{
       divergences: Enum.reverse(divergences),
       leftover: byte_size(leftover),
       duration_us: duration_us,
       size: size
     }}
  end

  defp compare(_cases, other, _us, _size) do
    {:error,
     {:unreadable_stream, byte_size(other), binary_part(other, 0, min(32, byte_size(other)))}}
  end

  defp report(acc, bench_case, index, samples, state) do
    {expected, _ram, expected_state} = oracle(bench_case)

    fields = state_diff(expected_state, state)
    offset = first_difference(expected, samples)

    if offset == nil and fields == [] do
      acc
    else
      [
        %{
          index: index,
          samples: offset,
          state: fields,
          expected: expected,
          got: samples
        }
        | acc
      ]
    end
  end

  @doc """
  What `Atomboy.APU` makes of the same case -- the oracle, called directly.

  The `ram` handed over holds the register window and the triggers, and nothing
  else: no `:mixer`, so the master volume defaults to a hundred and every voice
  is on, which is the only configuration the generated code models.
  """
  @spec oracle(bench_case()) :: {binary(), map(), APU.t()}
  def oracle(%{registers: registers, state: state, count: count, triggers: triggers}) do
    ram =
      registers
      |> :binary.bin_to_list()
      |> Enum.with_index(@regs_from)
      |> Map.new(fn {byte, addr} -> {addr, byte} end)

    ram = if triggers == [], do: ram, else: Map.put(ram, :apu_triggers, Enum.reverse(triggers))

    APU.samples(ram, state, count)
  end

  defp first_difference(same, same), do: nil

  defp first_difference(expected, got) do
    limit = min(byte_size(expected), byte_size(got))

    Enum.find(0..(limit - 1)//1, fn i ->
      :binary.at(expected, i) != :binary.at(got, i)
    end) || limit
  end

  defp state_diff(%APU{} = expected, %APU{} = got) do
    [:seq_acc, :seq_step, :sample_acc]
    |> Enum.flat_map(fn key ->
      if Map.fetch!(expected, key) == Map.fetch!(got, key),
        do: [],
        else: [{key, Map.fetch!(expected, key), Map.fetch!(got, key)}]
    end)
    |> Kernel.++(
      Enum.flat_map([:ch1, :ch2, :ch3, :ch4], fn channel ->
        left = Map.fetch!(expected, channel)
        right = Map.fetch!(got, channel)

        left
        |> Map.from_struct()
        |> Map.keys()
        |> Enum.flat_map(fn key ->
          if Map.fetch!(left, key) == Map.fetch!(right, key),
            do: [],
            else: [{:"#{channel}.#{key}", Map.fetch!(left, key), Map.fetch!(right, key)}]
        end)
      end)
    )
  end
end
