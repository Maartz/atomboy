defmodule Atomboy.Play.Input do
  @moduledoc """
  Le clavier du terminal, décodé en touches Game Boy.

  En mode raw, le terminal livre des octets bruts : les lettres telles
  quelles, les flèches en séquences CSI (`ESC [ A` …) qui peuvent arriver
  coupées en deux lectures. Le décodeur est donc un repli pur sur un tampon :
  il consomme ce qu'il reconnaît, rend les touches, et garde en reste tout
  préfixe de séquence encore incomplet.

  ## La disposition

      flèches          la croix
      x                A            (x et c : voisines en QWERTY comme en AZERTY)
      c                B
      Entrée           Start
      Espace           Select
      q ou Ctrl-C      quitter

  Un terminal ne signale jamais le relâchement d'une touche — c'est la boucle
  de jeu qui transforme chaque frappe en pression tenue quelques frames.
  """

  @type key :: :up | :down | :left | :right | :a | :b | :start | :select | :quit

  @doc """
  Décode le tampon en touches. Renvoie `{touches, reste}` — le reste est un
  début de séquence d'échappement à compléter à la prochaine lecture.
  """
  @spec decode(binary()) :: {[key()], binary()}
  def decode(buffer), do: decode(buffer, [])

  # Les flèches, en mode normal (CSI) comme en mode application (SS3).
  defp decode(<<?\e, o, ?A, rest::binary>>, keys) when o in ~c"[O", do: decode(rest, [:up | keys])

  defp decode(<<?\e, o, ?B, rest::binary>>, keys) when o in ~c"[O",
    do: decode(rest, [:down | keys])

  defp decode(<<?\e, o, ?C, rest::binary>>, keys) when o in ~c"[O",
    do: decode(rest, [:right | keys])

  defp decode(<<?\e, o, ?D, rest::binary>>, keys) when o in ~c"[O",
    do: decode(rest, [:left | keys])

  # Une séquence coupée en plein vol : attendre la suite.
  defp decode(<<?\e, o>>, keys) when o in ~c"[O", do: {Enum.reverse(keys), <<?\e, o>>}
  defp decode(<<"\e">>, keys), do: {Enum.reverse(keys), "\e"}
  # Échappement suivi d'autre chose qu'une flèche : ignoré.
  defp decode(<<"\e", _, rest::binary>>, keys), do: decode(rest, keys)

  defp decode(<<c, rest::binary>>, keys) when c in [?x, ?X], do: decode(rest, [:a | keys])
  defp decode(<<c, rest::binary>>, keys) when c in [?c, ?C], do: decode(rest, [:b | keys])
  defp decode(<<c, rest::binary>>, keys) when c in [?\r, ?\n], do: decode(rest, [:start | keys])
  defp decode(<<?\s, rest::binary>>, keys), do: decode(rest, [:select | keys])
  defp decode(<<c, rest::binary>>, keys) when c in [?q, ?Q, 0x03], do: decode(rest, [:quit | keys])

  # Tout le reste du clavier : silence.
  defp decode(<<_, rest::binary>>, keys), do: decode(rest, keys)
  defp decode(<<>>, keys), do: {Enum.reverse(keys), ""}

  @doc """
  Le quartet d'une nappe depuis l'ensemble des touches tenues — à 1 = relâché,
  comme les lignes du registre.
  """
  @spec dpad_lines(Enumerable.t(key())) :: 0..15
  def dpad_lines(held) do
    lines(held, [{:right, 0x01}, {:left, 0x02}, {:up, 0x04}, {:down, 0x08}])
  end

  @spec button_lines(Enumerable.t(key())) :: 0..15
  def button_lines(held) do
    lines(held, [{:a, 0x01}, {:b, 0x02}, {:select, 0x04}, {:start, 0x08}])
  end

  defp lines(held, bits) do
    Enum.reduce(bits, 0x0F, fn {key, bit}, lines ->
      if key in held, do: Bitwise.band(lines, Bitwise.bnot(bit)), else: lines
    end)
  end
end
