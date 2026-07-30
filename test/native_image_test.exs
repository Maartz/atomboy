defmodule Atomboy.NativeImageTest do
  @moduledoc """
  The smoke image, end to end.

  On paper this test checks very little -- three letters on a serial port. What
  it locks down are the four assumptions the whole harness rests on, none of
  which documentation settles with certainty: the processor really starts at
  `0x8000_0000` on a raw binary, the UART wants its status register polled,
  `sifive_test` hands control back cleanly, and Elixir needs neither a C
  compiler nor a linker to produce any of it.
  """

  use ExUnit.Case, async: true

  alias Atomboy.Native.Image
  alias Atomboy.Native.Qemu

  @moduletag :qemu

  test "the smoke image boots, speaks, and powers off" do
    image = Image.smoke()

    result = Qemu.run(image.code, timeout: 15_000)

    assert result.status == :ok, "qemu never handed control back -- the guest is looping"
    assert result.exit_status == 0
    assert result.serial == "OK\n"
  end

  test "the image stays tiny -- that is this work's promise" do
    image = Image.smoke()

    assert image.size < 512,
           "the runtime grew to #{image.size} bytes; the C6 cache is 32 KB"

    assert rem(image.size, 4) == 0
  end

  test "the entry point really is the first byte" do
    image = Image.smoke()
    assert image.labels[:_start] == 0
  end

  test "a watchdog interrupts a looping guest" do
    # An image that never powers off: the first byte jumps to itself.
    looper = Image.build([{:label, :stuck}, Atomboy.Native.Asm.j(:stuck)])

    result = Qemu.run(looper.code, timeout: 1_500)

    assert result.status == :timeout
    assert result.duration_us >= 1_500_000
  end
end
