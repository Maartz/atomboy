# Tests that depend on an external tool exclude themselves when it is missing,
# rather than failing: the repo must stay green on a machine with neither
# RISC-V binutils nor qemu. What they cover is then simply unverified, and
# `mix test --include binutils --include qemu` makes that visible.
tools =
  [:blargg] ++
    if(System.find_executable("riscv64-unknown-elf-as"), do: [], else: [:binutils]) ++
    if(Atomboy.Native.Qemu.available?(), do: [], else: [:qemu])

ExUnit.start(exclude: tools)
