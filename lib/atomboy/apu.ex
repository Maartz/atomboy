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
  Le son de la DMG, les quatre canaux : deux pulses, la wave, le bruit.

  L'APU réelle avance au cycle ; celle-ci avance à la frame, l'échelle de
  temps de la musique : les jeux posent leurs notes au vblank, une frame de
  granularité suffit pour les entendre. Chaque frame produit ses
  échantillons stéréo s16le à `sample_rate` Hz, prêts pour un lecteur PCM.

  ## Le modèle

  Les registres (0xFF10-0xFF26) vivent dans la map mémoire de CartLoop, lus
  à la génération — une note posée pendant la frame sonne à la suivante.
  Les *déclenchements* (bit 7 de NR14/NR24) sont capturés à l'écriture par
  CartLoop sous `:apu_triggers` : ils rechargent longueur, enveloppe, sweep.

  Le séquenceur de frame matériel (512 Hz) est reproduit : longueur à
  256 Hz, sweep à 128 Hz, enveloppe à 64 Hz — cadencé par les cycles
  machine écoulés, 128 par échantillon à 32 768 Hz.

      NR10 0xFF10  sweep : période 6-4, sens 3, décalage 2-0   (canal 1)
      NRx1         duty 7-6, longueur 5-0
      NRx2         enveloppe : volume 7-4, sens 3, période 2-0
      NRx3/NRx4    fréquence 11 bits, trigger 7, longueur armée 6
      NR30 0xFF1A  DAC du canal wave (bit 7)
      NR32 0xFF1C  volume wave (bits 6-5 : muet, 100 %, 50 %, 25 %)
      0xFF30-3F    la table d'onde : 32 échantillons de 4 bits
      NR43 0xFF22  bruit : décalage 7-4, largeur 3, diviseur 2-0
      NR50 0xFF24  volume gauche 6-4, droit 2-0
      NR51 0xFF25  aiguillage canal → gauche/droite
      NR52 0xFF26  bit 7 : l'APU sous tension

  Le canal wave rejoue sa table à (2048-f)×2 cycles le pas — c'est lui qui
  porte les basses. Le bruit sort d'un LFSR 15 bits (7 en mode étroit),
  cadencé par diviseur et décalage — percussions et souffles.

  Un canal au DAC éteint (bits 7-3 de NRx2 à zéro) est muet, trigger ou pas
  — c'est ainsi que les jeux coupent une voix.
  """

  import Bitwise

  @clock 4_194_304
  @sample_rate 32_768
  @cycles_per_sample div(@clock, @sample_rate)
  @frame_cycles 70_224
  @seq_period 8192

  # Les quatre rapports cycliques : 8 pas d'onde chacun.
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

  @doc "Le débit d'échantillonnage des frames produites."
  @spec sample_rate() :: pos_integer()
  def sample_rate, do: @sample_rate

  @doc """
  Une frame de son : consomme les déclenchements capturés, avance les
  canaux de 70 224 cycles, rend `{échantillons, ram, apu}` — stéréo s16le.
  Le reste de cycles se reporte : dérive nulle sur la durée.
  """
  @spec frame(map(), t()) :: {binary(), map(), t()}
  def frame(ram, apu) do
    {count, carry} = sample_count(apu)
    {bin, ram, apu} = samples(ram, apu, count)
    {bin, ram, %{apu | sample_acc: carry}}
  end

  @doc """
  Exactement `count` échantillons — la voie de la sortie audio asservie à
  l'horloge murale : le temps de l'APU y avance d'un pas de 128 cycles par
  échantillon, indépendamment du découpage en frames. Les déclenchements
  capturés sont consommés même à zéro échantillon demandé.
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

  # Les registres sont figés à l'échelle de la frame : tout se lit une fois
  # ici, la boucle interne (548 tours) ne touche plus jamais la map — c'est
  # la condition pour tenir dans le budget des 16,7 ms.
  defp config(ram) do
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
      lmul: ((bsr(nr50, 4) &&& 0x07) + 1) * 60,
      rmul: ((nr50 &&& 0x07) + 1) * 60,
      l1: (nr51 &&& 0x10) != 0,
      l2: (nr51 &&& 0x20) != 0,
      r1: (nr51 &&& 0x01) != 0,
      r2: (nr51 &&& 0x02) != 0,
      # Canal wave : DAC, table figée en tuple, période d'un pas, volume.
      dac3: (Map.get(ram, 0xFF1A, 0) &&& 0x80) != 0,
      table3: wave_table(ram),
      p3: (2048 - reg_freq(ram, 0xFF1D, 0xFF1E)) * 2,
      shift3: elem({4, 0, 1, 2}, bsr(Map.get(ram, 0xFF1C, 0), 5) &&& 0x03),
      len3: (Map.get(ram, 0xFF1E, 0) &&& 0x40) != 0,
      l3: (nr51 &&& 0x40) != 0,
      r3: (nr51 &&& 0x04) != 0,
      # Canal bruit : enveloppe, période du LFSR, largeur.
      env4: env4,
      dac4: dac_on?(env4),
      p4: bsl(divisor, bsr(nr43, 4) &&& 0x0F),
      narrow4: (nr43 &&& 0x08) != 0,
      len4: (Map.get(ram, 0xFF23, 0) &&& 0x40) != 0,
      l4: (nr51 &&& 0x80) != 0,
      r4: (nr51 &&& 0x08) != 0
    }
  end

  # Les 32 échantillons de 4 bits de la table d'onde, quartet haut d'abord.
  defp wave_table(ram) do
    for addr <- 0xFF30..0xFF3F, byte = Map.get(ram, addr, 0), nibble <- [bsr(byte, 4), byte &&& 0x0F] do
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
          # Le séquenceur : un pas tous les 8192 cycles.
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

          # Canal 1 sous sweep : la fréquence glisse, sa période se recalcule.
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

  # ── Le déclenchement ────────────────────────────────────────────────────────

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

  # ── Le séquenceur de frame ──────────────────────────────────────────────────

  # Longueur : pas 0, 2, 4, 6 — 256 Hz.
  defp clock_length(ch, len_on?, step) when rem(step, 2) == 0 do
    if len_on? and ch.length > 0 do
      length = ch.length - 1
      %{ch | length: length, enabled: ch.enabled and length > 0}
    else
      ch
    end
  end

  defp clock_length(ch, _len_on?, _step), do: ch

  # Enveloppe : pas 7 — 64 Hz.
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

  # Sweep (canal 1) : pas 2 et 6 — 128 Hz.
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

  # ── L'onde ──────────────────────────────────────────────────────────────────

  defp reg_freq(ram, nrx3, nrx4) do
    Map.get(ram, nrx3, 0) ||| bsl(Map.get(ram, nrx4, 0) &&& 0x07, 8)
  end

  # Avancer l'onde de 128 cycles : le pas de duty tourne à `period` cycles.
  defp advance(%Pulse{enabled: false} = ch, _period), do: ch

  defp advance(ch, period) do
    timer = ch.timer + @cycles_per_sample
    steps = div(timer, period)
    %{ch | timer: rem(timer, period), pos: rem(ch.pos + steps, 8)}
  end

  defp output(%Pulse{enabled: false}, _duty, _dac?), do: 0
  defp output(_ch, _duty, false), do: 0
  defp output(ch, duty, true), do: elem(duty, ch.pos) * ch.volume

  # ── Le canal wave ───────────────────────────────────────────────────────────

  # 32 pas par cycle de table, (2048-f)×2 cycles le pas.
  defp advance_wave(%Wave{enabled: false} = ch, _period), do: ch

  defp advance_wave(ch, period) do
    timer = ch.timer + @cycles_per_sample
    steps = div(timer, period)
    %{ch | timer: rem(timer, period), pos: rem(ch.pos + steps, 32)}
  end

  defp output_wave(%Wave{enabled: false}, _cfg), do: 0
  defp output_wave(_ch, %{dac3: false}), do: 0
  defp output_wave(ch, cfg), do: bsr(elem(cfg.table3, ch.pos), cfg.shift3)

  # ── Le canal bruit ──────────────────────────────────────────────────────────

  # Le LFSR 15 bits : xor des deux bits bas réinjecté en tête — et copié au
  # bit 6 en mode étroit, le « bip » métallique. Au pire 16 pas par
  # échantillon (période plancher 8 cycles).
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

  # ── Le mélange ──────────────────────────────────────────────────────────────

  # NR51 aiguille chaque canal vers chaque oreille, NR50 dose 0-7 par côté.
  # Pire cas : 15 de volume × 4 canaux × (7+1) de NR50 × 60 = 28 800,
  # sous les 32 767 du s16.
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
