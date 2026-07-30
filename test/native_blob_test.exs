defmodule Atomboy.NativeBlobTest do
  @moduledoc """
  The callable blob, checked where checking is cheap.

  `Atomboy.Native.Blob` exists for a machine this suite cannot run on, and the
  temptation is to call it untestable and flash it to find out. It is not: a
  blob is a function, and qemu can call a function. So the image built here is
  the ESP-IDF application's stand-in -- it puts a value in every register the
  ABI says a callee must give back, calls the blob, and demands them all back
  unchanged along with the right answer.

  What this cannot see is the one thing only silicon says: whether the memory
  the bytes were copied into is executable. That question was answered by the
  board, and the answer was no until the PMP split came off -- see
  `esp32/native/sdkconfig.defaults`.
  """

  use ExUnit.Case, async: true

  alias Atomboy.Native.Asm
  alias Atomboy.Native.Blob
  alias Atomboy.Native.Image
  alias Atomboy.Native.Qemu
  alias Atomboy.Native.RV32

  @moduletag :qemu

  test "the smoke blob computes its sum and returns it" do
    assert run(Blob.smoke(), []).serial == "OK"
  end

  test "every register the ABI protects comes back unchanged" do
    # A different marker in each, so a blob that saved the frame but restored it
    # in the wrong order fails as loudly as one that saved nothing. `sp` is not
    # in the list and is checked by construction: the caller's own frame is
    # still there afterwards, or `putc` would not return.
    saved = Blob.saved() -- [:ra]

    marks = for {register, index} <- Enum.with_index(saved), do: {register, 0x100 + index}

    poison = for {register, mark} <- marks, do: RV32.li(register, mark)

    checks =
      for {register, mark} <- marks do
        [RV32.li(:t2, mark), Asm.bne(register, :t2, :clobbered)]
      end

    run(Blob.smoke(), poison ++ checks)
    |> Map.get(:serial)
    |> then(&assert &1 == "OK", "a callee-saved register did not survive the call")
  end

  # The blob embedded in a bootable image and called from it -- `jal` in, `ret`
  # out, exactly as the C shim does it. The blob is position independent, so
  # sitting in another image's data section costs it nothing.
  defp run(blob, preamble) do
    Image.build(
      [
        preamble,
        Asm.call(:the_blob),
        RV32.li(:t1, 5050),
        Asm.bne(:a0, :t1, :clobbered),
        RV32.li(:a0, ?O),
        Asm.call(:putc),
        RV32.li(:a0, ?K),
        Asm.call(:putc),
        Asm.j(:poweroff),
        Asm.label(:clobbered),
        RV32.li(:a0, ?N),
        Asm.call(:putc),
        Asm.j(:poweroff)
      ],
      [{:align, 4}, Asm.label(:the_blob), blob.code]
    )
    |> Map.get(:code)
    |> Qemu.run([])
  end
end
