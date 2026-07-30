defmodule Atomboy.Menu do
  @moduledoc """
  Le menu en surimpression — dessiné DANS la frame 160×144.

  Une seule implémentation pour les deux façades : le menu se rend en
  pixels dans la frame brute (teintes DMG ou RGB555 CGB), et le rendu
  habituel — terminal ou fenêtre — l'affiche sans rien savoir de lui.
  Échap ou `m` l'ouvre, la machine dort pendant qu'il est là ; flèches
  pour naviguer et régler, A pour agir, B ou Échap pour reprendre.

  Le menu ne touche à rien lui-même : `touche/2` rend des *actions*
  (`:save_state`, `{:slot, n}`, `{:palette, p}`, `:quit`…) que la boucle
  hôte applique avec les mêmes chemins que les raccourcis directs.
  """

  alias Atomboy.Menu.Font

  defstruct curseur: 0,
            page: :principal,
            slot: 1,
            palette: :dmg,
            couleur: false,
            mixer: %{volume: 100, voices: {true, true, true, true}}

  @type mixer :: %{volume: 0..100, voices: {boolean(), boolean(), boolean(), boolean()}}

  @type action ::
          :resume
          | :save_state
          | :load_state
          | {:slot, 1..9}
          | {:palette, :dmg | :gray}
          | {:mixer, mixer()}
          | :quit

  @type t :: %__MODULE__{}

  @doc "Le mixer neutre : plein volume, les quatre voix ouvertes."
  @spec mixer_default() :: mixer()
  def mixer_default, do: %{volume: 100, voices: {true, true, true, true}}

  @doc """
  Ouvre le menu sur l'état courant de la boucle hôte. `couleur` masque le
  choix de palette — elle ne teinte que les frames DMG.
  """
  @spec open(1..9, :dmg | :gray, boolean(), mixer()) :: t()
  def open(slot, palette, couleur \\ false, mixer \\ nil),
    do: %__MODULE__{
      curseur: 0,
      slot: slot,
      palette: palette,
      couleur: couleur,
      mixer: mixer || mixer_default()
    }

  defp items(%{page: :mixer}), do: [:volume, :voices1, :voices2, :voices3, :voices4, :retour]
  defp items(%{couleur: true}), do: [:reprendre, :sauver, :charger, :case, :mixer, :quitter]
  defp items(_menu), do: [:reprendre, :sauver, :charger, :case, :palette, :mixer, :quitter]

  @doc """
  Une touche dans le menu. Rend `{menu, actions}` — `menu` à `nil` quand
  il se ferme, `actions` la liste (souvent vide) à appliquer par l'hôte.
  """
  @spec press(t(), atom()) :: {t() | nil, [action()]}
  def press(menu, :up) do
    n = length(items(menu))
    {%{menu | curseur: rem(menu.curseur + n - 1, n)}, []}
  end

  def press(menu, :down),
    do: {%{menu | curseur: rem(menu.curseur + 1, length(items(menu)))}, []}

  def press(menu, :left), do: ajuste(menu, -1)
  def press(menu, :right), do: ajuste(menu, 1)

  def press(menu, :a) do
    case Enum.at(items(menu), menu.curseur) do
      :reprendre -> {nil, []}
      :sauver -> {nil, [:save_state]}
      :charger -> {nil, [:load_state]}
      :case -> ajuste(menu, 1)
      :palette -> ajuste(menu, 1)
      :mixer -> {%{menu | page: :mixer, curseur: 0}, []}
      :retour -> {%{menu | page: :principal, curseur: 0}, []}
      :quitter -> {nil, [:quit]}
      _voix -> ajuste(menu, 1)
    end
  end

  # B remonte d'une page ; à la racine, il ferme — comme Échap.
  def press(%{page: :mixer} = menu, key) when key in [:b, :menu],
    do: {%{menu | page: :principal, curseur: 0}, []}

  def press(_menu, key) when key in [:b, :menu], do: {nil, []}
  def press(menu, _key), do: {menu, []}

  defp ajuste(menu, sens) do
    case Enum.at(items(menu), menu.curseur) do
      :case ->
        slot = menu.slot + sens

        slot =
          cond do
            slot < 1 -> 9
            slot > 9 -> 1
            true -> slot
          end

        {%{menu | slot: slot}, [{:slot, slot}]}

      :palette ->
        palette = if menu.palette == :dmg, do: :gray, else: :dmg
        {%{menu | palette: palette}, [{:palette, palette}]}

      :volume ->
        volume = min(100, max(0, menu.mixer.volume + sens * 10))
        mixer = %{menu.mixer | volume: volume}
        {%{menu | mixer: mixer}, [{:mixer, mixer}]}

      voix when voix in [:voices1, :voices2, :voices3, :voices4] ->
        i = %{voices1: 0, voices2: 1, voices3: 2, voices4: 3}[voix]
        voies = put_elem(menu.mixer.voices, i, not elem(menu.mixer.voices, i))
        mixer = %{menu.mixer | voices: voies}
        {%{menu | mixer: mixer}, [{:mixer, mixer}]}

      _ ->
        {menu, []}
    end
  end

  # ── Le rendu ────────────────────────────────────────────────────────────────

  @largeur 160
  @hauteur 144
  @boite_l 112
  @ligne_h 11
  @marge 8

  @doc """
  Compose le menu sur une frame brute — teintes 1 octet ou RGB555 2
  octets, détecté à la taille. Rend la frame composée, même format.
  """
  @spec render(t(), binary()) :: binary()
  def render(menu, frame) do
    lignes = étiquettes(menu)
    boite_h = length(lignes) * @ligne_h + 2 * @marge
    x0 = div(@largeur - @boite_l, 2)
    y0 = div(@hauteur - boite_h, 2)

    encre = pixels_encre(menu, lignes, x0, y0)
    octets = div(byte_size(frame), @largeur * @hauteur)
    compose(frame, octets, x0, y0, boite_h, encre)
  end

  defp étiquettes(menu) do
    Enum.map(items(menu), fn
      :reprendre -> "REPRENDRE"
      :sauver -> "SAUVER L'ETAT"
      :charger -> "CHARGER L'ETAT"
      :case -> "CASE D'ETAT <#{menu.slot}>"
      :palette -> "PALETTE <#{if menu.palette == :dmg, do: "VERTE", else: "GRISE"}>"
      :mixer -> "MIXER"
      :volume -> "VOLUME <#{menu.mixer.volume}>"
      :voices1 -> "PULSE 1 <#{on_off(menu, 0)}>"
      :voices2 -> "PULSE 2 <#{on_off(menu, 1)}>"
      :voices3 -> "WAVE <#{on_off(menu, 2)}>"
      :voices4 -> "BRUIT <#{on_off(menu, 3)}>"
      :retour -> "RETOUR"
      :quitter -> "QUITTER"
    end)
  end

  defp on_off(menu, i), do: if(elem(menu.mixer.voices, i), do: "OUI", else: "NON")

  # Tous les pixels d'encre (bordure + texte + curseur) de la boîte.
  defp pixels_encre(menu, lignes, x0, y0) do
    boite_h = length(lignes) * @ligne_h + 2 * @marge

    bordure =
      for x <- x0..(x0 + @boite_l - 1), y <- [y0, y0 + 1, y0 + boite_h - 2, y0 + boite_h - 1], into: %{} do
        {{x, y}, true}
      end

    bordure =
      for y <- y0..(y0 + boite_h - 1), x <- [x0, x0 + 1, x0 + @boite_l - 2, x0 + @boite_l - 1], into: bordure do
        {{x, y}, true}
      end

    lignes
    |> Enum.with_index()
    |> Enum.reduce(bordure, fn {texte, i}, acc ->
      y = y0 + @marge + i * @ligne_h
      texte = if i == menu.curseur, do: "▶ " <> texte, else: "  " <> texte
      Map.merge(acc, Font.pixels(texte, x0 + 6, y))
    end)
  end

  # Recompose la frame rangée par rangée : hors boîte, la rangée d'origine
  # telle quelle ; dans la boîte, papier clair et encre sombre.
  defp compose(frame, octets, x0, y0, boite_h, encre) do
    ligne_octets = @largeur * octets

    for y <- 0..(@hauteur - 1), into: <<>> do
      rangée = binary_part(frame, y * ligne_octets, ligne_octets)

      if y < y0 or y >= y0 + boite_h do
        rangée
      else
        gauche = binary_part(rangée, 0, x0 * octets)
        droite = binary_part(rangée, (x0 + @boite_l) * octets, (@largeur - x0 - @boite_l) * octets)

        boite =
          for x <- x0..(x0 + @boite_l - 1), into: <<>> do
            couleur(octets, Map.has_key?(encre, {x, y}))
          end

        gauche <> boite <> droite
      end
    end
  end

  # Papier et encre dans les deux formats : teinte 0/3 en DMG, blanc et
  # noir RGB555 (petit-boutiste) en couleur.
  defp couleur(1, true), do: <<3>>
  defp couleur(1, false), do: <<0>>
  defp couleur(2, true), do: <<0x00, 0x00>>
  defp couleur(2, false), do: <<0xFF, 0x7F>>
end
