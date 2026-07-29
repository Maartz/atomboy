defmodule Atomboy.LinkTest do
  use ExUnit.Case

  import Bitwise

  alias Atomboy.CPU.CartLoop
  alias Atomboy.CPU.State
  alias Atomboy.Link

  # L'API scanline : le câble vit dans la map. L'adaptateur garde les tests
  # dans la forme « {ram, link} » historique.
  defp tick(link, ram) do
    # L'await est non bloquant (rythme scanline) : laisser au loopback le
    # temps de livrer avant chaque passage.
    Process.sleep(5)
    ram = ram |> Map.put(:link, link) |> Link.line()
    {Map.delete(ram, :link), Map.get(ram, :link)}
  end

  # Une paire de câbles sur le port éphémère local.
  defp pair do
    {:ok, lsock} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(lsock)
    parent = self()

    spawn_link(fn ->
      {:ok, socket} = :gen_tcp.accept(lsock)
      :inet.setopts(socket, nodelay: true)
      # La socket appartient à qui l'accepte — la céder avant de mourir.
      :ok = :gen_tcp.controlling_process(socket, parent)
      send(parent, {:accepte, %Link{socket: socket}})
    end)

    {:ok, appelant} = Link.connect("localhost", port)
    assert_receive {:accepte, ecoutant}, 2000
    {ecoutant, appelant}
  end

  # Du code SM83 qui arme un transfert : SB = octet, SC = mode.
  defp arme(ram, octet, mode) do
    code = <<0x3E, octet, 0xE0, 0x01, 0x3E, mode, 0xE0, 0x02>>
    rom = :binary.copy(<<0>>, 0x100) <> code
    rom = rom <> :binary.copy(<<0>>, 0x8000 - byte_size(rom))
    {_state, ram, _} = CartLoop.run(%State{pc: 0x100}, rom, ram, 40)
    ram
  end

  test "maître et esclave échangent leurs octets, interruptions comprises" do
    {gauche, droite} = pair()

    # Gauche maître avec 0x42 ; droite esclave avec 0x99.
    ram_g = arme(%{link: true}, 0x42, 0x81)
    ram_d = arme(%{link: true}, 0x99, 0x80)

    assert ram_g[:link_op] == :master
    assert ram_d[:link_op] == :slave
    assert (ram_g[0xFF02] &&& 0x80) == 0x80

    # Frame 1 : le maître envoie son horloge (pas encore de réponse).
    {ram_g, gauche} = tick(gauche, ram_g)
    # L'esclave la pompe et répond.
    {ram_d, _droite} = tick(droite, ram_d)
    # Le maître récolte.
    {ram_g, _gauche} = tick(gauche, ram_g)

    assert ram_g[0xFF01] == 0x99
    assert ram_d[0xFF01] == 0x42
    assert (ram_g[0xFF02] &&& 0x80) == 0
    assert (ram_d[0xFF02] &&& 0x80) == 0
    assert (ram_g[0xFF0F] &&& 0x08) == 0x08
    assert (ram_d[0xFF0F] &&& 0x08) == 0x08
    refute Map.has_key?(ram_g, :link_op)
    refute Map.has_key?(ram_d, :link_op)
  end

  test "face à un partenaire non armé, la ligne lit 0xFF — SB intact" do
    {gauche, droite} = pair()

    ram_g = arme(%{link: true}, 0x11, 0x81)
    ram_d = %{:link => true, 0xFF01 => 0x77}

    {ram_g, gauche} = tick(gauche, ram_g)
    {ram_d, _} = tick(droite, ram_d)
    {ram_g, _} = tick(gauche, ram_g)

    # Le maître lit la ligne au repos ; le SB du non-armé ne bouge pas,
    # aucune interruption — c'est le silicium : le registre ne se branche
    # que transfert armé. (L'ancienne sémantique fabriquait de fausses
    # poignées de main au Club Câble.)
    assert ram_g[0xFF01] == 0xFF
    assert ram_d[0xFF01] == 0x77
    assert (Map.get(ram_d, 0xFF0F, 0) &&& 0x08) == 0
  end

  test "un maître sans réponse patiente sans renvoyer son horloge" do
    {gauche, droite} = pair()

    ram_g = arme(%{link: true}, 0x42, 0x81)
    {ram_g, gauche} = tick(gauche, ram_g)
    assert ram_g[:link_op] == :master_sent
    {ram_g, gauche} = tick(gauche, ram_g)
    {ram_g, gauche} = tick(gauche, ram_g)
    assert ram_g[:link_op] == :master_sent

    # Une seule horloge doit être partie.
    {:ok, <<0, 0x42>>} = :gen_tcp.recv(droite.socket, 2, 1000)
    assert {:error, :timeout} = :gen_tcp.recv(droite.socket, 2, 100)
    _ = {ram_g, gauche}
  end

  test "câble coupé : le transfert se conclut sur 0xFF, sans câble" do
    {gauche, droite} = pair()
    Link.close(droite)

    ram_g = arme(%{link: true}, 0x42, 0x81)
    {ram_g, gauche} = tick(gauche, ram_g)
    # L'envoi a pu réussir (tampon) ; la lecture, elle, échoue.
    {ram_g, gauche} =
      if gauche, do: tick(gauche, ram_g), else: {ram_g, gauche}

    assert gauche == nil
    assert ram_g[0xFF01] == 0xFF
    assert (ram_g[0xFF02] &&& 0x80) == 0
  end

  test "deux maîtres simultanés échangent sans laisser de résidu" do
    {gauche, droite} = pair()

    ram_g = arme(%{link: true}, 0x11, 0x81)
    ram_d = arme(%{link: true}, 0x22, 0x81)

    # Chacun envoie son horloge, puis conclut sur celle de l'autre.
    {ram_g, gauche} = tick(gauche, ram_g)
    {ram_d, droite} = tick(droite, ram_d)
    {ram_g, gauche} = tick(gauche, ram_g)
    {ram_d, droite} = tick(droite, ram_d)

    assert ram_g[0xFF01] == 0x22
    assert ram_d[0xFF01] == 0x11
    refute Map.has_key?(ram_g, :link_op)
    refute Map.has_key?(ram_d, :link_op)

    # Les sockets doivent être VIDES — le décalage d'un cran venait des
    # réponses orphelines (Nolan qui échangeait avec Nolan).
    assert {:error, :timeout} = :gen_tcp.recv(gauche.socket, 2, 50)
    assert {:error, :timeout} = :gen_tcp.recv(droite.socket, 2, 50)
    _ = {gauche, droite}
  end

  test "une réponse orpheline se purge avant une nouvelle horloge" do
    {gauche, droite} = pair()

    # Un résidu artificiel traîne dans la socket du maître.
    :gen_tcp.send(droite.socket, <<1, 0x99>>)
    Process.sleep(20)

    ram_g = arme(%{link: true}, 0x42, 0x81)
    {ram_g, gauche} = tick(gauche, ram_g)
    # Le résidu n'a PAS conclu le transfert : l'horloge est partie.
    assert ram_g[:link_op] == :master_sent

    # L'esclave répond normalement.
    ram_d = arme(%{link: true}, 0x55, 0x80)
    {ram_d, _} = tick(droite, ram_d)
    {ram_g, _} = tick(gauche, ram_g)

    assert ram_g[0xFF01] == 0x55
    assert ram_d[0xFF01] == 0x42
  end

  test "deux horloges d'affilée : une seule réponse par frame" do
    {gauche, droite} = pair()

    # Le maître (impatient) envoie deux horloges avant que l'esclave n'ait
    # digéré la première.
    :gen_tcp.send(gauche.socket, <<0, 0x01>>)
    :gen_tcp.send(gauche.socket, <<0, 0x02>>)
    Process.sleep(20)

    ram_d = arme(%{link: true}, 0xAA, 0x80)
    {ram_d, droite} = tick(droite, ram_d)

    # Première horloge servie avec l'octet armé…
    assert ram_d[0xFF01] == 0x01
    assert {:ok, <<1, 0xAA>>} = :gen_tcp.recv(gauche.socket, 2, 200)
    # …la seconde attend la frame suivante — et l'esclave réarmé, comme le
    # ferait son ISR (non armé, la ligne lirait 0xFF).
    ram_d = ram_d |> Map.put(:link, true) |> arme(0xBB, 0x80)
    {ram_d, _droite} = tick(droite, ram_d)
    assert ram_d[0xFF01] == 0x02
    assert {:ok, <<1, 0xBB>>} = :gen_tcp.recv(gauche.socket, 2, 200)
  end

  test "sans câble, la capture série de blargg reste intacte" do
    ram = arme(%{}, ?A, 0x81)
    assert IO.iodata_to_binary(Map.get(ram, :serial)) == "A"
    refute Map.has_key?(ram, :link_op)
  end
end
