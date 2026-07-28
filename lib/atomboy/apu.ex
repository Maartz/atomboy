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

defmodule Atomboy.APU do
  @moduledoc """
  Le son de la DMG, canaux pulse — les deux ondes carrées.

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
      NR50 0xFF24  volume gauche 6-4, droit 2-0
      NR51 0xFF25  aiguillage canal → gauche/droite
      NR52 0xFF26  bit 7 : l'APU sous tension

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

  alias Atomboy.APU.Pulse

  defstruct ch1: %Pulse{}, ch2: %Pulse{}, seq_acc: 0, seq_step: 0, sample_acc: 0

  @type t :: %__MODULE__{}

  @doc "Le débit d'échantillonnage des frames produites."
  @spec sample_rate() :: pos_integer()
  def sample_rate, do: @sample_rate

  @doc """
  Une frame de son : consomme les déclenchements capturés, avance les
  canaux de 70 224 cycles, rend `{échantillons, ram, apu}` — stéréo s16le.
  """
  @spec frame(map(), t()) :: {binary(), map(), t()}
  def frame(ram, apu) do
    apu =
      ram
      |> Map.get(:apu_triggers, [])
      |> Enum.reverse()
      |> Enum.reduce(apu, &trigger(&2, &1, ram))

    ram = Map.delete(ram, :apu_triggers)

    if (Map.get(ram, 0xFF26, 0xF1) &&& 0x80) == 0 do
      {count, carry} = sample_count(apu)
      {:binary.copy(<<0, 0, 0, 0>>, count), ram, %{apu | sample_acc: carry}}
    else
      {samples, apu} = generate(ram, apu)
      {samples, ram, apu}
    end
  end

  # Le nombre d'échantillons de la frame — le reste de cycles se reporte,
  # la dérive reste nulle sur la durée.
  defp sample_count(apu) do
    total = @frame_cycles + apu.sample_acc
    {div(total, @cycles_per_sample), rem(total, @cycles_per_sample)}
  end

  defp generate(ram, apu) do
    {count, carry} = sample_count(apu)

    {samples, ch1, ch2, seq_acc, seq_step} =
      Enum.reduce(1..count, {[], apu.ch1, apu.ch2, apu.seq_acc, apu.seq_step}, fn _,
                                                                                 {out, ch1, ch2,
                                                                                  seq_acc,
                                                                                  seq_step} ->
        # Le séquenceur : un pas tous les 8192 cycles.
        {ch1, ch2, seq_acc, seq_step} =
          if seq_acc + @cycles_per_sample >= @seq_period do
            step = rem(seq_step + 1, 8)
            ch1 = ch1 |> clock_length(ram, 0xFF14, step) |> clock_sweep(ram, step) |> clock_env(ram, 0xFF12, step)
            ch2 = ch2 |> clock_length(ram, 0xFF19, step) |> clock_env(ram, 0xFF17, step)
            {ch1, ch2, seq_acc + @cycles_per_sample - @seq_period, step}
          else
            {ch1, ch2, seq_acc + @cycles_per_sample, seq_step}
          end

        ch1 = advance(ch1, freq(ch1, ram, 0xFF13, 0xFF14, true))
        ch2 = advance(ch2, freq(ch2, ram, 0xFF18, 0xFF19, false))

        v1 = output(ch1, ram, 0xFF11, 0xFF12)
        v2 = output(ch2, ram, 0xFF16, 0xFF17)

        {[mix(v1, v2, ram) | out], ch1, ch2, seq_acc, seq_step}
      end)

    apu = %{apu | ch1: ch1, ch2: ch2, seq_acc: seq_acc, seq_step: seq_step, sample_acc: carry}
    {samples |> Enum.reverse() |> IO.iodata_to_binary(), apu}
  end

  # ── Le déclenchement ────────────────────────────────────────────────────────

  defp trigger(apu, 1, ram) do
    %{apu | ch1: trigger_pulse(apu.ch1, ram, 0xFF11, 0xFF13, 0xFF14, 0xFF10)}
  end

  defp trigger(apu, 2, ram) do
    %{apu | ch2: trigger_pulse(apu.ch2, ram, 0xFF16, 0xFF18, 0xFF19, nil)}
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
  defp clock_length(ch, ram, nrx4, step) when rem(step, 2) == 0 do
    if (Map.get(ram, nrx4, 0) &&& 0x40) != 0 and ch.length > 0 do
      length = ch.length - 1
      %{ch | length: length, enabled: ch.enabled and length > 0}
    else
      ch
    end
  end

  defp clock_length(ch, _ram, _nrx4, _step), do: ch

  # Enveloppe : pas 7 — 64 Hz.
  defp clock_env(ch, ram, nrx2, 7) do
    nrx2v = Map.get(ram, nrx2, 0)
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

  defp clock_env(ch, _ram, _nrx2, _step), do: ch

  # Sweep (canal 1) : pas 2 et 6 — 128 Hz.
  defp clock_sweep(ch, ram, step) when step in [2, 6] do
    nr10 = Map.get(ram, 0xFF10, 0)
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

  defp clock_sweep(ch, _ram, _step), do: ch

  defp sweep_period(nr10), do: max(bsr(nr10, 4) &&& 0x07, 1)

  # ── L'onde ──────────────────────────────────────────────────────────────────

  # La fréquence : celle des registres, sauf canal 1 sous sweep actif — le
  # shadow, que le matériel fait glisser sans réécrire les registres.
  defp freq(ch, ram, nrx3, nrx4, sweep?) do
    if sweep? and (Map.get(ram, 0xFF10, 0) &&& 0x77) != 0 do
      ch.shadow
    else
      reg_freq(ram, nrx3, nrx4)
    end
  end

  defp reg_freq(ram, nrx3, nrx4) do
    Map.get(ram, nrx3, 0) ||| bsl(Map.get(ram, nrx4, 0) &&& 0x07, 8)
  end

  # Avancer l'onde de 128 cycles : le pas de duty tourne à (2048-f)×4 cycles.
  defp advance(%Pulse{enabled: false} = ch, _freq), do: ch

  defp advance(ch, freq) do
    period = (2048 - freq) * 4
    timer = ch.timer + @cycles_per_sample
    steps = div(timer, period)
    %{ch | timer: rem(timer, period), pos: rem(ch.pos + steps, 8)}
  end

  defp output(%Pulse{enabled: false}, _ram, _nrx1, _nrx2), do: 0

  defp output(ch, ram, nrx1, nrx2) do
    if dac_on?(Map.get(ram, nrx2, 0)) do
      duty = bsr(Map.get(ram, nrx1, 0), 6)
      elem(elem(@duty, duty), ch.pos) * ch.volume
    else
      0
    end
  end

  defp dac_on?(nrx2), do: (nrx2 &&& 0xF8) != 0

  # ── Le mélange ──────────────────────────────────────────────────────────────

  # NR51 aiguille chaque canal vers chaque oreille, NR50 dose 0-7 par côté.
  # Pire cas : 15 de volume × 2 canaux × (7+1) de NR50 × 60 = 14 400,
  # sous les 32 767 du s16 avec la marge des deux canaux à venir.
  defp mix(v1, v2, ram) do
    nr50 = Map.get(ram, 0xFF24, 0x77)
    nr51 = Map.get(ram, 0xFF25, 0xF3)

    left = if((nr51 &&& 0x10) != 0, do: v1, else: 0) + if (nr51 &&& 0x20) != 0, do: v2, else: 0
    right = if((nr51 &&& 0x01) != 0, do: v1, else: 0) + if (nr51 &&& 0x02) != 0, do: v2, else: 0

    left = left * ((bsr(nr50, 4) &&& 0x07) + 1) * 60
    right = right * ((nr50 &&& 0x07) + 1) * 60

    <<left::16-little-signed, right::16-little-signed>>
  end

end
