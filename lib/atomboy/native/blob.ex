defmodule Atomboy.Native.Blob do
  @moduledoc """
  The same code, as a function somebody else calls.

  `Atomboy.Native.Image` builds something that *boots*: it takes the machine at
  reset, installs its own stack, talks to a 16550 UART and ends by asking
  `sifive_test` to hand control back. Every one of those is a fact about qemu's
  `virt` board and none of them is true of an ESP32-C6.

  On the chip nothing hands us the machine. An ESP-IDF application is already
  running -- it has a stack, a scheduler, a USB serial console and a panel -- and
  what it wants from us is a subroutine. So this module emits the same generated
  core with the boot removed and a calling convention put in its place:

      uint32_t entry(void *argument)   // a0 in, a0 out

  That is the whole seam. The C side owns every peripheral, which is also why
  there is no `putc` here: a blob that had to drive a UART would need to know
  which UART, and knowing that is exactly the coupling this shape exists to
  avoid.

  ## Why it can be loaded anywhere

  `Atomboy.Native.Asm.la/2` builds addresses with `auipc`, which is PC-relative:
  practically the whole core is already position-independent and would run
  wherever it was copied. The exception is `{:addr, _}` -- the two 256-word jump
  tables, which hold absolute handler addresses because that is what lets
  dispatch be one `lw` and one `jr`.

  So the blob is assembled at base **0**, making those entries offsets from its
  own first byte, and the entry sequence adds its actual load address to all 512
  of them before running anything. One pass over 2 KB, once per call into the
  blob at worst, against one extra instruction on every opcode dispatch had the
  tables been made relative instead. It also means the relocation is idempotent
  only once -- see `relocate/0`.

  ## What the caller must respect

  RISC-V's C ABI: `s0`-`s11` and `ra` belong to the caller and are saved and
  restored here, `t0`-`t6` and `a0`-`a7` do not and are not. The generated core
  keeps the SM83 state in `s` registers, and `gp` and `tp` hold the two memory
  bounds -- which is a liberty on a bare-metal image and a **hazard** in an
  ESP-IDF task, where the runtime may well be using them. They are saved and
  restored with the rest for that reason.
  """

  alias Atomboy.Native.Asm
  alias Atomboy.Native.RV32

  # Everything the C ABI says a callee must give back, plus the two the generated
  # core commandeers. `ra` first so the frame reads like the stack it is.
  @saved [:ra, :s0, :s1, :s2, :s3, :s4, :s5, :s6, :s7, :s8, :s9, :s10, :s11, :gp, :tp]
  @frame length(@saved) * 4

  @doc "The registers the blob saves and restores around the body."
  @spec saved() :: [RV32.reg()]
  def saved, do: @saved

  @doc """
  Assembles `code` and `data` into a callable, relocatable blob.

  `code` gets control with the caller's argument still in `a0`, and leaves by
  jumping to `return/0` with its result there. Falling off the end of `code` is
  not allowed: the data section follows it, and the processor would walk into it.
  """
  @spec build([Asm.item()], [Asm.item()], keyword()) :: Asm.assembled()
  def build(code, data \\ [], opts \\ []) do
    Asm.assemble(
      [
        Asm.label(:blob_start),
        entry(),
        if(Keyword.get(opts, :relocate, true), do: relocate(), else: []),
        code,
        exit_(),
        data
      ],
      0
    )
  end

  @doc """
  The smoke blob: it adds the first hundred integers and returns 5050.

  It emulates nothing, and its job is the one `Atomboy.Native.Image.smoke/0` had
  on qemu -- to settle the questions no datasheet settles for certain. Does a
  byte array copied into executable memory really run on this chip, does the
  calling convention hold across the boundary, does a value come back. 5050
  rather than a constant because a constant cannot tell a working blob from a
  register that happened to hold the right thing.
  """
  @spec smoke() :: Asm.assembled()
  def smoke do
    build(
      [
        RV32.li(:a0, 0),
        RV32.li(:t0, 1),
        RV32.li(:t1, 101),
        Asm.label(:smoke_loop),
        Asm.bgeu(:t0, :t1, :blob_exit),
        RV32.add(:a0, :a0, :t0),
        RV32.addi(:t0, :t0, 1),
        Asm.j(:smoke_loop)
      ],
      [],
      relocate: false
    )
  end

  @doc "The label a body jumps to when it has a result in `a0`."
  @spec return() :: atom()
  def return, do: :blob_exit

  # ══ The frame ════════════════════════════════════════════════════════════════

  defp entry do
    [
      RV32.addi(:sp, :sp, -@frame),
      for {register, index} <- Enum.with_index(@saved) do
        RV32.sw(register, :sp, index * 4)
      end
    ]
  end

  defp exit_ do
    [
      Asm.label(return()),
      for {register, index} <- Enum.with_index(@saved) do
        RV32.lw(register, :sp, index * 4)
      end,
      RV32.addi(:sp, :sp, @frame),
      RV32.ret()
    ]
  end

  # ══ The relocation ═══════════════════════════════════════════════════════════

  @doc """
  Adds the blob's actual address to the 512 absolute entries of the jump tables.

  Assembled at base 0, an entry is an offset from `blob_start`; at run time it
  has to be an address. `auipc` gives the one number nothing else can:  where
  this copy of the blob actually landed.

  **Once.** A second pass would add the base twice and every dispatch would jump
  into nothing, so a blob is entered many times only if the caller keeps the
  relocated copy and calls into a body that skips this -- which is why the
  relocation sits in the entry sequence and not in the loop that uses it.

  Clobbers `t0` to `t3`, before any of them means anything.
  """
  @spec relocate() :: [Asm.item()]
  def relocate do
    [
      Asm.la(:t2, :blob_start),
      Asm.la(:t0, :table_base),
      RV32.li(:t1, 2 * 256),
      Asm.label(:relocate_loop),
      RV32.lw(:t3, :t0, 0),
      RV32.add(:t3, :t3, :t2),
      RV32.sw(:t3, :t0, 0),
      RV32.addi(:t0, :t0, 4),
      RV32.addi(:t1, :t1, -1),
      Asm.bnez(:t1, :relocate_loop)
    ]
  end
end
