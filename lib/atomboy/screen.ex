defmodule Atomboy.Screen do
  @moduledoc """
  La boucle de frame : le CPU avance scanline par scanline, LY vit, le PPU
  rend.

  C'est la structure que le brief prévoyait : le CPU tourne pour 456 T-cycles
  — une scanline — puis le matériel simulé avance d'un cran. Ici « le matériel »
  se réduit à LY (0xFF44), que les jeux scrutent pour attendre le vblank ; le
  registre est écrit dans la map entre deux tranches, exactement là où le PPU
  de la phase 3 viendra se brancher.

  Le rendu se fait ligne à ligne pendant la partie visible de la dernière
  frame demandée — les registres de défilement sont donc lus à la scanline,
  comme sur la dalle, pas figés en fin de frame.
  """

  import Bitwise

  alias Atomboy.CPU.CartLoop
  alias Atomboy.CPU.State
  alias Atomboy.PPU

  @line_cycles 456
  @visible 144
  @lines 154

  @doc """
  Exécute `frames` frames depuis l'état de démarrage et rend la dernière.

  Renvoie `{frame, state, ram}`.
  """
  @spec run(Path.t(), pos_integer(), keyword()) :: {PPU.frame(), State.t(), map()}
  def run(rom_path, frames, opts \\ []) do
    rom = load(rom_path)
    dmg? = Keyword.get(opts, :dmg, false)
    state = boot_state(rom, dmg?)
    ram = boot_ram(rom, dmg?)

    Enum.reduce(1..frames, {<<>>, state, ram}, fn frame_index, {_frame, state, ram} ->
      render? = frame_index == frames
      frame(state, rom, ram, render?)
    end)
  end

  @doc """
  L'état des registres à la sortie de la ROM de boot DMG — le point de départ
  de tout jeu.
  """
  @spec boot_state() :: State.t()
  def boot_state do
    %State{
      a: 0x01,
      f: 0xB0,
      b: 0x00,
      c: 0x13,
      d: 0x00,
      e: 0xD8,
      h: 0x01,
      l: 0x4D,
      sp: 0xFFFE,
      pc: 0x0100
    }
  end

  @doc """
  La map mémoire de départ : nombre de banques, famille de MBC (en-tête
  0x147 : MBC3 pour 0x0F-0x13, MBC5 pour 0x19-0x1E, MBC1 sinon) et mode
  couleur (0x143 : 0x80 « enhanced », 0xC0 « only »).

  `dmg?` force la machine monochrome — l'équivalent de glisser la
  cartouche dans une vraie DMG.
  """
  @spec boot_ram(binary(), boolean()) :: map()
  def boot_ram(rom, dmg? \\ false) do
    mbc =
      case :binary.at(rom, 0x147) do
        t when t in 0x0F..0x13 -> :mbc3
        t when t in 0x19..0x1E -> :mbc5
        _ -> :mbc1
      end

    base = %{rom_banks: div(byte_size(rom), 0x4000), mbc: mbc}

    if not dmg? and :binary.at(rom, 0x143) in [0x80, 0xC0] do
      Map.put(base, :cgb, true)
    else
      base
    end
  end

  @doc """
  L'état de boot selon la cartouche : A vaut 0x11 sur Game Boy Color —
  c'est ainsi que les jeux « enhanced » choisissent leurs couleurs.
  """
  @spec boot_state(binary(), boolean()) :: State.t()
  def boot_state(rom, dmg? \\ false) do
    if not dmg? and :binary.at(rom, 0x143) in [0x80, 0xC0] do
      %{boot_state() | a: 0x11}
    else
      boot_state()
    end
  end

  @doc """
  Une frame de machine : 154 scanlines, rendues si `render?`.
  Renvoie `{pixels, state, ram}` — pixels vide sans rendu.
  """
  @spec frame(State.t(), binary(), map(), boolean()) :: {PPU.frame(), State.t(), map()}
  def frame(state, rom, ram, render?) do
    {pixels, state, ram, _window_line} =
      Enum.reduce(0..(@lines - 1), {<<>>, state, ram, 0}, fn ly,
                                                             {pixels, state, ram, window_line} ->
        {state, ram} = step_line(state, rom, ram, ly)

        if render? and ly < @visible do
          {line, window_line} = PPU.render_line(ram, ly, window_line)
          {pixels <> line, state, ram, window_line}
        else
          {pixels, state, ram, window_line}
        end
      end)

    {pixels, state, ram}
  end

  @doc """
  Une scanline de machine : LY avance, le vblank se lève à la ligne 144, le
  CPU tourne 456 T-cycles, le timer les rattrape. La brique commune de toute
  boucle de frame — Screen, le runner blargg, et la phase 3 un jour.
  """
  @spec step_line(State.t(), binary(), map(), 0..153) :: {State.t(), map()}
  def step_line(state, rom, ram, ly) do
    lcd_on? = band(Map.get(ram, 0xFF40, 0x91), 0x80) != 0
    ram = ppu_line(ram, ly, lcd_on?)

    # En double vitesse (KEY1, GBC), le CPU avale deux fois plus de cycles
    # par scanline — le PPU, lui, garde son rythme.
    budget = @line_cycles * Map.get(ram, :speed, 1)
    {state, ram, cycles} = CartLoop.run(state, rom, ram, budget)

    # Le GDMA posé pendant la ligne se consomme aussitôt la ligne finie —
    # au pire 456 cycles de retard sur le matériel, qui copie sur-le-champ.
    ram = gdma(rom, ram)
    ram = hdma(rom, ram, ly, lcd_on?)

    # Le câble link se résout à la scanline — la latence du vrai matériel.
    ram = if :erlang.is_map_key(:link, ram), do: Atomboy.Link.line(ram), else: ram
    {state, Atomboy.Timer.advance(ram, cycles)}
  end

  # Le transfert général (GDMA) : posé par l'écriture de HDMA5, exécuté ici
  # — la source peut être en ROM banquée, que seule cette boucle a en main.
  defp gdma(rom, ram) do
    case Map.get(ram, :gdma) do
      nil ->
        ram

      {src, dst, blocks} ->
        ram = copy(rom, Map.delete(ram, :gdma), src, dst, blocks * 16)
        ram
    end
  end

  # Le HDMA : un bloc de seize octets par HBlank de ligne visible, écran
  # allumé. Fini, HDMA5 relit 0xFF.
  defp hdma(rom, ram, ly, lcd_on?) do
    case Map.get(ram, :hdma) do
      {src, dst, blocks} when lcd_on? and ly < @visible ->
        ram = copy(rom, ram, src, dst, 16)

        if blocks == 1 do
          ram |> Map.delete(:hdma) |> Map.put(0xFF55, 0xFF)
        else
          Map.put(ram, :hdma, {src + 16, dst + 16, blocks - 1})
        end

      _ ->
        ram
    end
  end

  defp copy(rom, ram, src, dst, len) do
    Enum.reduce(0..(len - 1), ram, fn i, ram ->
      CartLoop.poke(ram, dst + i, CartLoop.peek(rom, ram, src + i))
    end)
  end

  # Écran éteint : le PPU ne balaye plus. LY reste à zéro, aucun vblank, aucune
  # coïncidence — le matériel arrête le générateur, pas seulement l'affichage.
  #
  # C'est un piège à conséquences lointaines : les jeux éteignent l'écran pour
  # recharger la VRAM (Pokémon le fait à chaque changement de carte, escaliers
  # compris) et continuent d'appeler leur moteur sonore depuis la boucle
  # principale, interruptions ouvertes. Un vblank fantôme rappelle alors ce
  # moteur par-dessus lui-même : son compteur de canaux, partagé, repart de
  # zéro, la boucle extérieure ne s'arrête plus à huit, son pointeur de
  # structure marche jusque dans la pile, et le CPU finit par exécuter du
  # texte de dialogue — l'opcode illégal E3, à des secondes de sa cause.
  defp ppu_line(ram, _ly, false) do
    ram
    |> Map.put(0xFF44, 0)
    |> Map.put(0xFF41, band(Map.get(ram, 0xFF41, 0), 0xF8))
  end

  defp ppu_line(ram, ly, true) do
    ram = Map.put(ram, 0xFF44, ly)

    # L'entrée en vblank lève le bit 0 d'IF — l'interruption que les jeux
    # attendent pour toucher la VRAM. Le service lui-même vit dans le fetch
    # de la boucle.
    ram =
      if ly == @visible do
        Map.update(ram, 0xFF0F, 0x01, &bor(&1, 0x01))
      else
        ram
      end

    # La coïncidence LY=LYC : le bit 2 de STAT la reflète, et si le jeu a armé
    # le bit 6, l'interruption STAT part — c'est l'outil des effets raster, et
    # dmg-acid2 s'endormait dessus.
    stat = Map.get(ram, 0xFF41, 0)

    if ly == Map.get(ram, 0xFF45, 0) do
      ram = Map.put(ram, 0xFF41, bor(stat, 0x04))

      if band(stat, 0x40) != 0 do
        Map.update(ram, 0xFF0F, 0x02, &bor(&1, 0x02))
      else
        ram
      end
    else
      Map.put(ram, 0xFF41, band(stat, 0xFB))
    end
  end

  @doc """
  Charge une ROM : les petites sont complétées à 32 Ko ; les grandes gardent
  leurs banques telles quelles, le MBC1 de CartLoop fait le reste.
  """
  @spec load(Path.t()) :: binary()
  def load(path) do
    rom = File.read!(path)

    if byte_size(rom) < 0x8000 do
      rom <> :binary.copy(<<0xFF>>, 0x8000 - byte_size(rom))
    else
      rom
    end
  end

  @doc """
  La frame en texte pour le terminal : deux scanlines par rangée de
  caractères, le demi-bloc `▀` portant la ligne du haut en avant-plan et
  celle du bas en arrière-plan, quatre gris ANSI pour les quatre teintes.

  La séquence de couleur n'est émise qu'au changement de paire — les aplats,
  majoritaires sur une frame de jeu, coûtent un octet par cellule. C'est ce
  qui laisse un terminal suivre 60 frames par seconde.
  """
  @spec to_text(PPU.frame(), :gris | :dmg) :: String.t()
  def to_text(frame, palette \\ :gris)

  # La frame couleur : demi-blocs en truecolor, via le RGB des palettes du jeu.
  def to_text(frame, palette) when byte_size(frame) == 2 * 160 * 144 do
    rgb = to_rgb(frame, palette)
    {width, height} = PPU.dimensions()

    rows =
      for row <- 0..(div(height, 2) - 1) do
        top = :binary.part(rgb, row * 2 * width * 3, width * 3)
        bottom = :binary.part(rgb, (row * 2 + 1) * width * 3, width * 3)

        {cells, _} =
          Enum.map_reduce(0..(width - 1), nil, fn x, prev ->
            <<r1, g1, b1>> = :binary.part(top, x * 3, 3)
            <<r2, g2, b2>> = :binary.part(bottom, x * 3, 3)
            pair = {r1, g1, b1, r2, g2, b2}

            if pair == prev do
              {"▀", prev}
            else
              {"\e[38;2;#{r1};#{g1};#{b1};48;2;#{r2};#{g2};#{b2}m▀", pair}
            end
          end)

        [cells, "\e[0m\n"]
      end

    IO.iodata_to_binary(rows)
  end

  def to_text(frame, palette) do
    {width, height} = PPU.dimensions()
    colors = colors(palette)

    rows =
      for row <- 0..(div(height, 2) - 1) do
        top = :binary.part(frame, row * 2 * width, width)
        bottom = :binary.part(frame, (row * 2 + 1) * width, width)

        {cells, _} =
          Enum.map_reduce(0..(width - 1), nil, fn x, prev ->
            fg = elem(colors, :binary.at(top, x))
            bg = elem(colors, :binary.at(bottom, x))
            pair = {fg, bg}

            if pair == prev do
              {"▀", prev}
            else
              {"\e[38;#{fg};48;#{bg}m▀", pair}
            end
          end)

        [cells, "\e[0m\n"]
      end

    IO.iodata_to_binary(rows)
  end

  # Les teintes précompilées en paramètres SGR : 256 couleurs pour les gris,
  # truecolor pour le vert de la dalle DMG d'origine.
  defp colors(:gris), do: {"5;255", "5;250", "5;243", "5;236"}

  defp colors(:dmg) do
    {"2;155;188;15", "2;139;172;15", "2;48;98;48", "2;15;56;15"}
  end

  @doc """
  La frame en protocole graphique kitty : une vraie image dans le terminal.

  Le pixel de la DMG devient un pixel RGB transmis en APC (`ESC _ G … ESC \\`),
  zlib puis base64 — une frame à quatre teintes se compresse en ~2 Ko. Le
  placement `r=` laisse le terminal choisir la largeur en gardant le rapport
  d'aspect ; `C=1` cloue le curseur ; `q=2` fait taire les accusés de
  réception. Deux identifiants alternent en double tampon : la nouvelle image
  se pose par-dessus l'ancienne, qui n'est effacée qu'ensuite — pas de trou,
  pas de scintillement.
  """
  @spec to_kitty(PPU.frame(), :gris | :dmg, pos_integer(), pos_integer()) :: iodata()
  def to_kitty(frame, palette, id, rows) do
    payload = frame |> to_rgb(palette) |> :zlib.compress() |> Base.encode64()

    {width, height} = PPU.dimensions()
    head = "a=T,i=#{id},f=24,s=#{width},v=#{height},o=z,q=2,C=1,r=#{rows}"

    case chunks(payload) do
      [only] ->
        ["\e_G", head, ";", only, "\e\\"]

      [first | rest] ->
        {middle, [last]} = Enum.split(rest, -1)

        [
          ["\e_G", head, ",m=1;", first, "\e\\"],
          Enum.map(middle, &["\e_Gm=1;", &1, "\e\\"]),
          ["\e_Gm=0;", last, "\e\\"]
        ]
    end
  end

  @doc """
  La frame en RGB 24 bits — trois octets par pixel. Une frame DMG (un octet
  par pixel) passe par la palette choisie ; une frame couleur (RGB555, deux
  octets par pixel) s'étend en RGB888, la palette du jeu faisant foi.
  """
  @spec to_rgb(PPU.frame(), :gris | :dmg) :: binary()
  def to_rgb(frame, palette) when byte_size(frame) == 160 * 144 do
    rgb = rgb_palette(palette)
    for <<shade <- frame>>, into: <<>>, do: elem(rgb, shade)
  end

  def to_rgb(frame, _palette) do
    for <<c::16-little <- frame>>, into: <<>> do
      <<x8(c &&& 0x1F), x8(bsr(c, 5) &&& 0x1F), x8(bsr(c, 10) &&& 0x1F)>>
    end
  end

  # 5 bits étendus à 8 : les bits hauts recopiés en bas, l'échelle exacte.
  defp x8(v), do: bsl(v, 3) ||| bsr(v, 2)

  # Le protocole plafonne les tronçons de charge utile à 4096 octets.
  defp chunks(<<chunk::binary-size(4096), rest::binary>>), do: [chunk | chunks(rest)]
  defp chunks(last), do: [last]

  # Les quatre teintes en RGB : le vert de la dalle d'origine, ou les gris.
  defp rgb_palette(:dmg),
    do: {<<0x9B, 0xBC, 0x0F>>, <<0x8B, 0xAC, 0x0F>>, <<0x30, 0x62, 0x30>>, <<0x0F, 0x38, 0x0F>>}

  defp rgb_palette(:gris),
    do: {<<0xFF, 0xFF, 0xFF>>, <<0xAA, 0xAA, 0xAA>>, <<0x55, 0x55, 0x55>>, <<0x00, 0x00, 0x00>>}

  @doc """
  La frame en PGM binaire (P5) — lisible par tout visionneur d'images.
  """
  @spec to_pgm(PPU.frame()) :: binary()
  def to_pgm(frame) when byte_size(frame) == 160 * 144 do
    {width, height} = PPU.dimensions()
    shades = {0xFF, 0xAA, 0x55, 0x00}
    pixels = for <<shade <- frame>>, into: <<>>, do: <<elem(shades, shade)>>
    "P5\n#{width} #{height}\n255\n" <> pixels
  end

  # La frame couleur en PPM (P6) — la vraie couleur, lisible partout.
  def to_pgm(frame) do
    {width, height} = PPU.dimensions()
    "P6\n#{width} #{height}\n255\n" <> to_rgb(frame, :dmg)
  end
end
