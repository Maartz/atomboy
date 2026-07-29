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

  `tick/2` est le seul point de contact des boucles : il résout l'opération
  série en attente (posée par CartLoop sous `:link_op`) et pompe les
  horloges entrantes. Un maître sans réponse réessaie à la frame suivante
  (`:master_sent` — l'horloge ne part qu'une fois) ; un câble coupé conclut
  l'échange sur 0xFF, comme un câble débranché.
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
  Une frame de câble : résout l'opération série en attente et pompe les
  horloges entrantes. Renvoie `{ram, link}` — link `nil` si le câble tombe.
  """
  @spec tick(t() | nil, map()) :: {map(), t() | nil}
  def tick(nil, ram), do: {ram, nil}

  def tick(link, ram) do
    case Map.get(ram, :link_op) do
      :master -> clock_out(link, ram)
      :master_sent -> await(link, ram)
      _ -> pump(link, ram)
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
    case :gen_tcp.send(link.socket, <<0, Map.get(ram, @sb, 0xFF)>>) do
      :ok -> await(link, %{ram | :link_op => :master_sent})
      {:error, _} -> unplugged(ram)
    end
  end

  defp await(link, ram) do
    case :gen_tcp.recv(link.socket, 2, 30) do
      {:ok, <<1, byte>>} ->
        {complete(ram, byte), link}

      {:ok, <<0, byte>>} ->
        # Deux maîtres à la fois : on répond, et son octet vaut réponse.
        :gen_tcp.send(link.socket, <<1, Map.get(ram, @sb, 0xFF)>>)
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
  # un transfert armé (bit 7 de SC).
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

            pump(link, ram)

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
