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

  defstruct [:socket]

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
         IO.puts("câble link : en attente du partenaire sur le port #{port}…"),
         {:ok, socket} <- :gen_tcp.accept(lsock, 120_000) do
      :gen_tcp.close(lsock)
      :inet.setopts(socket, nodelay: true)
      IO.puts("câble link : partenaire branché.")
      {:ok, %__MODULE__{socket: socket}}
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
        IO.puts("câble link : branché sur #{host}:#{port}.")
        {:ok, %__MODULE__{socket: socket}}

      {:error, _} when tries > 1 ->
        Process.sleep(500)
        connect(host, port, tries - 1)

      {:error, reason} ->
        {:error, "câble link : #{host}:#{port} injoignable (#{inspect(reason)})"}
    end
  end

  @doc """
  Une scanline de câble : résout l'opération série en attente et pompe au
  plus une horloge entrante. Sans câble dans la map, ne touche à rien ;
  un câble coupé s'efface de la map.
  """
  @spec line(map()) :: map()
  def line(ram) do
    case Map.get(ram, :link) do
      %__MODULE__{} = link ->
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
    # Purger les réponses orphelines d'abord : aucune horloge à nous n'est
    # en vol, toute réponse en attente est un résidu de désynchronisation —
    # la consommer ici guérit le flux au lieu de perpétuer le décalage.
    case drain_stale(link) do
      :ok ->
        case :gen_tcp.send(link.socket, <<0, Map.get(ram, @sb, 0xFF)>>) do
          :ok -> await(link, %{ram | :link_op => :master_sent})
          {:error, _} -> unplugged(ram)
        end

      {:clock, byte} ->
        # Le pair a cadencé le premier : nos horloges se croisent — la
        # nôtre part quand même (il l'attend), et la sienne conclut chez
        # nous. L'échange des deux maîtres, sans réponse orpheline.
        case :gen_tcp.send(link.socket, <<0, Map.get(ram, @sb, 0xFF)>>) do
          :ok -> {complete(ram, byte), link}
          {:error, _} -> unplugged(ram)
        end

      :closed ->
        unplugged(ram)
    end
  end

  defp drain_stale(link) do
    case :gen_tcp.recv(link.socket, 2, 0) do
      {:ok, <<1, _stale>>} -> drain_stale(link)
      {:ok, <<0, byte>>} -> {:clock, byte}
      {:ok, _autre} -> drain_stale(link)
      {:error, :timeout} -> :ok
      {:error, _} -> :closed
    end
  end

  defp await(link, ram) do
    case :gen_tcp.recv(link.socket, 2, 0) do
      {:ok, <<1, byte>>} ->
        {complete(ram, byte), link}

      {:ok, <<0, byte>>} ->
        # Deux maîtres à la fois : les horloges qui se croisent SONT
        # l'échange — chacun conclut avec l'octet de l'autre, personne ne
        # répond. Répondre en plus laisserait une réponse orpheline dans
        # chaque socket : le flux se décale d'un cran et chaque console
        # finit par relire ses propres octets (vécu : Nolan qui s'échange
        # des Pokémon avec Nolan).
        {complete(ram, byte), link}

      {:error, :timeout} ->
        {ram, link}

      {:error, _} ->
        unplugged(ram)
    end
  end

  # ── L'esclave, et le repos ──────────────────────────────────────────────────

  # L'horloge du maître peut arriver que l'esclave soit armé ou non — le
  # matériel décale SB dans tous les cas ; l'interruption n'appartient qu'à
  # un transfert armé (bit 7 de SC). UNE horloge par frame, pas plus : la
  # réponse à la suivante doit attendre que le jeu ait digéré la précédente
  # (son ISR recharge SB) — répondre à deux d'affilée renverrait au maître
  # son propre octet (vécu : l'écho, côté esclave, sous turbo).
  defp pump(link, ram) do
    case :gen_tcp.recv(link.socket, 2, 0) do
      {:ok, <<0, byte>>} ->
        case :gen_tcp.send(link.socket, <<1, Map.get(ram, @sb, 0xFF)>>) do
          :ok ->
            ram =
              if Map.get(ram, :link_op) == :slave do
                complete(ram, byte)
              else
                Map.put(ram, @sb, byte)
              end

            {ram, link}

          {:error, _} ->
            unplugged(ram)
        end

      {:ok, _autre} ->
        pump(link, ram)

      {:error, :timeout} ->
        {ram, link}

      {:error, _} ->
        unplugged(ram)
    end
  end

  # ── La fin d'un transfert ───────────────────────────────────────────────────

  defp complete(ram, byte) do
    ram
    |> Map.put(@sb, byte)
    |> Map.put(@sc, Map.get(ram, @sc, 0) &&& 0x7F)
    |> Map.update(@if_addr, 0x08, &(&1 ||| 0x08))
    |> Map.delete(:link_op)
  end

  # Câble débranché : la ligne lit 0xFF, le transfert armé se conclut.
  defp unplugged(ram) do
    {complete(ram, 0xFF), nil}
  end
end
