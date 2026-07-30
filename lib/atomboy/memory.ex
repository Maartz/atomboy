defmodule Atomboy.Memory do
  @moduledoc """
  The memory boundary — the project's structuring decision.

  This behaviour is deliberately minimal and **stable over time**: it is the
  same API that very different backends will implement as the phases go by.

    * Phase 1 (Mac, SM83 tests) — `Atomboy.Memory.Flat`, a sparse map. Enough
      for the SingleStepTests vectors, which only touch a handful of
      addresses.
    * Phase 1bis (blargg ROMs) — a segmented backend: the ROM is a BEAM binary
      (immutable, hence read by pattern matching without copying), and only
      the genuinely mutable regions live in a separate structure.
    * Phase 3 (ESP32) — VRAM/OAM become a C resource, `read8/2` and `write8/3`
      become NIFs. The PPU reaches them directly from C.

  ## Why `write8/3` returns the memory

  A pure backend (map, binary) has to return a new value; a NIF backend
  returns the same resource reference. The CPU threads the return value in
  both cases, so the same code works on both backends. The cost on the NIF
  backend is nil (we hand back the term we were given).

  ## Why `read16/2` and `write16/3` are part of the behaviour

  These are not syntactic sugar: they are the **block accessors** identified in
  the brief. On the NIF backend, every memory access the CPU makes is a NIF
  call, and the opcode fetch is itself an access. A `push`/`pop` that does two
  accesses in a single call halves the traffic across the boundary — it shows
  up in the profile. Implementing them as two `read8` calls would be missing
  the point; a serious backend implements them natively.
  """

  @typedoc "The opaque term carrying the memory state. Its shape is the backend's."
  @type t :: term()

  @type addr :: 0..0xFFFF
  @type value :: 0..0xFF

  @callback read8(t, addr) :: value
  @callback write8(t, addr, value) :: t

  @doc """
  Little-endian 16-bit read. `addr + 1` wraps to 0x0000.
  """
  @callback read16(t, addr) :: 0..0xFFFF

  @doc """
  Little-endian 16-bit write. `addr + 1` wraps to 0x0000.
  """
  @callback write16(t, addr, 0..0xFFFF) :: t
end
