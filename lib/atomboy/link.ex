defmodule Atomboy.Link do
  @moduledoc """
  The link cable, over TCP: two atomboys trade their serial bytes.

  On the real cable the master (internal clock, bit 0 of SC) clocks eight
  bits: its byte goes out while the partner's comes in — an exchange,
  never a send. The slave waits to be clocked, indefinitely. Here the wire
  is a socket and the exchange fits in two messages of two bytes:

      <<0, byte>>   the master's clock, its byte in tow
      <<1, byte>>   the slave's answer, its byte in return

  One side listens (`--listen [port]`), the other calls (`--link host:port`).
  Resolution lives at the frame boundary of the two game loops:
  round-trip latency ≈ one frame on each side — the tempo of a Pokémon
  trade, not of a race.

  The cable lives IN the memory map (`ram[:link]`, the socket struct) and
  resolves at the **scanline** (`line/1`, called by `Screen.step_line`): 154
  chances per frame, a latency of a few milliseconds — the scale of real
  hardware, whose master transfer concludes in ~4 ms. That is the condition
  for the Cable Club handshake, whose probe will not wait a whole frame. A
  master left unanswered retries on the next scanline (`:master_sent` — the
  clock goes out only once); one clock served per pass — the game must
  reload SB between two; a cut cable concludes on 0xFF and vanishes from
  the map, as if unplugged.
  """

  import Bitwise

  @default_port 7373
  @sb 0xFF01
  @sc 0xFF02
  @if_addr 0xFF0F

  defstruct [:socket, :trace, :t0]

  @type t :: %__MODULE__{}

  @doc "The cable's default port."
  @spec default_port() :: pos_integer()
  def default_port, do: @default_port

  @doc """
  Listens and waits for the partner — blocking, two minutes. To be started
  before the alternate screen: the waiting message must be seen.
  """
  @spec listen(pos_integer()) :: {:ok, t()} | {:error, String.t()}
  def listen(port) do
    with {:ok, lsock} <-
           :gen_tcp.listen(port, [:binary, packet: :raw, active: false, reuseaddr: true]),
         IO.puts(:stderr, "link cable: waiting for the partner on port #{port}…"),
         {:ok, socket} <- :gen_tcp.accept(lsock, :infinity) do
      :gen_tcp.close(lsock)
      :inet.setopts(socket, nodelay: true)
      IO.puts(:stderr, "link cable: partner plugged in.")
      {:ok, new(socket)}
    else
      {:error, reason} -> {:error, "link cable: #{inspect(reason)}"}
    end
  end

  @doc "Calls a partner that is listening. Retries for five seconds."
  @spec connect(String.t(), pos_integer()) :: {:ok, t()} | {:error, String.t()}
  def connect(host, port), do: connect(host, port, 10)

  defp connect(host, port, tries) do
    case :gen_tcp.connect(String.to_charlist(host), port, [
           :binary,
           packet: :raw,
           active: false,
           nodelay: true
         ]) do
      {:ok, socket} ->
        IO.puts(:stderr, "link cable: connected on #{host}:#{port}.")
        {:ok, new(socket)}

      {:error, _} when tries > 1 ->
        Process.sleep(500)
        connect(host, port, tries - 1)

      {:error, reason} ->
        {:error, "link cable: #{host}:#{port} unreachable (#{inspect(reason)})"}
    end
  end

  # The serial trace (ATOMBOY_LINK_TRACE=file): every event on the cable,
  # stamped in milliseconds — the tool for protocols that tear themselves
  # apart.
  defp new(socket) do
    %__MODULE__{
      socket: socket,
      trace: System.get_env("ATOMBOY_LINK_TRACE"),
      t0: System.monotonic_time(:millisecond)
    }
  end

  defp trace(%__MODULE__{trace: nil}, _msg), do: :ok

  defp trace(link, msg) do
    ms = System.monotonic_time(:millisecond) - link.t0
    File.write!(link.trace, "#{ms} #{msg}\n", [:append])
  end

  defp hex(b), do: b |> Integer.to_string(16) |> String.pad_leading(2, "0")

  @doc """
  One scanline of cable: resolves the pending serial operation and pumps at
  most one incoming clock. With no cable in the map, touches nothing; a cut
  cable erases itself from the map.
  """
  @spec line(map()) :: map()
  def line(ram) do
    case Map.get(ram, :link) do
      %__MODULE__{} = link ->
        ram = Map.update(ram, :link_line, 1, &(&1 + 1))

        {ram, link} =
          case Map.get(ram, :link_op) do
            :master -> clock_out(link, ram)
            :master_sent -> await(link, ram)
            _ -> pump(link, ram)
          end

        if link, do: Map.put(ram, :link, link), else: Map.delete(ram, :link)

      _ ->
        ram
    end
  end

  @doc "Closes the cable."
  @spec close(t() | nil) :: :ok
  def close(nil), do: :ok

  def close(%__MODULE__{socket: socket}) do
    :gen_tcp.close(socket)
    :ok
  end

  # ── The master ──────────────────────────────────────────────────────────────

  defp clock_out(link, ram) do
    # THE WIRE HAS ONLY ONE SLOT. If a clock is already in flight, this new
    # transfer reuses it — the games' probe loops rewrite SC every frame,
    # alternating master and slave, and every rewrite that would send a
    # fresh clock floods the wire: five clocks served within the same
    # millisecond, the decisive answer drowned (lived through, in the
    # trace). One clock, one answer, always.
    if Map.get(ram, :link_wire) do
      await(link, Map.put(ram, :link_op, :master_sent))
    else
      clock_send(link, ram)
    end
  end

  defp clock_send(link, ram) do
    # Wire free: any answer still lying around is a true orphan.
    case drain_stale(link) do
      :ok ->
        case :gen_tcp.send(link.socket, <<0, Map.get(ram, @sb, 0xFF)>>) do
          :ok ->
            trace(link, "M clock → #{hex(Map.get(ram, @sb, 0xFF))}")

            await(
              link,
              ram
              |> Map.put(:link_op, :master_sent)
              |> Map.put(:link_wire, true)
              |> Map.put(:link_sent, System.monotonic_time(:millisecond))
            )

          {:error, _} ->
            unplugged(ram)
        end

      {:clock, _byte} ->
        # The peer clocked too: two masters, two clocks crossing — on the
        # real wire that is electrical noise, not an exchange. Ours goes
        # out all the same (the peer will conclude the same way when it
        # sees it), and each side reads 0xFF: the games retry their
        # handshake until a probe meets a genuine slave window. (Swapping
        # the crossed bytes cleanly made BOTH probes read $01: each one
        # settled as slave — the "temperamental" sync of the report.)
        case :gen_tcp.send(link.socket, <<0, Map.get(ram, @sb, 0xFF)>>) do
          :ok ->
            trace(link, "M crossed: bus undefined, FF")
            {complete(ram, 0xFF), link}

          {:error, _} ->
            unplugged(ram)
        end

      :closed ->
        unplugged(ram)
    end
  end

  defp drain_stale(link) do
    case :gen_tcp.recv(link.socket, 2, 0) do
      {:ok, <<1, stale>>} ->
        trace(link, "orphan drained #{hex(stale)}")
        drain_stale(link)

      {:ok, <<0, byte>>} ->
        {:clock, byte}

      {:ok, _other} ->
        drain_stale(link)

      {:error, :timeout} ->
        :ok

      {:error, _} ->
        :closed
    end
  end

  defp await(link, ram) do
    case :gen_tcp.recv(link.socket, 2, 0) do
      {:ok, <<1, byte>>} ->
        trace(link, "M got   ← #{hex(byte)}")
        {complete(ram, byte), link}

      {:ok, <<0, _byte>>} ->
        # Two masters at once: noise, not an exchange — 0xFF, and the games
        # retry. Nobody answers (the peer concludes the same way when it
        # sees our clock): no orphan answer left behind.
        trace(link, "M crossed: bus undefined, FF")
        {complete(ram, 0xFF), link}

      {:error, :timeout} ->
        # Hardware always concludes in ~4 ms; a master still waiting beyond
        # the peer's long hold is dealing with a partner that has vanished —
        # the line at rest, and the game copes.
        if System.monotonic_time(:millisecond) - Map.get(ram, :link_sent, 0) > 600 do
          trace(link, "M timeout: FF")
          {complete(ram, 0xFF), link}
        else
          {ram, link}
        end

      {:error, _} ->
        unplugged(ram)
    end
  end

  # ── The slave, and the line at rest ─────────────────────────────────────────

  # The master's clock meets the slave's SB ONLY when a transfer is armed
  # (bit 7 of SC): unarmed, the serial line stays at rest and the master
  # reads 0xFF — the silicon only wires the register in on demand. Serving
  # the SB of an unarmed side (and overwriting it) manufactured false
  # handshakes: one player's $01 probe, recycled by the other, read as
  # "master partner detected" (lived through, in the trace). ONE clock per
  # frame: the answer to the next one waits for the ISR to have reloaded SB.
  # A clock received during the unarmed window is HELD: the slave's ISR —
  # delayed by the vblank handler or the end-of-frame nap — is going to
  # re-arm, and the byte must not get lost (lived through: one byte skipped,
  # "SILER", the other side's party shifted). Past the delay, the line at
  # rest answers 0xFF — the semantics handshake probes expect from a partner
  # that is not in link mode.
  #
  # Two patiences: short before the handshake (probes must read 0xFF fast),
  # long after (:link_active) — in the menu phase the game only re-arms
  # every two or three frames, and real hardware, its ISR always armed,
  # would never produce an FF there (lived through: "Too bad! The trade is
  # cancelled" while the partner was hesitating in a menu).
  @hold_ms 25
  @hold_active_ms 400

  # The hardware transfer lasts eight bits at 8192 Hz ≈ 4194 cycles ≈ nine
  # scanlines — and it is that duration which, on silicon, gives the slave's
  # main loop the time to copy hSerialReceive: the ISR re-arms SC
  # immediately, a single cell, no queue. Serving as soon as the transfer is
  # armed overwrites the previous byte between two passes of the loop (lived
  # through: bytes swallowed in the party blocks, structures shifted,
  # "CYNDAQUIL looks odd!", and the VRAM derailment of the crash report —
  # GetPokemonName on a phantom species).
  @transfer_lines 9

  defp pump(link, ram) do
    case Map.get(ram, :link_held) do
      {byte, since} -> serve_held(link, ram, byte, since)
      nil -> pump_recv(link, ram)
    end
  end

  defp pump_recv(link, ram) do
    case :gen_tcp.recv(link.socket, 2, 0) do
      {:ok, <<0, byte>>} ->
        if Map.get(ram, :link_op) == :slave do
          serve(link, ram, byte)
        else
          trace(link, "S holds #{hex(byte)} (not armed yet)")
          {Map.put(ram, :link_held, {byte, System.monotonic_time(:millisecond)}), link}
        end

      {:ok, <<1, byte>>} ->
        # The answer to a clock we gave up on (the game flipped to slave in
        # the meantime): consumed, and the wire is free again.
        trace(link, "late answer #{hex(byte)} — wire freed")
        pump_recv(link, Map.delete(ram, :link_wire))

      {:ok, _other} ->
        pump_recv(link, ram)

      {:error, :timeout} ->
        {ram, link}

      {:error, _} ->
        unplugged(ram)
    end
  end

  defp serve_held(link, ram, byte, since) do
    cond do
      Map.get(ram, :link_op) == :slave ->
        serve(link, Map.delete(ram, :link_held), byte)

      System.monotonic_time(:millisecond) - since >
          if(Map.get(ram, :link_active), do: @hold_active_ms, else: @hold_ms) ->
        # Nobody is arming: the line at rest.
        case :gen_tcp.send(link.socket, <<1, 0xFF>>) do
          :ok ->
            trace(link, "S ← #{hex(byte)} → FF (at rest, after the hold)")
            {Map.delete(ram, :link_held), link}

          {:error, _} ->
            unplugged(ram)
        end

      true ->
        {ram, link}
    end
  end

  defp serve(link, ram, byte) do
    line = Map.get(ram, :link_line, 0)

    if line - Map.get(ram, :link_served, -@transfer_lines) < @transfer_lines do
      # Too soon after the previous service: the clock waits on hold, as on
      # the real wire where the transfer is still clocking out its bits.
      {Map.put_new(ram, :link_held, {byte, System.monotonic_time(:millisecond)}), link}
    else
      answer = Map.get(ram, @sb, 0xFF)

      case :gen_tcp.send(link.socket, <<1, answer>>) do
        :ok ->
          trace(link, "S ← #{hex(byte)} → #{hex(answer)}")
          {complete(ram, byte) |> Map.put(:link_served, line), link}

        {:error, _} ->
          unplugged(ram)
      end
    end
  end

  # ── The end of a transfer ───────────────────────────────────────────────────

  defp complete(ram, byte) do
    ram
    |> Map.put(@sb, byte)
    |> Map.put(@sc, Map.get(ram, @sc, 0) &&& 0x7F)
    |> Map.update(@if_addr, 0x08, &(&1 ||| 0x08))
    |> Map.put(:link_active, true)
    |> Map.delete(:link_op)
    |> Map.delete(:link_sent)
    |> Map.delete(:link_wire)
  end

  # Cable unplugged: the line reads 0xFF, the armed transfer concludes.
  defp unplugged(ram) do
    {complete(ram, 0xFF), nil}
  end
end
