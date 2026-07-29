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

  # Un transfert matériel dure ~9 scanlines (8 bits à 8192 Hz) : les
  # services esclaves respectent cette cadence. Ce tick-là avale les
  # scanlines nécessaires avant de constater le résultat.
  defp tick_transfert(link, ram) do
    Enum.reduce(1..12, {ram, link}, fn _, {ram, link} ->
      tick(link, ram)
    end)
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

  test "face à un partenaire durablement non armé, la ligne lit 0xFF" do
    {gauche, droite} = pair()

    ram_g = arme(%{link: true}, 0x11, 0x81)
    ram_d = %{:link => true, 0xFF01 => 0x77}

    {ram_g, gauche} = tick(gauche, ram_g)
    # L'horloge est d'abord RETENUE (l'ISR pourrait se réarmer)…
    {ram_d, droite} = tick(droite, ram_d)
    assert {_byte, _depuis} = ram_d[:link_held]
    # …puis, personne ne s'armant, la ligne au repos répond.
    Process.sleep(30)
    {ram_d, _} = tick(droite, ram_d)
    {ram_g, _} = tick(gauche, ram_g)

    assert ram_g[0xFF01] == 0xFF
    assert ram_d[0xFF01] == 0x77
    assert (Map.get(ram_d, 0xFF0F, 0) &&& 0x08) == 0
    refute Map.has_key?(ram_d, :link_held)
  end

  test "une horloge retenue se sert dès que l'esclave s'arme — aucun octet perdu" do
    {gauche, droite} = pair()

    # Le maître cadence 0x42 vers un esclave pas encore réarmé (ISR en
    # retard) : l'octet est retenu.
    ram_g = arme(%{link: true}, 0x42, 0x81)
    ram_d = %{:link => true, 0xFF01 => 0x99}
    {ram_g, gauche} = tick(gauche, ram_g)
    {ram_d, droite} = tick(droite, ram_d)
    assert {_, _} = ram_d[:link_held]

    # L'ISR passe enfin : l'esclave s'arme — l'octet retenu se sert avec
    # la réponse fraîche.
    ram_d = ram_d |> Map.put(:link, true) |> arme(0x77, 0x80)
    {ram_d, _} = tick(droite, ram_d)
    {ram_g, _} = tick(gauche, ram_g)

    assert ram_d[0xFF01] == 0x42
    assert ram_g[0xFF01] == 0x77
    refute Map.has_key?(ram_d, :link_held)
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

  test "deux maîtres simultanés lisent du bruit — 0xFF, sans résidu" do
    {gauche, droite} = pair()

    ram_g = arme(%{link: true}, 0x11, 0x81)
    ram_d = arme(%{link: true}, 0x22, 0x81)

    # Chacun envoie son horloge ; les croisées valent bruit électrique.
    {ram_g, gauche} = tick(gauche, ram_g)
    {ram_d, droite} = tick(droite, ram_d)
    {ram_g, gauche} = tick(gauche, ram_g)
    {ram_d, droite} = tick(droite, ram_d)

    # 0xFF des deux côtés : les sondes d'établissement RETENTERONT — un
    # échange propre faisait lire $01 aux deux et s'établir esclaves tous
    # les deux (le sync capricieux du rapport).
    assert ram_g[0xFF01] == 0xFF
    assert ram_d[0xFF01] == 0xFF
    refute Map.has_key?(ram_g, :link_op)
    refute Map.has_key?(ram_d, :link_op)

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
    # …la seconde attend la cadence du transfert (≈ 9 scanlines) — et
    # l'esclave réarmé, comme le ferait son ISR (non armé, la ligne
    # lirait 0xFF).
    ram_d = ram_d |> Map.put(:link, true) |> arme(0xBB, 0x80)
    {ram_d, _droite} = tick_transfert(droite, ram_d)
    assert ram_d[0xFF01] == 0x02
    assert {:ok, <<1, 0xBB>>} = :gen_tcp.recv(gauche.socket, 2, 200)
  end

  test "lien actif : la retenue devient patiente — le menu peut réfléchir" do
    {gauche, droite} = pair()

    # Un premier échange armé établit le lien (link_active).
    ram_g = arme(%{link: true}, 0x42, 0x81)
    ram_d = arme(%{link: true}, 0x55, 0x80)
    {ram_g, gauche} = tick(gauche, ram_g)
    {ram_d, droite} = tick(droite, ram_d)
    {ram_g, gauche} = tick(gauche, ram_g)
    assert ram_d[:link_active] == true

    # Le maître cadence pendant que l'esclave navigue ses menus (pas armé).
    ram_g = ram_g |> Map.put(:link, true) |> arme(0x70, 0x81)
    {ram_g, gauche} = tick(gauche, ram_g)
    {ram_d, droite} = tick(droite, ram_d)
    assert {_, _} = ram_d[:link_held]

    # 30 ms plus tard — au-delà de l'ancienne patience — l'octet est
    # TOUJOURS retenu : pas de FF fantôme pris pour un refus d'échange.
    Process.sleep(30)
    {ram_d, droite} = tick(droite, ram_d)
    assert {_, _} = ram_d[:link_held]

    # L'esclave sort du menu et s'arme : l'octet retenu se sert (à la
    # cadence du transfert).
    ram_d = ram_d |> Map.put(:link, true) |> arme(0x71, 0x80)
    {ram_d, _} = tick_transfert(droite, ram_d)
    {ram_g, _} = tick(gauche, ram_g)
    assert ram_d[0xFF01] == 0x70
    assert ram_g[0xFF01] == 0x71
  end

  test "la cadence matérielle : pas deux services esclaves en neuf scanlines" do
    {gauche, droite} = pair()

    # Le maître déverse deux horloges d'un coup (dérive réelle entre les
    # deux BEAM : les octets s'empilent dans la socket).
    :gen_tcp.send(gauche.socket, <<0, 0x11>>)
    :gen_tcp.send(gauche.socket, <<0, 0x22>>)
    Process.sleep(20)

    ram_d = arme(%{link: true}, 0xAA, 0x80)
    {ram_d, droite} = tick(droite, ram_d)
    assert ram_d[0xFF01] == 0x11

    # Réarmé aussitôt (l'ISR du jeu ré-arme SC avant que la boucle
    # principale ait copié hSerialReceive) : la scanline suivante ne sert
    # PAS — sur silicium le transfert cadence encore ses huit bits, et
    # c'est cette durée qui protège l'octet précédent de l'écrasement.
    ram_d = ram_d |> Map.put(:link, true) |> arme(0xBB, 0x80)
    {ram_d, droite} = tick(droite, ram_d)
    assert ram_d[0xFF01] == 0xBB

    # Neuf scanlines plus tard : oui.
    {ram_d, _} = tick_transfert(droite, ram_d)
    assert ram_d[0xFF01] == 0x22
  end

  test "réécrire SC en vol relance le même transfert — une seule horloge" do
    {gauche, droite} = pair()

    # Le jeu sonde : SC=$81 ; l'horloge part.
    ram_g = arme(%{link: true}, 0x01, 0x81)
    {ram_g, gauche} = tick(gauche, ram_g)
    assert ram_g[:link_op] == :master_sent

    # La boucle de sonde réécrit SC=$81 (chaque frame, comme pokecrystal).
    ram_g = ram_g |> Map.put(:link, true) |> arme(0x01, 0x81)
    assert ram_g[:link_op] == :master_sent
    {ram_g, gauche} = tick(gauche, ram_g)
    {ram_g, gauche} = tick(gauche, ram_g)

    # UNE seule horloge sur le fil.
    assert {:ok, <<0, 0x01>>} = :gen_tcp.recv(droite.socket, 2, 200)
    assert {:error, :timeout} = :gen_tcp.recv(droite.socket, 2, 100)
    _ = {ram_g, gauche}
  end

  test "sans câble, la capture série de blargg reste intacte" do
    ram = arme(%{}, ?A, 0x81)
    assert IO.iodata_to_binary(Map.get(ram, :serial)) == "A"
    refute Map.has_key?(ram, :link_op)
  end
end
