defmodule Potion.ROM do
  @moduledoc """
  L'assemblage de la cartouche : d'un programme à une ROM que le matériel
  accepterait.

  ## Ce que le boot exige

  La ROM de boot du DMG ne fait confiance à rien : elle recopie le logo
  Nintendo depuis l'en-tête (0x104-0x133), le compare au sien, vérifie la
  somme de contrôle des octets 0x134-0x14C — et gèle la machine si l'un des
  deux ment. Atomboy, lui, saute la ROM de boot et n'exige rien de tout ça ;
  mais Potion vise la vraie Game Boy via flashcart, et une ROM qui ne
  passerait que dans notre émulateur serait une preuve au rabais. On écrit
  donc l'en-tête complet, sommes comprises, dès la première ROM.

  La somme globale (0x14E-0x14F, gros-boutien — la seule valeur gros-boutienne
  de toute la console) n'est vérifiée par rien, pas même le matériel. On la
  calcule quand même : elle est le hash d'intégrité que les outils tiers
  affichent, et un champ faux se voit.

  ## La carte de la cartouche

      0x0000-0x00FF   vecteurs RST et interruptions — zéros, sauf le vecteur
                      vblank (0x40) si le programme en donne un
      0x0100          le point d'entrée : NOP puis JP 0x150
      0x0104-0x0133   le logo Nintendo, au bit près
      0x0134-0x0143   le titre, ASCII majuscule ; 0x143 reste 0x00 — une ROM
                      Potion est DMG, la couleur attendra que le langage
                      tienne debout
      0x0147-0x0149   type 0x00 (ROM seule, sans MBC), 32 Ko, pas de RAM
      0x014D          la somme d'en-tête que le boot vérifie
      0x014E-0x014F   la somme globale
      0x0150-0x7FFF   le programme, assemblé par `Potion.Assembleur`,
                      puis du remplissage

  32 Ko sans MBC : le plus petit format qui existe, et `Atomboy.Screen`
  en déduit deux banques plates — aucun registre de banque à émuler pour
  les premières ROMs du langage.
  """

  import Bitwise

  alias Potion.Assembleur

  # Les 48 octets que la ROM de boot compare aux siens. Ils dessinent le mot
  # « Nintendo » — c'était le verrou juridique de la console : les graver dans
  # une cartouche pirate, c'était contrefaire la marque.
  @logo <<0xCE, 0xED, 0x66, 0x66, 0xCC, 0x0D, 0x00, 0x0B, 0x03, 0x73, 0x00, 0x83, 0x00, 0x0C,
          0x00, 0x0D, 0x00, 0x08, 0x11, 0x1F, 0x88, 0x89, 0x00, 0x0E, 0xDC, 0xCC, 0x6E, 0xE6,
          0xDD, 0xDD, 0xD9, 0x99, 0xBB, 0xBB, 0x67, 0x63, 0x6E, 0x0E, 0xEC, 0xCC, 0xDD, 0xDC,
          0x99, 0x9F, 0xBB, 0xB9, 0x33, 0x3E>>

  @taille 0x8000
  @origine 0x0150
  @place @taille - @origine

  @doc """
  Construit une ROM de 32 Ko autour d'un programme `Potion.Assembleur`.

  Options :

    * `:titre` — le nom dans l'en-tête, quinze caractères ASCII au plus,
      passé en majuscules. Par défaut `"POTION"`.
    * `:vblank` — le nom d'une étiquette du programme ; le vecteur 0x40
      devient un `JP` vers elle. Sans elle, une interruption vblank armée
      exécuterait des zéros — c'est-à-dire des `NOP` jusqu'à dérailler.
  """
  @spec construit([Assembleur.element()], keyword()) :: binary()
  def construit(programme, opts \\ []) do
    titre = opts |> Keyword.get(:titre, "POTION") |> titre!()
    code = Assembleur.assemble(programme, origine: @origine)

    if byte_size(code) > @place do
      raise ArgumentError,
            "programme trop grand : #{byte_size(code)} octets pour #{@place} " <>
              "disponibles entre 0x0150 et 0x7FFF — les banques MBC restent à écrire"
    end

    vecteurs = vecteurs(programme, Keyword.get(opts, :vblank))

    corps =
      vecteurs <>
        <<0x00, 0xC3, @origine::16-little>> <>
        @logo <>
        titre <>
        :binary.copy(<<0x00>>, 0x14D - 0x144)

    en_tete = corps <> <<somme_en_tete(corps)>>
    rembourre = en_tete <> <<0, 0>> <> code <> :binary.copy(<<0x00>>, @place - byte_size(code))

    somme = somme_globale(rembourre)
    binary_part(rembourre, 0, 0x14E) <> <<somme::16-big>> <> binary_part(rembourre, 0x150, @place)
  end

  # Les 256 premiers octets : zéros, sauf le vecteur vblank demandé. Les
  # zéros sont des NOP inoffensifs tant qu'aucune interruption n'est armée.
  defp vecteurs(_programme, nil), do: :binary.copy(<<0x00>>, 0x100)

  defp vecteurs(programme, etiquette) do
    adresses = Assembleur.adresses(programme, origine: @origine)

    cible =
      case adresses do
        %{^etiquette => adresse} ->
          adresse

        _ ->
          raise ArgumentError,
                "vecteur vblank : l'étiquette #{inspect(etiquette)} n'existe pas " <>
                  "dans le programme"
      end

    :binary.copy(<<0x00>>, 0x40) <>
      <<0xC3, cible::16-little>> <>
      :binary.copy(<<0x00>>, 0x100 - 0x43)
  end

  defp titre!(titre) do
    majuscule = String.upcase(titre)

    cond do
      byte_size(majuscule) > 15 ->
        raise ArgumentError,
              "titre trop long : #{inspect(titre)} fait #{byte_size(titre)} caractères, " <>
                "l'en-tête n'en loge que quinze"

      not (majuscule |> String.to_charlist() |> Enum.all?(&(&1 in 0x20..0x7E))) ->
        raise ArgumentError,
              "titre hors ASCII : #{inspect(titre)} — l'en-tête d'une cartouche ne " <>
                "connaît pas les accents"

      true ->
        majuscule <> :binary.copy(<<0x00>>, 16 - byte_size(majuscule))
    end
  end

  # La somme que la ROM de boot vérifie : x = x - octet - 1 sur 0x134-0x14C.
  # `corps` s'arrête juste avant 0x14D, donc sa fin EST la plage sommée.
  defp somme_en_tete(corps) do
    corps
    |> binary_part(0x134, 0x14D - 0x134)
    |> :binary.bin_to_list()
    |> Enum.reduce(0, fn octet, somme -> somme - octet - 1 &&& 0xFF end)
  end

  # La somme de tous les octets, sauf ses deux propres cases (ici encore à
  # zéro, donc sommer tout revient au même).
  defp somme_globale(rom) do
    rom |> :binary.bin_to_list() |> Enum.sum() |> band(0xFFFF)
  end
end
