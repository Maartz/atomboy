defmodule Atomboy.Menu do
  @moduledoc """
  The overlay menu — drawn INSIDE the 160×144 frame.

  A single implementation for both front-ends: the menu renders itself as
  pixels into the raw frame (DMG shades or CGB RGB555), and the usual
  rendering path — terminal or window — displays it knowing nothing about
  it. Escape or `m` opens it, and the machine sleeps for as long as it is
  there; arrows to navigate and adjust, A to act, B or Escape to resume.

  The menu touches nothing itself: `press/2` returns *actions*
  (`:save_state`, `{:slot, n}`, `{:palette, p}`, `:quit`…) that the host
  loop applies through the same paths as the direct shortcuts.
  """

  alias Atomboy.Menu.Font

  defstruct cursor: 0,
            page: :main,
            slot: 1,
            palette: :dmg,
            panel: :raw,
            color: false,
            movie: :absent,
            mixer: %{volume: 100, voices: {true, true, true, true}}

  @type mixer :: %{volume: 0..100, voices: {boolean(), boolean(), boolean(), boolean()}}

  @typedoc """
  What the host's movie machinery is doing — and `:absent` for a front-end
  that has none, which is offered nothing rather than offered a verb that
  would do nothing.
  """
  @type movie :: :absent | nil | :recording | :replaying

  @type action ::
          :resume
          | :save_state
          | :load_state
          | {:slot, 1..9}
          | {:palette, :dmg | :gray}
          | {:panel, Atomboy.LCD.preset()}
          | {:mixer, mixer()}
          | :record_movie
          | :stop_movie
          | :replay_movie
          | :quit

  @type t :: %__MODULE__{}

  @doc "The neutral mixer: full volume, all four voices open."
  @spec mixer_default() :: mixer()
  def mixer_default, do: %{volume: 100, voices: {true, true, true, true}}

  @doc """
  Opens the menu on the host loop's current state. `color` hides the
  palette choice — it only tints DMG frames; `movie` says which of the
  take's verbs are worth offering, and hides all of them by default.
  """
  @spec open(1..9, :dmg | :gray, boolean(), mixer(), Atomboy.LCD.preset(), movie()) :: t()
  def open(slot, palette, color \\ false, mixer \\ nil, panel \\ :raw, movie \\ :absent),
    do: %__MODULE__{
      cursor: 0,
      slot: slot,
      palette: palette,
      panel: panel,
      color: color,
      movie: movie,
      mixer: mixer || mixer_default()
    }

  defp items(%{page: :mixer}), do: [:volume, :voices1, :voices2, :voices3, :voices4, :back]

  defp items(menu) do
    [:resume, :save, :load, :slot] ++
      takes(menu.movie) ++
      if(menu.color, do: [], else: [:palette]) ++
      [:panel, :mixer, :quit]
  end

  # Only what can happen from here: a take that is running can be stopped
  # and nothing else, and a machine with nothing running can start one of
  # each. The menu never shows a verb that would answer with a refusal.
  defp takes(nil), do: [:record, :replay]
  defp takes(:recording), do: [:stop_take]
  defp takes(:replaying), do: [:stop_take]
  defp takes(:absent), do: []

  @doc """
  One key in the menu. Returns `{menu, actions}` — `menu` is `nil` when it
  closes, `actions` the (often empty) list for the host to apply.
  """
  @spec press(t(), atom()) :: {t() | nil, [action()]}
  def press(menu, :up) do
    n = length(items(menu))
    {%{menu | cursor: rem(menu.cursor + n - 1, n)}, []}
  end

  def press(menu, :down),
    do: {%{menu | cursor: rem(menu.cursor + 1, length(items(menu)))}, []}

  def press(menu, :left), do: adjust(menu, -1)
  def press(menu, :right), do: adjust(menu, 1)

  def press(menu, :a) do
    case Enum.at(items(menu), menu.cursor) do
      :resume -> {nil, []}
      :save -> {nil, [:save_state]}
      :load -> {nil, [:load_state]}
      :record -> {nil, [:record_movie]}
      :stop_take -> {nil, [:stop_movie]}
      :replay -> {nil, [:replay_movie]}
      :slot -> adjust(menu, 1)
      :palette -> adjust(menu, 1)
      :panel -> adjust(menu, 1)
      :mixer -> {%{menu | page: :mixer, cursor: 0}, []}
      :back -> {%{menu | page: :main, cursor: 0}, []}
      :quit -> {nil, [:quit]}
      _voice -> adjust(menu, 1)
    end
  end

  # B goes up one page; at the root it closes — like Escape.
  def press(%{page: :mixer} = menu, key) when key in [:b, :menu],
    do: {%{menu | page: :main, cursor: 0}, []}

  def press(_menu, key) when key in [:b, :menu], do: {nil, []}
  def press(menu, _key), do: {menu, []}

  defp adjust(menu, direction) do
    case Enum.at(items(menu), menu.cursor) do
      :slot ->
        slot = menu.slot + direction

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

      :panel ->
        panel = Atomboy.LCD.next(menu.panel, direction)
        {%{menu | panel: panel}, [{:panel, panel}]}

      :volume ->
        volume = min(100, max(0, menu.mixer.volume + direction * 10))
        mixer = %{menu.mixer | volume: volume}
        {%{menu | mixer: mixer}, [{:mixer, mixer}]}

      voice when voice in [:voices1, :voices2, :voices3, :voices4] ->
        i = %{voices1: 0, voices2: 1, voices3: 2, voices4: 3}[voice]
        voices = put_elem(menu.mixer.voices, i, not elem(menu.mixer.voices, i))
        mixer = %{menu.mixer | voices: voices}
        {%{menu | mixer: mixer}, [{:mixer, mixer}]}

      _ ->
        {menu, []}
    end
  end

  # ── Rendering ───────────────────────────────────────────────────────────────

  @width 160
  @height 144
  @box_w 112
  @line_h 11
  @margin 8

  @doc """
  Composes the menu onto a raw frame — 1-byte shades or 2-byte RGB555,
  detected from the size. Returns the composed frame, same format.
  """
  @spec render(t(), binary()) :: binary()
  def render(menu, frame) do
    lines = labels(menu)
    box_h = length(lines) * @line_h + 2 * @margin
    x0 = div(@width - @box_w, 2)
    y0 = div(@height - box_h, 2)

    ink = ink_pixels(menu, lines, x0, y0)
    bytes = div(byte_size(frame), @width * @height)
    compose(frame, bytes, x0, y0, box_h, ink)
  end

  defp labels(menu) do
    Enum.map(items(menu), fn
      :resume -> "RESUME"
      :save -> "SAVE STATE"
      :load -> "LOAD STATE"
      :record -> "RECORD MOVIE"
      # The ampersand is not in the font, and a menu of this era would have
      # spelled it out anyway.
      :stop_take -> if menu.movie == :recording, do: "STOP AND SAVE", else: "STOP REPLAY"
      :replay -> "REPLAY MOVIE"
      :slot -> "STATE SLOT <#{menu.slot}>"
      :palette -> "PALETTE <#{if menu.palette == :dmg, do: "GREEN", else: "GRAY"}>"
      :panel -> "PANEL <#{menu.panel |> Atom.to_string() |> String.upcase()}>"
      :mixer -> "MIXER"
      :volume -> "VOLUME <#{menu.mixer.volume}>"
      :voices1 -> "PULSE 1 <#{on_off(menu, 0)}>"
      :voices2 -> "PULSE 2 <#{on_off(menu, 1)}>"
      :voices3 -> "WAVE <#{on_off(menu, 2)}>"
      :voices4 -> "NOISE <#{on_off(menu, 3)}>"
      :back -> "BACK"
      :quit -> "QUIT"
    end)
  end

  defp on_off(menu, i), do: if(elem(menu.mixer.voices, i), do: "ON", else: "OFF")

  # Every ink pixel of the box: border, text and cursor.
  defp ink_pixels(menu, lines, x0, y0) do
    box_h = length(lines) * @line_h + 2 * @margin

    border =
      for x <- x0..(x0 + @box_w - 1),
          y <- [y0, y0 + 1, y0 + box_h - 2, y0 + box_h - 1],
          into: %{} do
        {{x, y}, true}
      end

    border =
      for y <- y0..(y0 + box_h - 1),
          x <- [x0, x0 + 1, x0 + @box_w - 2, x0 + @box_w - 1],
          into: border do
        {{x, y}, true}
      end

    lines
    |> Enum.with_index()
    |> Enum.reduce(border, fn {text, i}, acc ->
      y = y0 + @margin + i * @line_h
      text = if i == menu.cursor, do: "▶ " <> text, else: "  " <> text
      Map.merge(acc, Font.pixels(text, x0 + 6, y))
    end)
  end

  # Recomposes the frame row by row: outside the box, the original row as
  # it stands; inside the box, light paper and dark ink.
  defp compose(frame, bytes, x0, y0, box_h, ink) do
    line_bytes = @width * bytes

    for y <- 0..(@height - 1), into: <<>> do
      row = binary_part(frame, y * line_bytes, line_bytes)

      if y < y0 or y >= y0 + box_h do
        row
      else
        left = binary_part(row, 0, x0 * bytes)
        right = binary_part(row, (x0 + @box_w) * bytes, (@width - x0 - @box_w) * bytes)

        box =
          for x <- x0..(x0 + @box_w - 1), into: <<>> do
            color(bytes, Map.has_key?(ink, {x, y}))
          end

        left <> box <> right
      end
    end
  end

  # Paper and ink in both formats: shade 0/3 on DMG, RGB555 white and
  # black (little-endian) in color.
  defp color(1, true), do: <<3>>
  defp color(1, false), do: <<0>>
  defp color(2, true), do: <<0x00, 0x00>>
  defp color(2, false), do: <<0xFF, 0x7F>>
end
