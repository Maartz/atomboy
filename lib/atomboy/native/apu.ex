defmodule Atomboy.Native.APU do
  @moduledoc """
  The DMG's four voices in RISC-V -- the mirror of `Atomboy.APU`.

  One routine, one batch of samples: stereo s16le at 32,768 Hz, exactly what
  `Atomboy.APU.samples/3` produces for the same registers and the same starting
  state. The differential bench (`Atomboy.Native.APUBench`) compares the two
  inside the guest, byte for byte, and that comparison is the only reason to
  keep the two shapes so close.

  ## Why the sample, and not the cycle

  The hardware advances its channel timers every T-cycle: 4,194,304 steps a
  second, against 32,768 samples. `Atomboy.APU` already refused that -- it
  advances a channel by the 128 cycles a sample is worth and divides to find how
  many duty steps went by, which is the same answer arrived at in one division
  instead of 128 increments. This module inherits that trade rather than
  re-deciding it, because two emulators that round differently cannot be
  compared.

  It is also the reason this module needed the M extension. Four channels, 549
  samples, one division and one remainder each: 2,196 divisions a frame is
  nothing to a `divu` and a great deal to a loop of subtractions.

  ## The calling convention

      a5   the 64 KB space's base (`Regs.mem()`)   read, never written
      a0   how many samples to produce
      t0   the destination, four bytes a sample, halfword aligned
      ---
      ra   the return

  Everything except `t0`-`t6` and `a0` comes back untouched: the routine opens a
  frame and saves every `s` register plus `a1`-`a4`, the same set
  `Atomboy.Native.PPU` saves and for the same reason -- the machine loop calls
  this at a frame boundary with the whole SM83 state live.

  ## Four channels, one shape

  The state block gives every channel the same 32 bytes, whether it uses them
  all or not. A pulse fills all eight words; the wave uses four; the noise puts
  its LFSR where the pulse keeps its sweep shadow. It costs 48 bytes of data
  that nothing reads, and it buys a single `clock_length` and a single
  `clock_env` that take a channel pointer and work on any of the four. Two
  copies of the length counter would be two things to get wrong independently.

  ## The trigger, and why it is four bits

  `Atomboy.CPU.CartLoop` captures writes to NRx4 with bit 7 set as a list under
  `:apu_triggers`, and `Atomboy.APU.samples/3` replays that list in order before
  generating anything. Reproducing a list would mean a ring buffer and a bound
  on how many triggers a frame may carry.

  It collapses to a four-bit mask, and exactly:

    * `trigger/3` touches only its own channel, so the order between channels is
      not observable;
    * triggering one channel twice in a frame is the same as triggering it once.
      Every field is recomputed from registers that do not change in between,
      and the one conditional field -- `length: if(ch.length == 0, ...)` -- is
      reloaded to `64 - (nrx1 &&& 0x3F)`, which is 1..64 and never zero, so the
      second application finds a non-zero length and keeps it. Which is what the
      first application would have done anyway.

  So the seam sets a bit and this module reads four. What it does **not** get to
  do is apply the trigger at write time: a trigger reads NRx1, NRx2 and the
  frequency registers *when it is applied*, and a game that writes its length
  after the trigger byte would then be read too early.

  ## What is not modelled

  The mixer `Atomboy.APU` folds in from `ram[:mixer]` -- the in-game menu's
  master volume and per-voice mutes -- has no meaning on a console with no menu.
  Volume is 100 and every voice is on, which is what the Elixir side defaults to
  when the key is absent, so the two agree without the multipliers ever being
  divided by anything.
  """

  alias Atomboy.Native.Asm
  alias Atomboy.Native.Regs
  alias Atomboy.Native.RV32

  @clock 4_194_304
  @sample_rate 32_768
  @cycles_per_sample div(@clock, @sample_rate)
  @frame_cycles 70_224
  @seq_period 8192

  # `Atomboy.APU`'s duty tuples, flattened: four cycles of eight steps, one byte
  # each, so a duty is a base address and a step is an index.
  @duty [
    [0, 0, 0, 0, 0, 0, 0, 1],
    [1, 0, 0, 0, 0, 0, 0, 1],
    [1, 0, 0, 0, 0, 1, 1, 1],
    [0, 1, 1, 1, 1, 1, 1, 0]
  ]

  # NR32's volume codes, as right shifts: mute, 100%, 50%, 25%. Mute is a shift
  # of four, which takes a four-bit sample to zero -- `Atomboy.APU` spells it the
  # same way, and for the same reason: a shift is not a branch.
  @wave_shifts [4, 0, 1, 2]

  # ── One channel's 32 bytes ──────────────────────────────────────────────────
  #
  # The pulses use all of it. The wave uses the first four words. The noise puts
  # its LFSR in the last, where a pulse keeps its sweep shadow, and never touches
  # `pos` or `sweep`.
  @ch_enabled 0
  @ch_timer 4
  @ch_pos 8
  @ch_length 12
  @ch_volume 16
  @ch_env 20
  @ch_sweep 24
  @ch_extra 28
  @ch_size 32

  # Four blocks of the same shape, then what belongs to no channel. Derived from
  # @ch_size rather than written out, so widening a channel moves everything
  # after it instead of silently overlapping it.
  @st_ch1 0
  @st_ch2 @ch_size
  @st_ch3 2 * @ch_size
  @st_ch4 3 * @ch_size
  @st_seq_acc 4 * @ch_size
  @st_seq_step 4 * @ch_size + 4
  @st_sample_acc 4 * @ch_size + 8
  @st_triggers 4 * @ch_size + 12
  @st_size 4 * @ch_size + 16

  # ── What one frame freezes ──────────────────────────────────────────────────
  #
  # `Atomboy.APU.config/1`, as words. Everything the inner loop needs is read
  # once here and never looked up again -- the Elixir side made that the
  # condition for its 16.7 ms budget, and it is the same condition here.
  #
  # Every field used as a gate is stored as 0 or -1 rather than 0 or 1, so a
  # test that reads `if(cfg.l1, do: v1, else: 0)` in Elixir is one `and` here.
  @cf_p1 0
  @cf_p2 4
  @cf_p3 8
  @cf_p4 12
  @cf_duty1 16
  @cf_duty2 20
  @cf_dac1 24
  @cf_dac2 28
  @cf_dac3 32
  @cf_dac4 36
  @cf_shift3 40
  @cf_narrow4 44
  @cf_len1 48
  @cf_len2 52
  @cf_len3 56
  @cf_len4 60
  @cf_env1 64
  @cf_env2 68
  @cf_env4 72
  @cf_nr10 76
  @cf_sweep 80
  @cf_lmul 84
  @cf_rmul 88
  @cf_l1 92
  @cf_l2 96
  @cf_l3 100
  @cf_l4 104
  @cf_r1 108
  @cf_r2 112
  @cf_r3 116
  @cf_r4 120
  @cf_table3 124
  @cf_size 156

  @io 0xFF00

  # The registers the routine saves: `ra` because it calls its own helpers, the
  # four argument registers because they are both the helpers' arguments and
  # SM83 carriers, and every `s` because the working set does not fit elsewhere.
  @saved [:ra, :a1, :a2, :a3, :a4] ++
           for(i <- 0..11, do: :"s#{i}")

  # 17 words, rounded up to a multiple of 16 for the ABI's stack alignment.
  @frame 80

  @doc "The sample rate the generated code produces -- `Atomboy.APU.sample_rate/0`."
  @spec sample_rate() :: 32_768
  def sample_rate, do: @sample_rate

  @doc "The T-cycles one sample is worth."
  @spec cycles_per_sample() :: 128
  def cycles_per_sample, do: @cycles_per_sample

  @doc """
  The most samples one frame can ask for.

  70,224 cycles over 128 is 548.625, so a frame is 548 samples and sometimes 549
  once the carried fraction has accumulated. Callers sizing a buffer want the
  ceiling, not the mean.
  """
  @spec max_samples() :: 549
  def max_samples, do: div(@frame_cycles + @cycles_per_sample - 1, @cycles_per_sample)

  @doc "The bytes one frame of samples can take -- stereo, two bytes a side."
  @spec max_bytes() :: 2196
  def max_bytes, do: max_samples() * 4

  @doc "The entry that generates a whole frame's worth, count and all."
  @spec label() :: :apu_frame
  def label, do: :apu_frame

  @doc "The entry that generates exactly the count handed in `a0`."
  @spec samples_label() :: :apu_samples
  def samples_label, do: :apu_samples

  @doc "The state block's size in bytes, and the offsets a caller may seed or read."
  @spec state_bytes() :: 144
  def state_bytes, do: @st_size

  @doc """
  Where each field of the state block lives, for a caller seeding one.

  Channels are `:ch1`-`:ch4`, each a byte offset to a 32-byte block whose own
  fields are `:enabled`, `:timer`, `:pos`, `:length`, `:volume`, `:env`,
  `:sweep` and `:extra` -- the last being the sweep shadow on channel 1 and the
  LFSR on channel 4.
  """
  @spec offsets() :: %{atom() => non_neg_integer()}
  def offsets do
    %{
      ch1: @st_ch1,
      ch2: @st_ch2,
      ch3: @st_ch3,
      ch4: @st_ch4,
      seq_acc: @st_seq_acc,
      seq_step: @st_seq_step,
      sample_acc: @st_sample_acc,
      triggers: @st_triggers,
      enabled: @ch_enabled,
      timer: @ch_timer,
      pos: @ch_pos,
      length: @ch_length,
      volume: @ch_volume,
      env: @ch_env,
      sweep: @ch_sweep,
      extra: @ch_extra
    }
  end

  @doc """
  Every routine, to be placed once in an image.

  Like `Atomboy.Native.PPU.routines/0`, they cost only their size: nothing runs
  unless `:apu_frame` or `:apu_samples` is called.
  """
  @spec routines() :: [Asm.item()]
  def routines do
    [
      frame(),
      samples(),
      config(),
      generate(),
      apply_triggers(),
      trigger_pulse(),
      clock_length(),
      clock_env(),
      clock_sweep(),
      advance(),
      advance_noise()
    ]
  end

  @doc """
  The state and scratch the routines need, in an image's **data** section.

  The duty cycles are constants and could sit among the code; they are here
  because everything the routine addresses with `la` is here, and one rule about
  where data lives is easier to keep than two.
  """
  @spec data() :: [Asm.item()]
  def data do
    [
      {:align, 4},
      Asm.label(:apu_state),
      {:space, @st_size},
      Asm.label(:apu_config),
      {:space, @cf_size},
      Asm.label(:apu_duty),
      @duty |> List.flatten() |> :binary.list_to_bin(),
      {:align, 4},
      Asm.label(:apu_wave_shifts),
      @wave_shifts |> Enum.map(&<<&1::32-little>>) |> IO.iodata_to_binary()
    ]
  end

  # ══ A frame's worth ══════════════════════════════════════════════════════════
  #
  # `Atomboy.APU.frame/2`: 70,224 cycles plus what the last frame carried, over
  # 128. The remainder carries forward, which is what keeps the sample clock from
  # drifting against the frame clock over a run of any length.

  defp frame do
    [
      Asm.label(:apu_frame),
      Asm.la(:t1, :apu_state),
      RV32.lw(:t2, :t1, @st_sample_acc),
      RV32.li(:t3, @frame_cycles),
      RV32.add(:t2, :t2, :t3),
      RV32.srli(:a0, :t2, 7),
      RV32.andi(:t2, :t2, @cycles_per_sample - 1),
      RV32.sw(:t2, :t1, @st_sample_acc),
      Asm.j(:apu_samples)
    ]
  end

  # ══ Exactly the count asked for ══════════════════════════════════════════════
  #
  # `Atomboy.APU.samples/3`, clause for clause: the triggers are consumed first
  # and consumed even when no samples are wanted; a count of zero writes nothing;
  # an APU switched off at NR52 writes silence rather than skipping, because the
  # caller asked for that many samples and a short buffer is a different bug.

  defp samples do
    [
      Asm.label(:apu_samples),
      RV32.addi(:sp, :sp, -@frame),
      @saved |> Enum.with_index() |> Enum.map(fn {reg, i} -> RV32.sw(reg, :sp, 4 * i) end),
      RV32.mv(:s2, :t0),
      RV32.mv(:s3, :a0),
      Asm.la(:s1, :apu_state),
      Asm.la(:s0, :apu_config),
      Asm.call(:apu_apply_triggers),

      # A count of zero, or one that a caller made negative: nothing to write.
      RV32.li(:t0, 0),
      Asm.bge(:t0, :s3, :apu_done),

      # NR52 bit 7: the APU is powered. Off, every sample is a silent one.
      RV32.li(:t0, @io + 0x26),
      RV32.add(:t0, Regs.mem(), :t0),
      RV32.lbu(:t0, :t0, 0),
      RV32.andi(:t0, :t0, 0x80),
      Asm.bnez(:t0, :apu_powered),
      Asm.label(:apu_silence),
      RV32.sh(:zero, :s2, 0),
      RV32.sh(:zero, :s2, 2),
      RV32.addi(:s2, :s2, 4),
      RV32.addi(:s3, :s3, -1),
      Asm.bnez(:s3, :apu_silence),
      Asm.j(:apu_done),
      Asm.label(:apu_powered),
      Asm.call(:apu_freeze),
      Asm.call(:apu_generate),
      Asm.label(:apu_done),
      @saved |> Enum.with_index() |> Enum.map(fn {reg, i} -> RV32.lw(reg, :sp, 4 * i) end),
      RV32.addi(:sp, :sp, @frame),
      RV32.ret()
    ]
  end

  # ══ The triggers ═════════════════════════════════════════════════════════════
  #
  # Four bits, applied low to high, then cleared. See the moduledoc on why a mask
  # is enough where Elixir keeps a list.

  # This routine calls another, so `ra` is not its to keep. It stashes it in
  # `s11` and returns through that instead -- affordable because `apu_samples`
  # owns the frame and has already saved every `s` register, and because nothing
  # here is ever reached from anywhere else. `apu_generate` does the same.
  defp apply_triggers do
    [
      Asm.label(:apu_apply_triggers),
      RV32.mv(:s11, :ra),
      RV32.lw(:t0, :s1, @st_triggers),
      Asm.beqz(:t0, :apu_triggers_done),
      RV32.sw(:zero, :s1, @st_triggers),
      RV32.mv(:s10, :t0),

      # Channel 1: the only one with a sweep, so the only one handed an NR10.
      RV32.andi(:t0, :s10, 0x01),
      Asm.beqz(:t0, :apu_trigger_2),
      RV32.addi(:a0, :s1, @st_ch1),
      RV32.li(:a1, @io + 0x11),
      RV32.li(:a2, @io + 0x13),
      RV32.li(:a3, @io + 0x10),
      Asm.call(:apu_trigger_pulse),
      Asm.label(:apu_trigger_2),
      RV32.andi(:t0, :s10, 0x02),
      Asm.beqz(:t0, :apu_trigger_3),
      RV32.addi(:a0, :s1, @st_ch2),
      RV32.li(:a1, @io + 0x16),
      RV32.li(:a2, @io + 0x18),
      RV32.li(:a3, 0),
      Asm.call(:apu_trigger_pulse),

      # Channel 3, the wave: no envelope and no volume of its own -- NR30's bit 7
      # is the whole of its DAC, and its length counts to 256 rather than 64.
      Asm.label(:apu_trigger_3),
      RV32.andi(:t0, :s10, 0x04),
      Asm.beqz(:t0, :apu_trigger_4),
      RV32.addi(:t1, :s1, @st_ch3),
      RV32.li(:t2, @io + 0x1A),
      RV32.add(:t2, Regs.mem(), :t2),
      RV32.lbu(:t3, :t2, 0),
      RV32.andi(:t3, :t3, 0x80),
      RV32.sltu(:t3, :zero, :t3),
      RV32.sub(:t3, :zero, :t3),
      RV32.sw(:t3, :t1, @ch_enabled),
      RV32.lw(:t4, :t1, @ch_length),
      Asm.bnez(:t4, :apu_trigger_3_kept),
      RV32.lbu(:t5, :t2, 0x1B - 0x1A),
      RV32.li(:t6, 256),
      RV32.sub(:t5, :t6, :t5),
      RV32.sw(:t5, :t1, @ch_length),
      Asm.label(:apu_trigger_3_kept),
      RV32.sw(:zero, :t1, @ch_pos),
      RV32.sw(:zero, :t1, @ch_timer),

      # Channel 4, the noise: an envelope like a pulse, no frequency, and an LFSR
      # that starts full of ones.
      Asm.label(:apu_trigger_4),
      RV32.andi(:t0, :s10, 0x08),
      Asm.beqz(:t0, :apu_triggers_done),
      RV32.addi(:t1, :s1, @st_ch4),
      RV32.li(:t2, @io + 0x21),
      RV32.add(:t2, Regs.mem(), :t2),
      RV32.lbu(:t3, :t2, 0),
      RV32.andi(:t4, :t3, 0xF8),
      RV32.sltu(:t4, :zero, :t4),
      RV32.sub(:t4, :zero, :t4),
      RV32.sw(:t4, :t1, @ch_enabled),
      RV32.srli(:t5, :t3, 4),
      RV32.sw(:t5, :t1, @ch_volume),
      RV32.andi(:t5, :t3, 0x07),
      RV32.sw(:t5, :t1, @ch_env),
      RV32.li(:t5, 0x7FFF),
      RV32.sw(:t5, :t1, @ch_extra),
      RV32.sw(:zero, :t1, @ch_timer),
      RV32.lw(:t4, :t1, @ch_length),
      Asm.bnez(:t4, :apu_triggers_done),
      RV32.lbu(:t5, :t2, 0x20 - 0x21),
      RV32.andi(:t5, :t5, 0x3F),
      RV32.li(:t6, 64),
      RV32.sub(:t5, :t6, :t5),
      RV32.sw(:t5, :t1, @ch_length),
      Asm.label(:apu_triggers_done),
      RV32.jr(:s11)
    ]
  end

  # `Atomboy.APU.trigger_pulse/6`.
  #
  #     a0  the channel block
  #     a1  NRx1's absolute address -- NRx2 is the byte after it
  #     a2  NRx3's absolute address -- NRx4 is the byte after it
  #     a3  NR10's absolute address, or zero on the channel without a sweep
  defp trigger_pulse do
    [
      Asm.label(:apu_trigger_pulse),
      RV32.add(:t0, Regs.mem(), :a1),
      RV32.lbu(:t1, :t0, 1),

      # The DAC: bits 7-3 of NRx2. All zero and the channel is mute however hard
      # it is triggered, which is how a game cuts a voice.
      RV32.andi(:t2, :t1, 0xF8),
      RV32.sltu(:t2, :zero, :t2),
      RV32.sub(:t2, :zero, :t2),
      RV32.sw(:t2, :a0, @ch_enabled),
      RV32.srli(:t2, :t1, 4),
      RV32.sw(:t2, :a0, @ch_volume),
      RV32.andi(:t2, :t1, 0x07),
      RV32.sw(:t2, :a0, @ch_env),
      RV32.sw(:zero, :a0, @ch_timer),

      # The frequency shadow, which the sweep then slides.
      RV32.add(:t3, Regs.mem(), :a2),
      RV32.lbu(:t4, :t3, 0),
      RV32.lbu(:t5, :t3, 1),
      RV32.andi(:t5, :t5, 0x07),
      RV32.slli(:t5, :t5, 8),
      RV32.or_(:t4, :t4, :t5),
      RV32.sw(:t4, :a0, @ch_extra),

      # The sweep timer, and `max(period, 1)`: a period of zero would reload the
      # timer to zero and step it every clock.
      RV32.sw(:zero, :a0, @ch_sweep),
      Asm.beqz(:a3, :apu_trigger_length),
      RV32.add(:t0, Regs.mem(), :a3),
      RV32.lbu(:t1, :t0, 0),
      RV32.srli(:t1, :t1, 4),
      RV32.andi(:t1, :t1, 0x07),
      Asm.bnez(:t1, :apu_trigger_sweep),
      RV32.li(:t1, 1),
      Asm.label(:apu_trigger_sweep),
      RV32.sw(:t1, :a0, @ch_sweep),

      # The length reloads only from zero: a channel still counting keeps what it
      # has, which is how a re-trigger inside a note does not restart it.
      Asm.label(:apu_trigger_length),
      RV32.lw(:t0, :a0, @ch_length),
      Asm.bnez(:t0, :apu_trigger_pulse_done),
      RV32.add(:t0, Regs.mem(), :a1),
      RV32.lbu(:t1, :t0, 0),
      RV32.andi(:t1, :t1, 0x3F),
      RV32.li(:t2, 64),
      RV32.sub(:t1, :t2, :t1),
      RV32.sw(:t1, :a0, @ch_length),
      Asm.label(:apu_trigger_pulse_done),
      RV32.ret()
    ]
  end

  # ══ What a frame freezes ═════════════════════════════════════════════════════
  #
  # `Atomboy.APU.config/1`. Read once, so that 549 turns of the inner loop never
  # touch the 64 KB again.

  defp config do
    [
      Asm.label(:apu_freeze),
      RV32.li(:t0, @io),
      RV32.add(:t0, Regs.mem(), :t0),

      # The two pulse periods: (2048 - f) x 4 cycles a duty step.
      period(0x13, 4, @cf_p1),
      period(0x18, 4, @cf_p2),
      # The wave steps twice as often for the same frequency: x 2, not x 4.
      period(0x1D, 2, @cf_p3),

      # The duty: NRx1's top two bits choose one of four eight-step cycles.
      RV32.lbu(:t1, :t0, 0x11),
      RV32.srli(:t1, :t1, 6),
      RV32.slli(:t1, :t1, 3),
      Asm.la(:t2, :apu_duty),
      RV32.add(:t1, :t2, :t1),
      RV32.sw(:t1, :s0, @cf_duty1),
      RV32.lbu(:t1, :t0, 0x16),
      RV32.srli(:t1, :t1, 6),
      RV32.slli(:t1, :t1, 3),
      RV32.add(:t1, :t2, :t1),
      RV32.sw(:t1, :s0, @cf_duty2),

      # The envelope bytes travel whole: the sequencer reads their period and
      # direction out of them 64 times a second.
      RV32.lbu(:t1, :t0, 0x12),
      RV32.sw(:t1, :s0, @cf_env1),
      dac(:t1, @cf_dac1),
      RV32.lbu(:t1, :t0, 0x17),
      RV32.sw(:t1, :s0, @cf_env2),
      dac(:t1, @cf_dac2),
      RV32.lbu(:t1, :t0, 0x21),
      RV32.sw(:t1, :s0, @cf_env4),
      dac(:t1, @cf_dac4),

      # The wave's DAC is a single bit of NR30, not five of an envelope.
      RV32.lbu(:t1, :t0, 0x1A),
      mask_bit(:t1, 0x80),
      RV32.sw(:t1, :s0, @cf_dac3),

      # NR32's two volume bits, as the right shift they amount to.
      RV32.lbu(:t1, :t0, 0x1C),
      RV32.srli(:t1, :t1, 5),
      RV32.andi(:t1, :t1, 0x03),
      RV32.slli(:t1, :t1, 2),
      Asm.la(:t2, :apu_wave_shifts),
      RV32.add(:t1, :t2, :t1),
      RV32.lw(:t1, :t1, 0),
      RV32.sw(:t1, :s0, @cf_shift3),

      # NR10: kept whole for the sweep, plus the one question the inner loop asks
      # of it -- whether a sweep is running at all, which decides whether channel
      # one's period is the register's or the shadow's.
      RV32.lbu(:t1, :t0, 0x10),
      RV32.sw(:t1, :s0, @cf_nr10),
      mask_bit(:t1, 0x77),
      RV32.sw(:t1, :s0, @cf_sweep),

      # NR43: the noise divisor, its shift, and the narrow LFSR.
      RV32.lbu(:t1, :t0, 0x22),
      RV32.andi(:t2, :t1, 0x07),
      Asm.bnez(:t2, :apu_freeze_divisor),
      RV32.li(:t2, 8),
      Asm.j(:apu_freeze_shift),
      Asm.label(:apu_freeze_divisor),
      RV32.slli(:t2, :t2, 4),
      Asm.label(:apu_freeze_shift),
      RV32.srli(:t3, :t1, 4),
      RV32.andi(:t3, :t3, 0x0F),
      RV32.sll(:t2, :t2, :t3),
      RV32.sw(:t2, :s0, @cf_p4),
      mask_bit(:t1, 0x08),
      RV32.sw(:t1, :s0, @cf_narrow4),

      # The four length switches, NRx4 bit 6.
      length_switch(0x14, @cf_len1),
      length_switch(0x19, @cf_len2),
      length_switch(0x1E, @cf_len3),
      length_switch(0x23, @cf_len4),

      # NR50, both sides. `Atomboy.APU` scales by a master volume out of the menu
      # and divides by a hundred; there is no menu here, the volume is a hundred,
      # and the division cancels.
      RV32.lbu(:t1, :t0, 0x24),
      RV32.srli(:t2, :t1, 4),
      RV32.andi(:t2, :t2, 0x07),
      RV32.addi(:t2, :t2, 1),
      RV32.li(:t3, 60),
      RV32.mul(:t2, :t2, :t3),
      RV32.sw(:t2, :s0, @cf_lmul),
      RV32.andi(:t2, :t1, 0x07),
      RV32.addi(:t2, :t2, 1),
      RV32.mul(:t2, :t2, :t3),
      RV32.sw(:t2, :s0, @cf_rmul),

      # NR51 routes each channel to each ear.
      RV32.lbu(:t1, :t0, 0x25),
      routing(:t1, 0x10, @cf_l1),
      routing(:t1, 0x20, @cf_l2),
      routing(:t1, 0x40, @cf_l3),
      routing(:t1, 0x80, @cf_l4),
      routing(:t1, 0x01, @cf_r1),
      routing(:t1, 0x02, @cf_r2),
      routing(:t1, 0x04, @cf_r3),
      routing(:t1, 0x08, @cf_r4),

      # The wave table: sixteen bytes into thirty-two nibbles, high first.
      RV32.addi(:t1, :t0, 0x30),
      RV32.addi(:t2, :s0, @cf_table3),
      RV32.addi(:t3, :t1, 16),
      Asm.label(:apu_freeze_wave),
      RV32.lbu(:t4, :t1, 0),
      RV32.srli(:t5, :t4, 4),
      RV32.sb(:t5, :t2, 0),
      RV32.andi(:t5, :t4, 0x0F),
      RV32.sb(:t5, :t2, 1),
      RV32.addi(:t1, :t1, 1),
      RV32.addi(:t2, :t2, 2),
      Asm.bne(:t1, :t3, :apu_freeze_wave),
      RV32.ret()
    ]
  end

  # (2048 - f) times `scale`: the cycles one step of the channel's wave costs.
  # Both scales are powers of two, so the multiply is a shift.
  defp period(nrx3, scale, slot) when scale in [2, 4] do
    [
      RV32.lbu(:t1, :t0, nrx3),
      RV32.lbu(:t2, :t0, nrx3 + 1),
      RV32.andi(:t2, :t2, 0x07),
      RV32.slli(:t2, :t2, 8),
      RV32.or_(:t1, :t1, :t2),
      RV32.li(:t2, 2048),
      RV32.sub(:t1, :t2, :t1),
      RV32.slli(:t1, :t1, if(scale == 4, do: 2, else: 1)),
      RV32.sw(:t1, :s0, slot)
    ]
  end

  defp dac(reg, slot) do
    [
      RV32.andi(:t2, reg, 0xF8),
      RV32.sltu(:t2, :zero, :t2),
      RV32.sub(:t2, :zero, :t2),
      RV32.sw(:t2, :s0, slot)
    ]
  end

  defp length_switch(nrx4, slot) do
    [
      RV32.lbu(:t1, :t0, nrx4),
      mask_bit(:t1, 0x40),
      RV32.sw(:t1, :s0, slot)
    ]
  end

  defp routing(reg, bit, slot) do
    [
      RV32.andi(:t2, reg, bit),
      RV32.sltu(:t2, :zero, :t2),
      RV32.sub(:t2, :zero, :t2),
      RV32.sw(:t2, :s0, slot)
    ]
  end

  # `(reg &&& bits) != 0`, as 0 or -1 -- a gate the inner loop spends one `and`
  # on instead of a branch.
  defp mask_bit(reg, bits) do
    [
      RV32.andi(reg, reg, bits),
      RV32.sltu(reg, :zero, reg),
      RV32.sub(reg, :zero, reg)
    ]
  end

  # ══ The sample loop ══════════════════════════════════════════════════════════
  #
  #   s0  the frozen config      s3  samples left to write
  #   s1  the state block        s4  the sequencer's accumulator
  #   s2  the destination        s5  the sequencer's step, 0..7

  defp generate do
    [
      Asm.label(:apu_generate),
      RV32.mv(:s11, :ra),
      RV32.lw(:s4, :s1, @st_seq_acc),
      RV32.lw(:s5, :s1, @st_seq_step),
      Asm.label(:apu_sample),

      # ── The frame sequencer, once every 8192 cycles ──────────────────────────
      RV32.addi(:t0, :s4, @cycles_per_sample),
      RV32.li(:t1, @seq_period),
      Asm.blt(:t0, :t1, :apu_no_step),
      RV32.sub(:s4, :t0, :t1),
      RV32.addi(:s5, :s5, 1),
      RV32.andi(:s5, :s5, 0x07),

      # Length at 256 Hz -- the even steps.
      RV32.andi(:t0, :s5, 0x01),
      Asm.bnez(:t0, :apu_no_length),
      RV32.addi(:a0, :s1, @st_ch1),
      RV32.lw(:a1, :s0, @cf_len1),
      Asm.call(:apu_clock_length),
      RV32.addi(:a0, :s1, @st_ch2),
      RV32.lw(:a1, :s0, @cf_len2),
      Asm.call(:apu_clock_length),
      RV32.addi(:a0, :s1, @st_ch3),
      RV32.lw(:a1, :s0, @cf_len3),
      Asm.call(:apu_clock_length),
      RV32.addi(:a0, :s1, @st_ch4),
      RV32.lw(:a1, :s0, @cf_len4),
      Asm.call(:apu_clock_length),
      Asm.label(:apu_no_length),

      # Sweep at 128 Hz -- steps 2 and 6, channel one alone.
      RV32.andi(:t0, :s5, 0x03),
      RV32.li(:t1, 2),
      Asm.bne(:t0, :t1, :apu_no_sweep),
      RV32.addi(:a0, :s1, @st_ch1),
      RV32.lw(:a1, :s0, @cf_nr10),
      Asm.call(:apu_clock_sweep),
      Asm.label(:apu_no_sweep),

      # Envelope at 64 Hz -- step 7, the three channels that have one.
      RV32.li(:t1, 7),
      Asm.bne(:s5, :t1, :apu_no_env),
      RV32.addi(:a0, :s1, @st_ch1),
      RV32.lw(:a1, :s0, @cf_env1),
      Asm.call(:apu_clock_env),
      RV32.addi(:a0, :s1, @st_ch2),
      RV32.lw(:a1, :s0, @cf_env2),
      Asm.call(:apu_clock_env),
      RV32.addi(:a0, :s1, @st_ch4),
      RV32.lw(:a1, :s0, @cf_env4),
      Asm.call(:apu_clock_env),
      Asm.label(:apu_no_env),
      Asm.j(:apu_stepped),
      Asm.label(:apu_no_step),
      RV32.mv(:s4, :t0),
      Asm.label(:apu_stepped),

      # ── The four channels advance ────────────────────────────────────────────
      #
      # Channel one under a running sweep takes its period from the shadow the
      # sweep slides, not from the register the game wrote.
      RV32.addi(:a0, :s1, @st_ch1),
      RV32.lw(:t0, :s0, @cf_sweep),
      Asm.beqz(:t0, :apu_ch1_fixed),
      RV32.lw(:a1, :a0, @ch_extra),
      RV32.li(:t1, 2048),
      RV32.sub(:a1, :t1, :a1),
      RV32.slli(:a1, :a1, 2),
      Asm.j(:apu_ch1_go),
      Asm.label(:apu_ch1_fixed),
      RV32.lw(:a1, :s0, @cf_p1),
      Asm.label(:apu_ch1_go),
      RV32.li(:a2, 0x07),
      Asm.call(:apu_advance),
      RV32.addi(:a0, :s1, @st_ch2),
      RV32.lw(:a1, :s0, @cf_p2),
      RV32.li(:a2, 0x07),
      Asm.call(:apu_advance),
      RV32.addi(:a0, :s1, @st_ch3),
      RV32.lw(:a1, :s0, @cf_p3),
      RV32.li(:a2, 0x1F),
      Asm.call(:apu_advance),
      RV32.addi(:a0, :s1, @st_ch4),
      RV32.lw(:a1, :s0, @cf_p4),
      RV32.lw(:a2, :s0, @cf_narrow4),
      Asm.call(:apu_advance_noise),

      # ── What each channel is putting out ─────────────────────────────────────
      #
      # s6-s9 carry the four amplitudes into the mix.
      pulse_output(@st_ch1, @cf_duty1, @cf_dac1, :s6),
      pulse_output(@st_ch2, @cf_duty2, @cf_dac2, :s7),

      # The wave reads its table rather than a duty, and shifts rather than
      # multiplies: its sample *is* its amplitude.
      RV32.addi(:t0, :s1, @st_ch3),
      RV32.lw(:t1, :t0, @ch_pos),
      RV32.addi(:t2, :s0, @cf_table3),
      RV32.add(:t1, :t2, :t1),
      RV32.lbu(:s8, :t1, 0),
      RV32.lw(:t1, :s0, @cf_shift3),
      RV32.srl(:s8, :s8, :t1),
      RV32.lw(:t1, :t0, @ch_enabled),
      RV32.and_(:s8, :s8, :t1),
      RV32.lw(:t1, :s0, @cf_dac3),
      RV32.and_(:s8, :s8, :t1),

      # The noise: the LFSR's low bit, inverted, gated by the volume.
      RV32.addi(:t0, :s1, @st_ch4),
      RV32.lw(:t1, :t0, @ch_extra),
      RV32.xori(:t1, :t1, 0x01),
      RV32.andi(:t1, :t1, 0x01),
      RV32.sub(:t1, :zero, :t1),
      RV32.lw(:s9, :t0, @ch_volume),
      RV32.and_(:s9, :s9, :t1),
      RV32.lw(:t1, :t0, @ch_enabled),
      RV32.and_(:s9, :s9, :t1),
      RV32.lw(:t1, :s0, @cf_dac4),
      RV32.and_(:s9, :s9, :t1),

      # ── The mix ──────────────────────────────────────────────────────────────
      #
      # Worst case: volume 15, four channels, NR50 at seven, times sixty --
      # 28,800, inside the s16 by a comfortable margin. The store truncates to
      # sixteen bits little-endian, which is what the format is.
      side(@cf_l1, @cf_l2, @cf_l3, @cf_l4, @cf_lmul, 0),
      side(@cf_r1, @cf_r2, @cf_r3, @cf_r4, @cf_rmul, 2),
      RV32.addi(:s2, :s2, 4),
      RV32.addi(:s3, :s3, -1),
      Asm.bnez(:s3, :apu_sample),
      RV32.sw(:s4, :s1, @st_seq_acc),
      RV32.sw(:s5, :s1, @st_seq_step),
      RV32.jr(:s11)
    ]
  end

  defp pulse_output(channel, duty_slot, dac_slot, dest) do
    [
      RV32.addi(:t0, :s1, channel),
      RV32.lw(:t1, :t0, @ch_pos),
      RV32.lw(:t2, :s0, duty_slot),
      RV32.add(:t1, :t2, :t1),
      RV32.lbu(:t1, :t1, 0),
      RV32.sub(:t1, :zero, :t1),
      RV32.lw(dest, :t0, @ch_volume),
      RV32.and_(dest, dest, :t1),
      RV32.lw(:t1, :t0, @ch_enabled),
      RV32.and_(dest, dest, :t1),
      RV32.lw(:t1, :s0, dac_slot),
      RV32.and_(dest, dest, :t1)
    ]
  end

  defp side(g1, g2, g3, g4, mul, offset) do
    [
      RV32.lw(:t1, :s0, g1),
      RV32.and_(:t0, :s6, :t1),
      RV32.lw(:t1, :s0, g2),
      RV32.and_(:t1, :s7, :t1),
      RV32.add(:t0, :t0, :t1),
      RV32.lw(:t1, :s0, g3),
      RV32.and_(:t1, :s8, :t1),
      RV32.add(:t0, :t0, :t1),
      RV32.lw(:t1, :s0, g4),
      RV32.and_(:t1, :s9, :t1),
      RV32.add(:t0, :t0, :t1),
      RV32.lw(:t1, :s0, mul),
      RV32.mul(:t0, :t0, :t1),
      RV32.sh(:t0, :s2, offset)
    ]
  end

  # ══ The sequencer's three clocks ═════════════════════════════════════════════

  # `Atomboy.APU.clock_length/3`. The channel dies when the counter reaches zero
  # and not before -- and only if it was alive, which is why the store is
  # conditional rather than a mask.
  defp clock_length do
    [
      Asm.label(:apu_clock_length),
      Asm.beqz(:a1, :apu_length_done),
      RV32.lw(:t0, :a0, @ch_length),
      RV32.li(:t1, 0),
      Asm.bge(:t1, :t0, :apu_length_done),
      RV32.addi(:t0, :t0, -1),
      RV32.sw(:t0, :a0, @ch_length),
      Asm.bnez(:t0, :apu_length_done),
      RV32.sw(:zero, :a0, @ch_enabled),
      Asm.label(:apu_length_done),
      RV32.ret()
    ]
  end

  # `Atomboy.APU.clock_env/3`.
  #
  # The timer is decremented and compared to zero, not to one: a channel
  # triggered with an envelope period of zero starts its timer at zero and walks
  # negative from there, and the Elixir side -- which is the oracle -- walks
  # negative with it. Reproducing the arithmetic reproduces the silence.
  defp clock_env do
    [
      Asm.label(:apu_clock_env),
      RV32.andi(:t0, :a1, 0x07),
      Asm.beqz(:t0, :apu_env_done),
      RV32.lw(:t1, :a0, @ch_env),
      RV32.addi(:t1, :t1, -1),
      Asm.bnez(:t1, :apu_env_tick),
      RV32.lw(:t2, :a0, @ch_volume),
      RV32.andi(:t3, :a1, 0x08),
      Asm.beqz(:t3, :apu_env_down),
      RV32.li(:t3, 15),
      Asm.bge(:t2, :t3, :apu_env_store),
      RV32.addi(:t2, :t2, 1),
      Asm.j(:apu_env_store),
      Asm.label(:apu_env_down),
      Asm.beqz(:t2, :apu_env_store),
      RV32.addi(:t2, :t2, -1),
      Asm.label(:apu_env_store),
      RV32.sw(:t2, :a0, @ch_volume),
      RV32.sw(:t0, :a0, @ch_env),
      RV32.ret(),
      Asm.label(:apu_env_tick),
      RV32.sw(:t1, :a0, @ch_env),
      Asm.label(:apu_env_done),
      RV32.ret()
    ]
  end

  # `Atomboy.APU.clock_sweep/3`. The overflow at 2047 silences the channel and
  # leaves the shadow alone, which is what keeps the recomputed period positive.
  defp clock_sweep do
    [
      Asm.label(:apu_clock_sweep),
      RV32.srli(:t0, :a1, 4),
      RV32.andi(:t0, :t0, 0x07),
      Asm.beqz(:t0, :apu_sweep_done),
      RV32.lw(:t1, :a0, @ch_sweep),
      RV32.addi(:t1, :t1, -1),
      Asm.bnez(:t1, :apu_sweep_tick),
      RV32.andi(:t2, :a1, 0x07),
      RV32.lw(:t3, :a0, @ch_extra),
      RV32.srl(:t4, :t3, :t2),
      RV32.andi(:t5, :a1, 0x08),
      Asm.beqz(:t5, :apu_sweep_up),
      RV32.sub(:t4, :t3, :t4),
      Asm.j(:apu_sweep_check),
      Asm.label(:apu_sweep_up),
      RV32.add(:t4, :t3, :t4),
      Asm.label(:apu_sweep_check),
      RV32.li(:t5, 2047),
      Asm.bge(:t5, :t4, :apu_sweep_ok),
      RV32.sw(:zero, :a0, @ch_enabled),
      Asm.j(:apu_sweep_reload),
      Asm.label(:apu_sweep_ok),
      Asm.beqz(:t2, :apu_sweep_reload),
      RV32.li(:t5, 0),
      Asm.bge(:t5, :t4, :apu_sweep_floor),
      RV32.mv(:t5, :t4),
      Asm.label(:apu_sweep_floor),
      RV32.sw(:t5, :a0, @ch_extra),
      Asm.label(:apu_sweep_reload),
      RV32.sw(:t0, :a0, @ch_sweep),
      RV32.ret(),
      Asm.label(:apu_sweep_tick),
      RV32.sw(:t1, :a0, @ch_sweep),
      Asm.label(:apu_sweep_done),
      RV32.ret()
    ]
  end

  # ══ Advancing a channel by one sample ════════════════════════════════════════

  # `Atomboy.APU.advance/2` and `advance_wave/2`, which differ only in how far
  # the position wraps -- eight duty steps against thirty-two table entries.
  #
  #     a0  the channel block
  #     a1  the period, in cycles a step
  #     a2  the position's wrap mask, 7 or 31
  defp advance do
    [
      Asm.label(:apu_advance),
      RV32.lw(:t0, :a0, @ch_enabled),
      Asm.beqz(:t0, :apu_advance_done),
      RV32.lw(:t0, :a0, @ch_timer),
      RV32.addi(:t0, :t0, @cycles_per_sample),
      RV32.divu(:t1, :t0, :a1),
      RV32.remu(:t0, :t0, :a1),
      RV32.sw(:t0, :a0, @ch_timer),
      RV32.lw(:t0, :a0, @ch_pos),
      RV32.add(:t0, :t0, :t1),
      RV32.and_(:t0, :t0, :a2),
      RV32.sw(:t0, :a0, @ch_pos),
      Asm.label(:apu_advance_done),
      RV32.ret()
    ]
  end

  # `Atomboy.APU.advance_noise/3`. The LFSR takes at most seventeen steps a
  # sample -- the divisor floors at eight cycles -- so the loop is bounded and
  # short enough to leave rolled.
  #
  #     a0  the channel block
  #     a1  the period
  #     a2  the narrow mask: 0, or -1 to feed bit 6 as well as bit 14
  defp advance_noise do
    [
      Asm.label(:apu_advance_noise),
      RV32.lw(:t0, :a0, @ch_enabled),
      Asm.beqz(:t0, :apu_noise_done),
      RV32.lw(:t0, :a0, @ch_timer),
      RV32.addi(:t0, :t0, @cycles_per_sample),
      RV32.divu(:t1, :t0, :a1),
      RV32.remu(:t0, :t0, :a1),
      RV32.sw(:t0, :a0, @ch_timer),
      Asm.beqz(:t1, :apu_noise_done),
      RV32.lw(:t2, :a0, @ch_extra),
      Asm.label(:apu_noise_step),
      RV32.srli(:t3, :t2, 1),
      RV32.xor_(:t4, :t2, :t3),
      RV32.andi(:t4, :t4, 0x01),
      RV32.slli(:t5, :t4, 14),
      RV32.or_(:t2, :t3, :t5),

      # Narrow mode copies the same bit into bit 6, which shortens the sequence
      # from 32,767 steps to 127 -- the metallic ring rather than the hiss.
      Asm.beqz(:a2, :apu_noise_next),
      RV32.li(:t5, -0x41),
      RV32.and_(:t2, :t2, :t5),
      RV32.slli(:t5, :t4, 6),
      RV32.or_(:t2, :t2, :t5),
      Asm.label(:apu_noise_next),
      RV32.addi(:t1, :t1, -1),
      Asm.bnez(:t1, :apu_noise_step),
      RV32.sw(:t2, :a0, @ch_extra),
      Asm.label(:apu_noise_done),
      RV32.ret()
    ]
  end
end
