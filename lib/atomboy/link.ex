defmodule Atomboy.Link do
  @moduledoc """
  Le câble link, en TCP : deux atomboy s'échangent leurs octets série.

  Sur le vrai câble, le maître (horloge interne, bit 0 de SC) cadence huit
  bits : son octet sort pendant que celui du partenaire entre — un échange,
  jamais un envoi. L'esclave attend d'être cadencé, indéfiniment. Ici, le
  fil est une socket et l'échange tient en deux messages de deux octets :

      <<0, octet>>   l'horloge du maître, son octet au bout
      <<1, octet>>   la réponse de l'esclave, son octet en retour

  Un côté écoute (`--ecoute [port]`), l'autre appelle (`--lien hôte:port`).
  La résolution vit à la frontière de frame des deux boucles de jeu :
  latence d'un aller-retour ≈ une frame de chaque côté — le rythme d'un
  échange Pokémon, pas celui d'une course.

  Le câble vit DANS la map mémoire (`ram[:link]`, la struct socket) et se
  résout à la **scanline** (`line/1`, appelé par `Screen.step_line`) : 154
  occasions par frame, une latence de quelques millisecondes — l'échelle du
  vrai matériel, dont le transfert maître se conclut en ~4 ms. C'est la
  condition de la négociation du Club Câble, dont la sonde n'attend pas
  une frame. Un maître sans réponse réessaie à la scanline suivante
  (`:master_sent` — l'horloge ne part qu'une fois) ; une seule horloge
  servie par passage — le jeu doit recharger SB entre deux ; un câble
  coupé conclut sur 0xFF et disparaît de la map, comme débranché.
  """

  import Bitwise

  @default_port 7373
  @sb 0xFF01
  @sc 0xFF02
  @if_addr 0xFF0F

  defstruct [:socket, :trace, :t0]

  @type t :: %__MODULE__{}

  @doc "Le port par défaut du câble."
  @spec default_port() :: pos_integer()
  def default_port, do: @default_port

  @doc """
  Écoute et attend le partenaire — bloquant, deux minutes. À lancer avant
  l'écran alternatif : le message d'attente doit se voir.
  """
  @spec listen(pos_integer()) :: {:ok, t()} | {:error, String.t()}
  def listen(port) do
    with {:ok, lsock} <-
           :gen_tcp.listen(port, [:binary, packet: :raw, active: false, reuseaddr: true]),
         IO.puts(:stderr, "câble link : en attente du partenaire sur le port #{port}…"),
         {:ok, socket} <- :gen_tcp.accept(lsock, 120_000) do
      :gen_tcp.close(lsock)
      :inet.setopts(socket, nodelay: true)
      IO.puts(:stderr, "câble link : partenaire branché.")
      {:ok, nouveau(socket)}
    else
      {:error, reason} -> {:error, "câble link : #{inspect(reason)}"}
    end
  end

  @doc "Appelle un partenaire qui écoute. Réessaie cinq secondes."
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
        IO.puts(:stderr, "câble link : branché sur #{host}:#{port}.")
        {:ok, nouveau(socket)}

      {:error, _} when tries > 1 ->
        Process.sleep(500)
        connect(host, port, tries - 1)

      {:error, reason} ->
        {:error, "câble link : #{host}:#{port} injoignable (#{inspect(reason)})"}
    end
  end

  # La trace série (ATOMBOY_LINK_TRACE=fichier) : chaque événement du câble,
  # horodaté en millisecondes — l'outil des protocoles qui se déchirent.
  defp nouveau(socket) do
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
  Une scanline de câble : résout l'opération série en attente et pompe au
  plus une horloge entrante. Sans câble dans la map, ne touche à rien ;
  un câble coupé s'efface de la map.
  """
  @spec line(map()) :: map()
  def line(ram) do
    case Map.get(ram, :link) do
      %__MODULE__{} = link ->
        ram = Map.update(ram, :link_ligne, 1, &(&1 + 1))

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

  @doc "Referme le câble."
  @spec close(t() | nil) :: :ok
  def close(nil), do: :ok

  def close(%__MODULE__{socket: socket}) do
    :gen_tcp.close(socket)
    :ok
  end

  # ── Le maître ───────────────────────────────────────────────────────────────

  defp clock_out(link, ram) do
    # LE FIL N'A QU'UN SLOT. Si une horloge est déjà en vol, ce nouveau
    # transfert la réutilise — les boucles de sonde des jeux réécrivent SC
    # chaque frame en alternant maître/esclave, et chaque réécriture qui
    # enverrait une horloge neuve inonde le fil : cinq horloges servies
    # dans la même milliseconde, la réponse décisive noyée (vécu, à la
    # trace). Une horloge, une réponse, toujours.
    if Map.get(ram, :link_wire) do
      await(link, Map.put(ram, :link_op, :master_sent))
    else
      clock_send(link, ram)
    end
  end

  defp clock_send(link, ram) do
    # Fil libre : toute réponse qui traîne est une vraie orpheline.
    case drain_stale(link) do
      :ok ->
        case :gen_tcp.send(link.socket, <<0, Map.get(ram, @sb, 0xFF)>>) do
          :ok ->
            trace(link, "M horloge → #{hex(Map.get(ram, @sb, 0xFF))}")

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
        # Le pair a cadencé aussi : deux maîtres, deux horloges qui se
        # croisent — sur le fil réel c'est du bruit électrique, pas un
        # échange. La nôtre part quand même (le pair conclura pareil en la
        # voyant), et chacun lit 0xFF : les jeux retentent leur
        # établissement jusqu'à ce qu'une sonde rencontre une vraie
        # fenêtre esclave. (Échanger proprement les octets croisés faisait
        # lire $01 aux DEUX sondes : chacune s'établissait esclave — le
        # sync « capricieux » du rapport.)
        case :gen_tcp.send(link.socket, <<0, Map.get(ram, @sb, 0xFF)>>) do
          :ok ->
            trace(link, "M croisé : bus indéterminé, FF")
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
        trace(link, "purge orpheline #{hex(stale)}")
        drain_stale(link)
      {:ok, <<0, byte>>} -> {:clock, byte}
      {:ok, _autre} -> drain_stale(link)
      {:error, :timeout} -> :ok
      {:error, _} -> :closed
    end
  end

  defp await(link, ram) do
    case :gen_tcp.recv(link.socket, 2, 0) do
      {:ok, <<1, byte>>} ->
        trace(link, "M reçu    ← #{hex(byte)}")
        {complete(ram, byte), link}

      {:ok, <<0, _byte>>} ->
        # Deux maîtres à la fois : du bruit, pas un échange — 0xFF, et
        # les jeux retentent. Personne ne répond (le pair conclut pareil
        # en voyant notre horloge) : aucune réponse orpheline.
        trace(link, "M croisé : bus indéterminé, FF")
        {complete(ram, 0xFF), link}

      {:error, :timeout} ->
        # Le matériel conclut toujours en ~4 ms ; un maître qui attend au-
        # delà de la retenue longue du pair a affaire à un partenaire
        # disparu — la ligne au repos, et le jeu gère.
        if System.monotonic_time(:millisecond) - Map.get(ram, :link_sent, 0) > 600 do
          trace(link, "M timeout : FF")
          {complete(ram, 0xFF), link}
        else
          {ram, link}
        end

      {:error, _} ->
        unplugged(ram)
    end
  end

  # ── L'esclave, et le repos ──────────────────────────────────────────────────

  # L'horloge du maître ne rencontre le SB de l'esclave QUE transfert armé
  # (bit 7 de SC) : non armé, la ligne série reste au repos et le maître
  # lit 0xFF — le silicium ne branche le registre qu'à la demande. Servir
  # le SB d'un non-armé (et l'écraser) fabriquait de fausses poignées de
  # main : la sonde $01 d'un joueur, recyclée par l'autre, se lisait comme
  # « partenaire maître détecté » (vécu, à la trace). UNE horloge par
  # frame : la réponse à la suivante attend que l'ISR ait rechargé SB.
  # Une horloge reçue pendant la fenêtre non armée est RETENUE : l'ISR de
  # l'esclave — retardée par le handler vblank ou la sieste de fin de
  # frame — va se réarmer, et l'octet ne doit pas se perdre (vécu : un
  # octet sauté, « SILER », l'équipe d'en face décalée). Passé le délai,
  # la ligne au repos répond 0xFF — la sémantique des sondes
  # d'établissement face à un partenaire hors mode lien.
  #
  # Deux patiences : courte avant l'établissement (les sondes doivent lire
  # 0xFF vite), longue après (:link_active) — en phase de menus le jeu ne
  # réarme que toutes les deux ou trois frames, et le vrai matériel, ISR
  # toujours armée, ne produirait jamais de FF là (vécu : « Dommage !
  # L'échange est annulé » pendant que le partenaire hésitait au menu).
  @retenue_ms 25
  @retenue_active_ms 400

  # Le transfert matériel dure huit bits à 8192 Hz ≈ 4194 cycles ≈ neuf
  # scanlines — et c'est cette durée qui, sur silicium, laisse à la boucle
  # principale de l'esclave le temps de copier hSerialReceive : l'ISR
  # ré-arme SC immédiatement, une cellule unique, aucune file. Servir dès
  # l'armement écrase l'octet précédent entre deux passages de la boucle
  # (vécu : octets avalés dans les blocs d'équipe, structures décalées,
  # « HERICENDRE a l'air bizarre ! », et le déraillement en VRAM du
  # rapport de crash — GetPokemonName sur une espèce fantôme).
  @cadence_lignes 9

  defp pump(link, ram) do
    case Map.get(ram, :link_held) do
      {byte, depuis} -> serve_held(link, ram, byte, depuis)
      nil -> pump_recv(link, ram)
    end
  end

  defp pump_recv(link, ram) do
    case :gen_tcp.recv(link.socket, 2, 0) do
      {:ok, <<0, byte>>} ->
        if Map.get(ram, :link_op) == :slave do
          serve(link, ram, byte)
        else
          trace(link, "E retient #{hex(byte)} (pas encore armé)")
          {Map.put(ram, :link_held, {byte, System.monotonic_time(:millisecond)}), link}
        end

      {:ok, <<1, byte>>} ->
        # La réponse d'une horloge abandonnée (le jeu a basculé esclave
        # entre-temps) : consommée, le fil se libère.
        trace(link, "réponse tardive #{hex(byte)} — fil libéré")
        pump_recv(link, Map.delete(ram, :link_wire))

      {:ok, _autre} ->
        pump_recv(link, ram)

      {:error, :timeout} ->
        {ram, link}

      {:error, _} ->
        unplugged(ram)
    end
  end

  defp serve_held(link, ram, byte, depuis) do
    cond do
      Map.get(ram, :link_op) == :slave ->
        serve(link, Map.delete(ram, :link_held), byte)

      System.monotonic_time(:millisecond) - depuis >
          if(Map.get(ram, :link_active), do: @retenue_active_ms, else: @retenue_ms) ->
        # Personne ne s'arme : la ligne au repos.
        case :gen_tcp.send(link.socket, <<1, 0xFF>>) do
          :ok ->
            trace(link, "E ← #{hex(byte)} → FF (repos, après retenue)")
            {Map.delete(ram, :link_held), link}

          {:error, _} ->
            unplugged(ram)
        end

      true ->
        {ram, link}
    end
  end

  defp serve(link, ram, byte) do
    ligne = Map.get(ram, :link_ligne, 0)

    if ligne - Map.get(ram, :link_servi, -@cadence_lignes) < @cadence_lignes do
      # Trop tôt après le service précédent : l'horloge patiente en
      # retenue, comme sur le fil réel où le transfert est encore en
      # train de cadencer ses bits.
      {Map.put_new(ram, :link_held, {byte, System.monotonic_time(:millisecond)}), link}
    else
      réponse = Map.get(ram, @sb, 0xFF)

      case :gen_tcp.send(link.socket, <<1, réponse>>) do
        :ok ->
          trace(link, "E ← #{hex(byte)} → #{hex(réponse)}")
          {complete(ram, byte) |> Map.put(:link_servi, ligne), link}

        {:error, _} ->
          unplugged(ram)
      end
    end
  end

  # ── La fin d'un transfert ───────────────────────────────────────────────────

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

  # Câble débranché : la ligne lit 0xFF, le transfert armé se conclut.
  defp unplugged(ram) do
    {complete(ram, 0xFF), nil}
  end
end
