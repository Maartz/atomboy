defmodule Atomboy.Play.Input do
  @moduledoc """
  The terminal keyboard, decoded into Game Boy key events.

  The decoder is a pure fold over a buffer of raw bytes: it consumes what
  it recognises, returns events, and keeps as leftover any escape-sequence
  prefix that is still incomplete (an arrow can arrive split across two
  reads).

  ## Two worlds of terminals

  A classic terminal sends only *keystrokes* — letters as they are, arrows
  as `ESC [ A` — never releases; and macOS only auto-repeats the last key
  pressed. Holding a diagonal there is impossible. Those encodings become
  `{:key, key}`: a keystroke whose release is unknown, which the loop turns
  into a press held for a few frames.

  The kitty keyboard protocol (Ghostty, kitty, WezTerm…) sends the full
  events instead — press, repeat, release, for every key:

      CSI code ; mods [: event] u        letters and named keys
      CSI 1 ; mods [: event] A…D         arrows (bare press: ESC [ A)

  event 1 = press, 2 = repeat, 3 = release. Those become
  `{:press | :repeat | :release, key}`: the real state of the keyboard,
  diagonals and A+direction chords included. The `CSI ? … u` answer to the
  activation request becomes `{:kitty, flags}` — the sign that the terminal
  speaks the protocol.

  ## The layout

      arrows           the d-pad
      x                A            (x and c: neighbours on QWERTY and AZERTY alike)
      c                B
      Enter            Start
      Space            Select
      s / r            save / load state
      Backspace        rewind (hold)
      Tab              turbo (fast forward)
      p                pause
      w                the watch — the game's cells, live (under mix atomboy.live)
      q, Escape (kitty) or Ctrl-C    quit
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
          | :watch
          | :rewind
          | {:slot, 1..9}
  @type event ::
          {:key, key()}
          | {:press, key()}
          | {:repeat, key()}
          | {:release, key()}
          | {:kitty, non_neg_integer()}
          | {:graphics, boolean()}

  @arrows %{?A => :up, ?B => :down, ?C => :right, ?D => :left}

  # CSI-u codes: the key's code point, lowercase.
  @codes %{
    ?x => :a,
    ?c => :b,
    13 => :start,
    ?\s => :select,
    ?q => :quit,
    # Escape opens the menu — quitting lives on q and in the menu.
    27 => :menu,
    ?m => :menu,
    ?s => :save_state,
    ?r => :load_state,
    9 => :turbo,
    ?p => :pause,
    ?w => :watch,
    127 => :rewind,
    8 => :rewind,
    ?1 => {:slot, 1},
    ?2 => {:slot, 2},
    ?3 => {:slot, 3},
    ?4 => {:slot, 4},
    ?5 => {:slot, 5},
    ?6 => {:slot, 6},
    ?7 => {:slot, 7},
    ?8 => {:slot, 8},
    ?9 => {:slot, 9}
  }

  @doc """
  Decodes the buffer into events. Returns `{events, leftover}` — the
  leftover is the start of an escape sequence, to be completed on the next
  read.
  """
  @spec decode(binary()) :: {[event()], binary()}
  def decode(buffer), do: decode(buffer, [])

  # CSI: ESC [ params final-byte. The parameters stay within 0x20-0x3F.
  defp decode(<<"\e[", rest::binary>> = all, events) do
    case csi(rest, "") do
      {params, final, rest} -> decode(rest, csi_events(params, final) ++ events)
      :partial -> {Enum.reverse(events), all}
    end
  end

  # APC: ESC _ … ESC \ — the answers of the kitty graphics protocol.
  # "OK" after the semicolon = the terminal can display images.
  defp decode(<<"\e_", rest::binary>> = all, events) do
    case :binary.split(rest, "\e\\") do
      [payload, rest] ->
        ok? = String.contains?(payload, ";OK")
        decode(rest, [{:graphics, ok?} | events])

      _ ->
        {Enum.reverse(events), all}
    end
  end

  # SS3: ESC O letter — the arrows of application mode.
  defp decode(<<?\e, ?O, final, rest::binary>>, events) when is_map_key(@arrows, final),
    do: decode(rest, [{:key, @arrows[final]} | events])

  # A sequence cut off mid-flight: wait for the rest.
  defp decode(<<?\e, o>>, events) when o in ~c"[O_", do: {Enum.reverse(events), <<?\e, o>>}
  defp decode(<<"\e">>, events), do: {Enum.reverse(events), "\e"}
  # SS3 with no arrow at the end: swallow the prefix, decode the rest.
  defp decode(<<?\e, ?O, rest::binary>>, events), do: decode(rest, events)
  # An escape that opens no sequence: that is the Escape key — the menu.
  # The next byte decodes normally behind it.
  defp decode(<<"\e", rest::binary>>, events), do: decode(rest, [{:key, :menu} | events])

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

  defp decode(<<c, rest::binary>>, events) when c in [?w, ?W],
    do: decode(rest, [{:key, :watch} | events])

  defp decode(<<c, rest::binary>>, events) when c in [?m, ?M],
    do: decode(rest, [{:key, :menu} | events])

  defp decode(<<c, rest::binary>>, events) when c in [0x7F, 0x08],
    do: decode(rest, [{:key, :rewind} | events])

  defp decode(<<c, rest::binary>>, events) when c in ?1..?9,
    do: decode(rest, [{:key, {:slot, c - ?0}} | events])

  # Everything else on the keyboard: silence.
  defp decode(<<_, rest::binary>>, events), do: decode(rest, events)
  defp decode(<<>>, events), do: {Enum.reverse(events), ""}

  # ── The CSI sequence, taken apart ───────────────────────────────────────────

  defp csi(<<c, rest::binary>>, params) when c in ?0..?9 or c in ~c";:?",
    do: csi(rest, <<params::binary, c>>)

  defp csi(<<final, rest::binary>>, params) when final in 0x40..0x7E,
    do: {params, final, rest}

  defp csi(<<>>, _params), do: :partial
  defp csi(_other, _params), do: :partial

  # ── The events of a sequence ────────────────────────────────────────────────

  # Bare arrow: a keystroke, regime unknown — the loop decides.
  defp csi_events("", final) when is_map_key(@arrows, final), do: [{:key, @arrows[final]}]

  # Parameterised arrow: "1;mods:event" — the kitty protocol.
  defp csi_events(params, final) when is_map_key(@arrows, final) do
    tag(parse_event(params), @arrows[final])
  end

  # CSI-u: "code;mods:event u" — every key of the kitty protocol.
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

  # The event lives after the ":" of the modifier field; absent = press.
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

  # Modifiers = 1 + mask; Ctrl = bit 4.
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
  The nibble of one line group from the set of held keys — 1 = released,
  just like the register's lines.
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
