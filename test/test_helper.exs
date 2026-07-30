# Les tests qui dépendent d'un outil externe s'excluent d'eux-mêmes quand il
# manque, plutôt que d'échouer : le dépôt doit rester vert sur une machine sans
# binutils RISC-V ni qemu. Ce qu'ils couvrent est alors simplement non vérifié,
# et `mix test --include binutils --include qemu` le rend visible.
outils =
  [:blargg] ++
    if(System.find_executable("riscv64-unknown-elf-as"), do: [], else: [:binutils]) ++
    if(Atomboy.Native.Qemu.available?(), do: [], else: [:qemu])

ExUnit.start(exclude: outils)
