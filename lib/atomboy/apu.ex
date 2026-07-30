defmodule Atomboy.APU.Pulse do
  @moduledoc false
  defstruct enabled: false,
            timer: 0,
            pos: 0,
            length: 0,
            volume: 0,
            env_timer: 0,
            sweep_timer: 0,
            shadow: 0
end

defmodule Atomboy.APU.Wave do
  @moduledoc false
  defstruct enabled: false, timer: 0, pos: 0, length: 0
end

defmodule Atomboy.APU.Noise do
  @moduledoc false
  defstruct enabled: false,
            timer: 0,
            length: 0,
            volume: 0,
            env_timer: 0,
            lfsr: 0x7FFF
end

defmodule Atomboy.APU do
  @moduledoc """
  The DMG's sound, all four channels: two pulses, the wave, the noise.

  The real APU advances per cycle; this one advances per frame, the time
  scale of music: games lay their notes down at vblank, one frame of
  granularity is enough to hear them. Each frame produces its stereo s16le
  samples at `sample_rate` Hz, ready for a PCM player.

  ## The model

  The registers (0xFF10-0xFF26) live in CartLoop's memory map, read at
  generation time — a note laid down during the frame sounds on the next
  one. The *triggers* (bit 7 of NR14/NR24) are captured on write by CartLoop
  under `:apu_triggers`: they reload length, envelope and sweep.

  The hardware frame sequencer (512 Hz) is reproduced: length at 256 Hz,
  sweep at 128 Hz, envelope at 64 Hz — clocked by the machine cycles
  elapsed, 128 per sample at 32,768 Hz.

      NR10 0xFF10  sweep: period 6-4, direction 3, shift 2-0   (channel 1)
      NRx1         duty 7-6, length 5-0
      NRx2         envelope: volume 7-4, direction 3, period 2-0
      NRx3/NRx4    11-bit frequency, trigger 7, length armed 6
      NR30 0xFF1A  the wave channel's DAC (bit 7)
      NR32 0xFF1C  wave volume (bits 6-5: mute, 100%, 50%, 25%)
      0xFF30-3F    the wave table: 32 samples of 4 bits
      NR43 0xFF22  noise: shift 7-4, width 3, divisor 2-0
      NR50 0xFF24  left volume 6-4, right 2-0
      NR51 0xFF25  channel → left/right routing
      NR52 0xFF26  bit 7: the APU is powered on

  The wave channel replays its table at (2048-f)×2 cycles per step — it is
  the one carrying the bass. The noise comes out of a 15-bit LFSR (7 in
  narrow mode), clocked by divisor and shift — percussion and hiss.

  A channel whose DAC is off (bits 7-3 of NRx2 at zero) is mute, trigger or
  not — that is how games cut a voice.
  """

  import Bitwise

  @clock 4_194_304
  @sample_rate 32_768
  @cycles_per_sample div(@clock, @sample_rate)
  @frame_cycles 70_224
  @seq_period 8192

  # The four duty cycles: 8 wave steps each.
  @duty {
    {0, 0, 0, 0, 0, 0, 0, 1},
    {1, 0, 0, 0, 0, 0, 0, 1},
    {1, 0, 0, 0, 0, 1, 1, 1},
    {0, 1, 1, 1, 1, 1, 1, 0}
  }

  alias Atomboy.APU.Noise
  alias Atomboy.APU.Pulse
  alias Atomboy.APU.Wave

  defstruct ch1: %Pulse{},
            ch2: %Pulse{},
            ch3: %Wave{},
            ch4: %Noise{},
            seq_acc: 0,
            seq_step: 0,
            sample_acc: 0

  @type t :: %__MODULE__{}

  @doc "The sample rate of the frames produced."
  @spec sample_rate() :: pos_integer()
  def sample_rate, do: @sample_rate

  @doc """
  One frame of sound: consumes the captured triggers, advances the channels
  by 70,224 cycles, returns `{samples, ram, apu}` — stereo s16le. The
  leftover cycles carry over: zero drift over time.
  """
  @spec frame(map(), t()) :: {binary(), map(), t()}
  def frame(ram, apu) do
    {count, carry} = sample_count(apu)
    {bin, ram, apu} = samples(ram, apu, count)
    {bin, ram, %{apu | sample_acc: carry}}
  end

  @doc """
  Exactly `count` samples — the path taken by audio output slaved to the wall
  clock: the APU's time advances there in steps of 128 cycles per sample,
  independently of how frames are cut. The captured triggers are consumed
  even when zero samples are asked for.
  """
  @spec samples(map(), t(), non_neg_integer()) :: {binary(), map(), t()}
  def samples(ram, apu, count) do
    apu =
      ram
      |> Map.get(:apu_triggers, [])
      |> Enum.reverse()
      |> Enum.reduce(apu, &trigger(&2, &1, ram))

    ram = Map.delete(ram, :apu_triggers)

    cond do
      count <= 0 ->
        {<<>>, ram, apu}

      (Map.get(ram, 0xFF26, 0xF1) &&& 0x80) == 0 ->
        {:binary.copy(<<0, 0, 0, 0>>, count), ram, apu}

      true ->
        {bin, apu} = generate(ram, apu, count)
        {bin, ram, apu}
    end
  end

  defp sample_count(apu) do
    total = @frame_cycles + apu.sample_acc
    {div(total, @cycles_per_sample), rem(total, @cycles_per_sample)}
  end

  # The registers are frozen at frame scale: everything is read once here,
  # and the inner loop (548 turns) never touches the map again — that is the
  # condition for staying inside the 16.7 ms budget. The emulator's mixer
  # (ram[:mixer], set by the menu) folds in here too: master volume into the
  # multipliers, muted voices into the NR51 gates — per-sample cost: zero.
  defp config(ram) do
    {volume, {v1?, v2?, v3?, v4?}} =
      case Map.get(ram, :mixer) do
        %{volume: v, voices: voices} -> {v, voices}
        _ -> {100, {true, true, true, true}}
      end

    nr10 = Map.get(ram, 0xFF10, 0)
    nr50 = Map.get(ram, 0xFF24, 0x77)
    nr51 = Map.get(ram, 0xFF25, 0xF3)
    env1 = Map.get(ram, 0xFF12, 0)
    env2 = Map.get(ram, 0xFF17, 0)
    env4 = Map.get(ram, 0xFF21, 0)
    nr43 = Map.get(ram, 0xFF22, 0)
    divisor = if (nr43 &&& 0x07) == 0, do: 8, else: (nr43 &&& 0x07) * 16

    %{
      nr10: nr10,
      sweep?: (nr10 &&& 0x77) != 0,
      duty1: elem(@duty, bsr(Map.get(ram, 0xFF11, 0), 6)),
      duty2: elem(@duty, bsr(Map.get(ram, 0xFF16, 0), 6)),
      env1: env1,
      env2: env2,
      dac1: dac_on?(env1),
      dac2: dac_on?(env2),
      p1: (2048 - reg_freq(ram, 0xFF13, 0xFF14)) * 4,
      p2: (2048 - reg_freq(ram, 0xFF18, 0xFF19)) * 4,
      len1: (Map.get(ram, 0xFF14, 0) &&& 0x40) != 0,
      len2: (Map.get(ram, 0xFF19, 0) &&& 0x40) != 0,
      lmul: div(((bsr(nr50, 4) &&& 0x07) + 1) * 60 * volume, 100),
      rmul: div(((nr50 &&& 0x07) + 1) * 60 * volume, 100),
      l1: (nr51 &&& 0x10) != 0 and v1?,
      l2: (nr51 &&& 0x20) != 0 and v2?,
      r1: (nr51 &&& 0x01) != 0 and v1?,
      r2: (nr51 &&& 0x02) != 0 and v2?,
      # Wave channel: DAC, table frozen into a tuple, step period, volume.
      dac3: (Map.get(ram, 0xFF1A, 0) &&& 0x80) != 0,
      table3: wave_table(ram),
      p3: (2048 - reg_freq(ram, 0xFF1D, 0xFF1E)) * 2,
      shift3: elem({4, 0, 1, 2}, bsr(Map.get(ram, 0xFF1C, 0), 5) &&& 0x03),
      len3: (Map.get(ram, 0xFF1E, 0) &&& 0x40) != 0,
      l3: (nr51 &&& 0x40) != 0 and v3?,
      r3: (nr51 &&& 0x04) != 0 and v3?,
      # Noise channel: envelope, LFSR period, width.
      env4: env4,
      dac4: dac_on?(env4),
      p4: bsl(divisor, bsr(nr43, 4) &&& 0x0F),
      narrow4: (nr43 &&& 0x08) != 0,
      len4: (Map.get(ram, 0xFF23, 0) &&& 0x40) != 0,
      l4: (nr51 &&& 0x80) != 0 and v4?,
      r4: (nr51 &&& 0x08) != 0 and v4?
    }
  end

  # The wave table's 32 samples of 4 bits, high nibble first.
  defp wave_table(ram) do
    for addr <- 0xFF30..0xFF3F,
        byte = Map.get(ram, addr, 0),
        nibble <- [bsr(byte, 4), byte &&& 0x0F] do
      nibble
    end
    |> List.to_tuple()
  end

  defp generate(ram, apu, count) do
    cfg = config(ram)

    {samples, ch1, ch2, ch3, ch4, seq_acc, seq_step} =
      Enum.reduce(
        1..count,
        {[], apu.ch1, apu.ch2, apu.ch3, apu.ch4, apu.seq_acc, apu.seq_step},
        fn _, {out, ch1, ch2, ch3, ch4, seq_acc, seq_step} ->
          # The sequencer: one step every 8192 cycles.
          {ch1, ch2, ch3, ch4, seq_acc, seq_step} =
            if seq_acc + @cycles_per_sample >= @seq_period do
              step = rem(seq_step + 1, 8)

              ch1 =
                ch1
                |> clock_length(cfg.len1, step)
                |> clock_sweep(cfg.nr10, step)
                |> clock_env(cfg.env1, step)

              ch2 = ch2 |> clock_length(cfg.len2, step) |> clock_env(cfg.env2, step)
              ch3 = clock_length(ch3, cfg.len3, step)
              ch4 = ch4 |> clock_length(cfg.len4, step) |> clock_env(cfg.env4, step)
              {ch1, ch2, ch3, ch4, seq_acc + @cycles_per_sample - @seq_period, step}
            else
              {ch1, ch2, ch3, ch4, seq_acc + @cycles_per_sample, seq_step}
            end

          # Channel 1 under sweep: the frequency slides, so its period is
          # recomputed.
          p1 = if cfg.sweep?, do: (2048 - ch1.shadow) * 4, else: cfg.p1
          ch1 = advance(ch1, p1)
          ch2 = advance(ch2, cfg.p2)
          ch3 = advance_wave(ch3, cfg.p3)
          ch4 = advance_noise(ch4, cfg.p4, cfg.narrow4)

          v1 = output(ch1, cfg.duty1, cfg.dac1)
          v2 = output(ch2, cfg.duty2, cfg.dac2)
          v3 = output_wave(ch3, cfg)
          v4 = output_noise(ch4, cfg.dac4)

          {[mix(v1, v2, v3, v4, cfg) | out], ch1, ch2, ch3, ch4, seq_acc, seq_step}
        end
      )

    apu = %{
      apu
      | ch1: ch1,
        ch2: ch2,
        ch3: ch3,
        ch4: ch4,
        seq_acc: seq_acc,
        seq_step: seq_step
    }

    {samples |> Enum.reverse() |> IO.iodata_to_binary(), apu}
  end

  # ── The trigger ─────────────────────────────────────────────────────────────

  defp trigger(apu, 1, ram) do
    %{apu | ch1: trigger_pulse(apu.ch1, ram, 0xFF11, 0xFF13, 0xFF14, 0xFF10)}
  end

  defp trigger(apu, 2, ram) do
    %{apu | ch2: trigger_pulse(apu.ch2, ram, 0xFF16, 0xFF18, 0xFF19, nil)}
  end

  defp trigger(apu, 3, ram) do
    length = 256 - Map.get(ram, 0xFF1B, 0)

    ch3 = %Wave{
      apu.ch3
      | enabled: (Map.get(ram, 0xFF1A, 0) &&& 0x80) != 0,
        length: if(apu.ch3.length == 0, do: length, else: apu.ch3.length),
        pos: 0,
        timer: 0
    }

    %{apu | ch3: ch3}
  end

  defp trigger(apu, 4, ram) do
    length = 64 - (Map.get(ram, 0xFF20, 0) &&& 0x3F)
    env = Map.get(ram, 0xFF21, 0)

    ch4 = %Noise{
      apu.ch4
      | enabled: dac_on?(env),
        length: if(apu.ch4.length == 0, do: length, else: apu.ch4.length),
        volume: bsr(env, 4),
        env_timer: env &&& 0x07,
        lfsr: 0x7FFF,
        timer: 0
    }

    %{apu | ch4: ch4}
  end

  defp trigger(apu, _ch, _ram), do: apu

  defp trigger_pulse(ch, ram, nrx1, nrx3, nrx4, nr10) do
    length = 64 - (Map.get(ram, nrx1, 0) &&& 0x3F)
    env = Map.get(ram, nrx1 + 1, 0)
    shadow = reg_freq(ram, nrx3, nrx4)

    sweep_timer =
      case nr10 && Map.get(ram, nr10, 0) do
        nil -> 0
        nr10v -> sweep_period(nr10v)
      end

    %Pulse{
      ch
      | enabled: dac_on?(env),
        length: if(ch.length == 0, do: length, else: ch.length),
        volume: bsr(env, 4),
        env_timer: env &&& 0x07,
        shadow: shadow,
        sweep_timer: sweep_timer,
        timer: 0
    }
  end

  # ── The frame sequencer ─────────────────────────────────────────────────────

  # Length: steps 0, 2, 4, 6 — 256 Hz.
  defp clock_length(ch, len_on?, step) when rem(step, 2) == 0 do
    if len_on? and ch.length > 0 do
      length = ch.length - 1
      %{ch | length: length, enabled: ch.enabled and length > 0}
    else
      ch
    end
  end

  defp clock_length(ch, _len_on?, _step), do: ch

  # Envelope: step 7 — 64 Hz.
  defp clock_env(ch, nrx2v, 7) do
    period = nrx2v &&& 0x07

    if period == 0 do
      ch
    else
      case ch.env_timer - 1 do
        0 ->
          volume =
            if (nrx2v &&& 0x08) != 0,
              do: min(ch.volume + 1, 15),
              else: max(ch.volume - 1, 0)

          %{ch | volume: volume, env_timer: period}

        t ->
          %{ch | env_timer: t}
      end
    end
  end

  defp clock_env(ch, _nrx2v, _step), do: ch

  # Sweep (channel 1): steps 2 and 6 — 128 Hz.
  defp clock_sweep(ch, nr10, step) when step in [2, 6] do
    shift = nr10 &&& 0x07
    period = bsr(nr10, 4) &&& 0x07

    if period == 0 do
      ch
    else
      case ch.sweep_timer - 1 do
        0 ->
          delta = bsr(ch.shadow, shift)
          shadow = if (nr10 &&& 0x08) != 0, do: ch.shadow - delta, else: ch.shadow + delta

          cond do
            shadow > 2047 -> %{ch | enabled: false, sweep_timer: period}
            shift == 0 -> %{ch | sweep_timer: period}
            true -> %{ch | shadow: max(shadow, 0), sweep_timer: period}
          end

        t ->
          %{ch | sweep_timer: t}
      end
    end
  end

  defp clock_sweep(ch, _nr10, _step), do: ch

  defp sweep_period(nr10), do: max(bsr(nr10, 4) &&& 0x07, 1)

  # ── The wave ────────────────────────────────────────────────────────────────

  defp reg_freq(ram, nrx3, nrx4) do
    Map.get(ram, nrx3, 0) ||| bsl(Map.get(ram, nrx4, 0) &&& 0x07, 8)
  end

  # Advance the wave by 128 cycles: the duty step turns every `period` cycles.
  defp advance(%Pulse{enabled: false} = ch, _period), do: ch

  defp advance(ch, period) do
    timer = ch.timer + @cycles_per_sample
    steps = div(timer, period)
    %{ch | timer: rem(timer, period), pos: rem(ch.pos + steps, 8)}
  end

  defp output(%Pulse{enabled: false}, _duty, _dac?), do: 0
  defp output(_ch, _duty, false), do: 0
  defp output(ch, duty, true), do: elem(duty, ch.pos) * ch.volume

  # ── The wave channel ────────────────────────────────────────────────────────

  # 32 steps per table cycle, (2048-f)×2 cycles per step.
  defp advance_wave(%Wave{enabled: false} = ch, _period), do: ch

  defp advance_wave(ch, period) do
    timer = ch.timer + @cycles_per_sample
    steps = div(timer, period)
    %{ch | timer: rem(timer, period), pos: rem(ch.pos + steps, 32)}
  end

  defp output_wave(%Wave{enabled: false}, _cfg), do: 0
  defp output_wave(_ch, %{dac3: false}), do: 0
  defp output_wave(ch, cfg), do: bsr(elem(cfg.table3, ch.pos), cfg.shift3)

  # ── The noise channel ───────────────────────────────────────────────────────

  # The 15-bit LFSR: xor of the two low bits fed back at the head — and
  # copied to bit 6 in narrow mode, the metallic "beep". At worst 16 steps per
  # sample (floor period of 8 cycles).
  defp advance_noise(%Noise{enabled: false} = ch, _period, _narrow?), do: ch

  defp advance_noise(ch, period, narrow?) do
    timer = ch.timer + @cycles_per_sample
    steps = div(timer, period)
    %{ch | timer: rem(timer, period), lfsr: lfsr_steps(ch.lfsr, steps, narrow?)}
  end

  defp lfsr_steps(lfsr, 0, _narrow?), do: lfsr

  defp lfsr_steps(lfsr, steps, narrow?) do
    bit = bxor(lfsr &&& 1, bsr(lfsr, 1) &&& 1)
    lfsr = bsr(lfsr, 1) ||| bsl(bit, 14)
    lfsr = if narrow?, do: (lfsr &&& bnot(0x40)) ||| bsl(bit, 6), else: lfsr
    lfsr_steps(lfsr, steps - 1, narrow?)
  end

  defp output_noise(%Noise{enabled: false}, _dac?), do: 0
  defp output_noise(_ch, false), do: 0
  defp output_noise(ch, true), do: bxor(ch.lfsr &&& 1, 1) * ch.volume

  defp dac_on?(nrx2), do: (nrx2 &&& 0xF8) != 0

  # ── The mix ─────────────────────────────────────────────────────────────────

  # NR51 routes each channel to each ear, NR50 doses 0-7 per side. Worst
  # case: volume 15 × 4 channels × NR50's (7+1) × 60 = 28,800, under the
  # 32,767 of the s16.
  defp mix(v1, v2, v3, v4, cfg) do
    left =
      (if(cfg.l1, do: v1, else: 0) + if(cfg.l2, do: v2, else: 0) +
         if(cfg.l3, do: v3, else: 0) + if(cfg.l4, do: v4, else: 0)) * cfg.lmul

    right =
      (if(cfg.r1, do: v1, else: 0) + if(cfg.r2, do: v2, else: 0) +
         if(cfg.r3, do: v3, else: 0) + if(cfg.r4, do: v4, else: 0)) * cfg.rmul

    <<left::16-little-signed, right::16-little-signed>>
  end
end
