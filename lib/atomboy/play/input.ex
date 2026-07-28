defmodule Atomboy.Play.Input do
  @moduledoc """
  Le clavier du terminal, décodé en événements de touches Game Boy.

  Le décodeur est un repli pur sur un tampon d'octets bruts : il consomme ce
  qu'il reconnaît, rend des événements, et garde en reste tout préfixe de
  séquence encore incomplet (une flèche peut arriver coupée en deux
  lectures).

  ## Deux mondes de terminaux

  Un terminal classique n'envoie que des *frappes* — lettres telles quelles,
  flèches en `ESC [ A` — jamais les relâchements ; et macOS ne répète que la
  dernière touche enfoncée. Impossible d'y tenir une diagonale. Ces
  encodages deviennent `{:key, touche}` : une frappe au relâchement inconnu,
  que la boucle transforme en pression tenue quelques frames.

  Le protocole clavier kitty (Ghostty, kitty, WezTerm…) envoie lui les
  événements complets — presse, répétition, relâchement, pour chaque touche :

      CSI code ; mods [: événement] u        lettres et touches nommées
      CSI 1 ; mods [: événement] A…D         flèches (presse nue : ESC [ A)

  événement 1 = presse, 2 = répétition, 3 = relâchement. Ils deviennent
  `{:press | :repeat | :release, touche}` : l'état réel du clavier, les
  diagonales et les accords A+direction avec. La réponse `CSI ? … u` à la
  requête d'activation devient `{:kitty, flags}` — le signe que le terminal
  parle le protocole.

  ## La disposition

      flèches          la croix
      x                A            (x et c : voisines en QWERTY comme en AZERTY)
      c                B
      Entrée           Start
      Espace           Select
      s / r            sauver / reprendre l'état
      Tab              turbo (avance rapide)
      p                pause
      q, Échap (kitty) ou Ctrl-C    quitter
  """

  import Bitwise

  @type key ::
          :up
          | :down
          | :left
          | :right
          | :a
          | :b
          | :start
          | :select
          | :quit
          | :save_state
          | :load_state
          | :turbo
          | :pause
  @type event ::
          {:key, key()}
          | {:press, key()}
          | {:repeat, key()}
          | {:release, key()}
          | {:kitty, non_neg_integer()}
          | {:graphics, boolean()}

  @arrows %{?A => :up, ?B => :down, ?C => :right, ?D => :left}

  # Codes CSI-u : le point de code de la touche, minuscule.
  @codes %{
    ?x => :a,
    ?c => :b,
    13 => :start,
    ?\s => :select,
    ?q => :quit,
    27 => :quit,
    ?s => :save_state,
    ?r => :load_state,
    9 => :turbo,
    ?p => :pause
  }

  @doc """
  Décode le tampon en événements. Renvoie `{événements, reste}` — le reste
  est un début de séquence d'échappement à compléter à la prochaine lecture.
  """
  @spec decode(binary()) :: {[event()], binary()}
  def decode(buffer), do: decode(buffer, [])

  # CSI : ESC [ paramètres octet-final. Les paramètres restent dans 0x20-0x3F.
  defp decode(<<"\e[", rest::binary>> = all, events) do
    case csi(rest, "") do
      {params, final, rest} -> decode(rest, csi_events(params, final) ++ events)
      :partial -> {Enum.reverse(events), all}
    end
  end

  # APC : ESC _ … ESC \ — les réponses du protocole graphique kitty.
  # « OK » après le point-virgule = le terminal sait afficher des images.
  defp decode(<<"\e_", rest::binary>> = all, events) do
    case :binary.split(rest, "\e\\") do
      [payload, rest] ->
        ok? = String.contains?(payload, ";OK")
        decode(rest, [{:graphics, ok?} | events])

      _ ->
        {Enum.reverse(events), all}
    end
  end

  # SS3 : ESC O lettre — les flèches du mode application.
  defp decode(<<?\e, ?O, final, rest::binary>>, events) when is_map_key(@arrows, final),
    do: decode(rest, [{:key, @arrows[final]} | events])

  # Une séquence coupée en plein vol : attendre la suite.
  defp decode(<<?\e, o>>, events) when o in ~c"[O_", do: {Enum.reverse(events), <<?\e, o>>}
  defp decode(<<"\e">>, events), do: {Enum.reverse(events), "\e"}
  # Échappement suivi d'autre chose : ignoré.
  defp decode(<<"\e", _, rest::binary>>, events), do: decode(rest, events)

  defp decode(<<c, rest::binary>>, events) when c in [?x, ?X],
    do: decode(rest, [{:key, :a} | events])

  defp decode(<<c, rest::binary>>, events) when c in [?c, ?C],
    do: decode(rest, [{:key, :b} | events])

  defp decode(<<c, rest::binary>>, events) when c in [?\r, ?\n],
    do: decode(rest, [{:key, :start} | events])

  defp decode(<<?\s, rest::binary>>, events), do: decode(rest, [{:key, :select} | events])

  defp decode(<<c, rest::binary>>, events) when c in [?q, ?Q, 0x03],
    do: decode(rest, [{:key, :quit} | events])

  defp decode(<<c, rest::binary>>, events) when c in [?s, ?S],
    do: decode(rest, [{:key, :save_state} | events])

  defp decode(<<c, rest::binary>>, events) when c in [?r, ?R],
    do: decode(rest, [{:key, :load_state} | events])

  defp decode(<<?\t, rest::binary>>, events), do: decode(rest, [{:key, :turbo} | events])

  defp decode(<<c, rest::binary>>, events) when c in [?p, ?P],
    do: decode(rest, [{:key, :pause} | events])

  # Tout le reste du clavier : silence.
  defp decode(<<_, rest::binary>>, events), do: decode(rest, events)
  defp decode(<<>>, events), do: {Enum.reverse(events), ""}

  # ── La séquence CSI, découpée ───────────────────────────────────────────────

  defp csi(<<c, rest::binary>>, params) when c in ?0..?9 or c in ~c";:?",
    do: csi(rest, <<params::binary, c>>)

  defp csi(<<final, rest::binary>>, params) when final in 0x40..0x7E,
    do: {params, final, rest}

  defp csi(<<>>, _params), do: :partial
  defp csi(_other, _params), do: :partial

  # ── Les événements d'une séquence ───────────────────────────────────────────

  # Flèche nue : une frappe, régime inconnu — la boucle tranche.
  defp csi_events("", final) when is_map_key(@arrows, final), do: [{:key, @arrows[final]}]

  # Flèche paramétrée : « 1;mods:événement » — le protocole kitty.
  defp csi_events(params, final) when is_map_key(@arrows, final) do
    tag(parse_event(params), @arrows[final])
  end

  # CSI-u : « code;mods:événement u » — chaque touche du protocole kitty.
  defp csi_events(<<??, params::binary>>, ?u), do: [{:kitty, flags(params)}]

  defp csi_events(params, ?u) do
    [code | mods] = String.split(params, ";")

    with {code, ""} <- Integer.parse(code),
         key when key != nil <- Map.get(@codes, code) do
      key = if ctrl?(mods) and code == ?c, do: :quit, else: key
      tag(parse_event(params), key)
    else
      _ -> []
    end
  end

  defp csi_events(_params, _final), do: []

  defp tag(1, key), do: [{:press, key}]
  defp tag(2, key), do: [{:repeat, key}]
  defp tag(3, key), do: [{:release, key}]
  defp tag(_, _key), do: []

  # L'événement vit après le « : » du champ modificateurs ; absent = presse.
  defp parse_event(params) do
    case String.split(params, ":") do
      [_, event | _] ->
        case Integer.parse(event) do
          {n, _} -> n
          _ -> 1
        end

      _ ->
        1
    end
  end

  # Modificateurs = 1 + masque ; Ctrl = bit 4.
  defp ctrl?([mods | _]) do
    case Integer.parse(mods) do
      {n, _} -> (n - 1 &&& 4) != 0
      _ -> false
    end
  end

  defp ctrl?(_), do: false

  defp flags(params) do
    case Integer.parse(params) do
      {n, _} -> n
      _ -> 0
    end
  end

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
      if key in held, do: band(lines, bnot(bit)), else: lines
    end)
  end
end
