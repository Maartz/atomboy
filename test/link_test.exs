defmodule Atomboy.LinkTest do
  use ExUnit.Case

  import Bitwise

  alias Atomboy.CPU.CartLoop
  alias Atomboy.CPU.State
  alias Atomboy.Link

  # The scanline API: the cable lives in the map. This adapter keeps the tests
  # in the historical "{ram, link}" shape.
  defp tick(link, ram) do
    # The await is non-blocking (scanline tempo): give the loopback time to
    # deliver before each pass.
    Process.sleep(5)
    ram = ram |> Map.put(:link, link) |> Link.line()
    {Map.delete(ram, :link), Map.get(ram, :link)}
  end

  # A hardware transfer lasts ~9 scanlines (8 bits at 8192 Hz): slave services
  # honour that pacing. This tick swallows the scanlines needed before looking
  # at the result.
  defp tick_transfer(link, ram) do
    Enum.reduce(1..12, {ram, link}, fn _, {ram, link} ->
      tick(link, ram)
    end)
  end

  # A pair of cables on the local ephemeral port.
  defp pair do
    {:ok, lsock} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(lsock)
    parent = self()

    spawn_link(fn ->
      {:ok, socket} = :gen_tcp.accept(lsock)
      :inet.setopts(socket, nodelay: true)
      # The socket belongs to whoever accepts it — hand it over before dying.
      :ok = :gen_tcp.controlling_process(socket, parent)
      send(parent, {:accepted, %Link{socket: socket}})
    end)

    {:ok, caller} = Link.connect("localhost", port)
    assert_receive {:accepted, listener}, 2000
    {listener, caller}
  end

  # SM83 code that arms a transfer: SB = byte, SC = mode.
  defp arm(ram, byte, mode) do
    code = <<0x3E, byte, 0xE0, 0x01, 0x3E, mode, 0xE0, 0x02>>
    rom = :binary.copy(<<0>>, 0x100) <> code
    rom = rom <> :binary.copy(<<0>>, 0x8000 - byte_size(rom))
    {_state, ram, _} = CartLoop.run(%State{pc: 0x100}, rom, ram, 40)
    ram
  end

  test "master and slave trade their bytes, interrupts included" do
    {left, right} = pair()

    # Left is master with 0x42; right is slave with 0x99.
    ram_l = arm(%{link: true}, 0x42, 0x81)
    ram_r = arm(%{link: true}, 0x99, 0x80)

    assert ram_l[:link_op] == :master
    assert ram_r[:link_op] == :slave
    assert (ram_l[0xFF02] &&& 0x80) == 0x80

    # Frame 1: the master sends its clock (no answer yet).
    {ram_l, left} = tick(left, ram_l)
    # The slave pumps it and answers.
    {ram_r, _right} = tick(right, ram_r)
    # The master collects.
    {ram_l, _left} = tick(left, ram_l)

    assert ram_l[0xFF01] == 0x99
    assert ram_r[0xFF01] == 0x42
    assert (ram_l[0xFF02] &&& 0x80) == 0
    assert (ram_r[0xFF02] &&& 0x80) == 0
    assert (ram_l[0xFF0F] &&& 0x08) == 0x08
    assert (ram_r[0xFF0F] &&& 0x08) == 0x08
    refute Map.has_key?(ram_l, :link_op)
    refute Map.has_key?(ram_r, :link_op)
  end

  test "facing a partner that stays unarmed, the line reads 0xFF" do
    {left, right} = pair()

    ram_l = arm(%{link: true}, 0x11, 0x81)
    ram_r = %{:link => true, 0xFF01 => 0x77}

    {ram_l, left} = tick(left, ram_l)
    # The clock is HELD at first (the ISR might re-arm)…
    {ram_r, right} = tick(right, ram_r)
    assert {_byte, _since} = ram_r[:link_held]
    # …then, nobody arming, the line at rest answers.
    Process.sleep(30)
    {ram_r, _} = tick(right, ram_r)
    {ram_l, _} = tick(left, ram_l)

    assert ram_l[0xFF01] == 0xFF
    assert ram_r[0xFF01] == 0x77
    assert (Map.get(ram_r, 0xFF0F, 0) &&& 0x08) == 0
    refute Map.has_key?(ram_r, :link_held)
  end

  test "a held clock is served as soon as the slave arms — no byte lost" do
    {left, right} = pair()

    # The master clocks 0x42 towards a slave that has not re-armed yet (ISR
    # running late): the byte is held.
    ram_l = arm(%{link: true}, 0x42, 0x81)
    ram_r = %{:link => true, 0xFF01 => 0x99}
    {ram_l, left} = tick(left, ram_l)
    {ram_r, right} = tick(right, ram_r)
    assert {_, _} = ram_r[:link_held]

    # The ISR finally runs: the slave arms — the held byte is served together
    # with the fresh answer.
    ram_r = ram_r |> Map.put(:link, true) |> arm(0x77, 0x80)
    {ram_r, _} = tick(right, ram_r)
    {ram_l, _} = tick(left, ram_l)

    assert ram_r[0xFF01] == 0x42
    assert ram_l[0xFF01] == 0x77
    refute Map.has_key?(ram_r, :link_held)
  end

  test "a master left unanswered waits without re-sending its clock" do
    {left, right} = pair()

    ram_l = arm(%{link: true}, 0x42, 0x81)
    {ram_l, left} = tick(left, ram_l)
    assert ram_l[:link_op] == :master_sent
    {ram_l, left} = tick(left, ram_l)
    {ram_l, left} = tick(left, ram_l)
    assert ram_l[:link_op] == :master_sent

    # Only one clock must have gone out.
    {:ok, <<0, 0x42>>} = :gen_tcp.recv(right.socket, 2, 1000)
    assert {:error, :timeout} = :gen_tcp.recv(right.socket, 2, 100)
    _ = {ram_l, left}
  end

  test "cable cut: the transfer concludes on 0xFF, with no cable left" do
    {left, right} = pair()
    Link.close(right)

    ram_l = arm(%{link: true}, 0x42, 0x81)
    {ram_l, left} = tick(left, ram_l)
    # The send may have succeeded (buffer); the read is the one that fails.
    {ram_l, left} =
      if left, do: tick(left, ram_l), else: {ram_l, left}

    assert left == nil
    assert ram_l[0xFF01] == 0xFF
    assert (ram_l[0xFF02] &&& 0x80) == 0
  end

  test "two simultaneous masters read noise — 0xFF, no leftovers" do
    {left, right} = pair()

    ram_l = arm(%{link: true}, 0x11, 0x81)
    ram_r = arm(%{link: true}, 0x22, 0x81)

    # Each one sends its clock; crossed clocks amount to electrical noise.
    {ram_l, left} = tick(left, ram_l)
    {ram_r, right} = tick(right, ram_r)
    {ram_l, left} = tick(left, ram_l)
    {ram_r, right} = tick(right, ram_r)

    # 0xFF on both sides: the handshake probes WILL RETRY — a clean exchange
    # made both of them read $01 and both settle as slaves (the temperamental
    # sync of the report).
    assert ram_l[0xFF01] == 0xFF
    assert ram_r[0xFF01] == 0xFF
    refute Map.has_key?(ram_l, :link_op)
    refute Map.has_key?(ram_r, :link_op)

    assert {:error, :timeout} = :gen_tcp.recv(left.socket, 2, 50)
    assert {:error, :timeout} = :gen_tcp.recv(right.socket, 2, 50)
    _ = {left, right}
  end

  test "an orphan answer is drained before a new clock" do
    {left, right} = pair()

    # An artificial leftover lies around in the master's socket.
    :gen_tcp.send(right.socket, <<1, 0x99>>)
    Process.sleep(20)

    ram_l = arm(%{link: true}, 0x42, 0x81)
    {ram_l, left} = tick(left, ram_l)
    # The leftover did NOT conclude the transfer: the clock went out.
    assert ram_l[:link_op] == :master_sent

    # The slave answers as usual.
    ram_r = arm(%{link: true}, 0x55, 0x80)
    {ram_r, _} = tick(right, ram_r)
    {ram_l, _} = tick(left, ram_l)

    assert ram_l[0xFF01] == 0x55
    assert ram_r[0xFF01] == 0x42
  end

  test "two clocks in a row: only one answer per frame" do
    {left, right} = pair()

    # The master (impatient) sends two clocks before the slave has digested
    # the first one.
    :gen_tcp.send(left.socket, <<0, 0x01>>)
    :gen_tcp.send(left.socket, <<0, 0x02>>)
    Process.sleep(20)

    ram_r = arm(%{link: true}, 0xAA, 0x80)
    {ram_r, right} = tick(right, ram_r)

    # First clock served with the armed byte…
    assert ram_r[0xFF01] == 0x01
    assert {:ok, <<1, 0xAA>>} = :gen_tcp.recv(left.socket, 2, 200)
    # …the second waits for the transfer's pacing (≈ 9 scanlines) — and for
    # the slave to be re-armed, as its ISR would do (unarmed, the line would
    # read 0xFF).
    ram_r = ram_r |> Map.put(:link, true) |> arm(0xBB, 0x80)
    {ram_r, _right} = tick_transfer(right, ram_r)
    assert ram_r[0xFF01] == 0x02
    assert {:ok, <<1, 0xBB>>} = :gen_tcp.recv(left.socket, 2, 200)
  end

  test "link active: the hold turns patient — the menu may take its time" do
    {left, right} = pair()

    # A first armed exchange establishes the link (link_active).
    ram_l = arm(%{link: true}, 0x42, 0x81)
    ram_r = arm(%{link: true}, 0x55, 0x80)
    {ram_l, left} = tick(left, ram_l)
    {ram_r, right} = tick(right, ram_r)
    {ram_l, left} = tick(left, ram_l)
    assert ram_r[:link_active] == true

    # The master clocks while the slave browses its menus (not armed).
    ram_l = ram_l |> Map.put(:link, true) |> arm(0x70, 0x81)
    {ram_l, left} = tick(left, ram_l)
    {ram_r, right} = tick(right, ram_r)
    assert {_, _} = ram_r[:link_held]

    # 30 ms later — beyond the old patience — the byte is STILL held: no
    # phantom FF mistaken for a refused trade.
    Process.sleep(30)
    {ram_r, right} = tick(right, ram_r)
    assert {_, _} = ram_r[:link_held]

    # The slave leaves the menu and arms: the held byte is served (at the
    # transfer's pacing).
    ram_r = ram_r |> Map.put(:link, true) |> arm(0x71, 0x80)
    {ram_r, _} = tick_transfer(right, ram_r)
    {ram_l, _} = tick(left, ram_l)
    assert ram_r[0xFF01] == 0x70
    assert ram_l[0xFF01] == 0x71
  end

  test "the hardware pacing: no two slave services within nine scanlines" do
    {left, right} = pair()

    # The master dumps two clocks at once (real drift between the two BEAMs:
    # the bytes pile up in the socket).
    :gen_tcp.send(left.socket, <<0, 0x11>>)
    :gen_tcp.send(left.socket, <<0, 0x22>>)
    Process.sleep(20)

    ram_r = arm(%{link: true}, 0xAA, 0x80)
    {ram_r, right} = tick(right, ram_r)
    assert ram_r[0xFF01] == 0x11

    # Re-armed right away (the game's ISR re-arms SC before the main loop has
    # copied hSerialReceive): the next scanline does NOT serve — on silicon
    # the transfer is still clocking out its eight bits, and it is that
    # duration which protects the previous byte from being overwritten.
    ram_r = ram_r |> Map.put(:link, true) |> arm(0xBB, 0x80)
    {ram_r, right} = tick(right, ram_r)
    assert ram_r[0xFF01] == 0xBB

    # Nine scanlines later: yes.
    {ram_r, _} = tick_transfer(right, ram_r)
    assert ram_r[0xFF01] == 0x22
  end

  test "rewriting SC in flight restarts the same transfer — a single clock" do
    {left, right} = pair()

    # The game probes: SC=$81; the clock goes out.
    ram_l = arm(%{link: true}, 0x01, 0x81)
    {ram_l, left} = tick(left, ram_l)
    assert ram_l[:link_op] == :master_sent

    # The probe loop rewrites SC=$81 (every frame, like pokecrystal).
    ram_l = ram_l |> Map.put(:link, true) |> arm(0x01, 0x81)
    assert ram_l[:link_op] == :master_sent
    {ram_l, left} = tick(left, ram_l)
    {ram_l, left} = tick(left, ram_l)

    # ONE clock on the wire, and one only.
    assert {:ok, <<0, 0x01>>} = :gen_tcp.recv(right.socket, 2, 200)
    assert {:error, :timeout} = :gen_tcp.recv(right.socket, 2, 100)
    _ = {ram_l, left}
  end

  test "with no cable, blargg's serial capture stays intact" do
    ram = arm(%{}, ?A, 0x81)
    assert IO.iodata_to_binary(Map.get(ram, :serial)) == "A"
    refute Map.has_key?(ram, :link_op)
  end
end
