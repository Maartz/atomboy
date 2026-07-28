# Sonde n°2 : lire le pty par son nom, sans terminal de contrôle.
#
#     mix run scripts/probe_clavier2.exs
#
# Le BEAM détache ses enfants du terminal (setsid) : /dev/tty est mort pour
# eux. Mais le pty a un nom (/dev/ttysNNN), que ps sait retrouver — un simple
# fichier device, ouvrable sans lien de contrôle : stty -f pour les modes,
# :file.read pour les octets, sans passer par l'étage d'E/S d'Erlang.
#
# Pendant chaque fenêtre de 6 s, tape des touches (lettres ET flèches).
# Des points s'écrivent pendant la fenêtre C — ils simulent le rendu du jeu,
# pour vérifier que les écritures ne rendent pas le mode ligne au terminal.
# À la fin, coller toute la sortie.

defmodule Probe2 do
  def window(label, seconds, writer? \\ false) do
    IO.write("\r\n=== #{label} — tape des touches pendant #{seconds} s ===\r\n")
    parent = self()
    t0 = System.monotonic_time(:millisecond)

    writer =
      if writer? do
        spawn(fn ->
          Enum.each(1..(seconds * 10), fn _ ->
            IO.write(".")
            Process.sleep(100)
          end)
        end)
      end

    Process.sleep(seconds * 1000)
    if writer, do: Process.exit(writer, :kill)

    got = drain(0, t0)
    IO.write("\r\n=== #{label} : #{got} octet(s) reçu(s) ===\r\n")
    _ = parent
    got
  end

  defp drain(n, t0) do
    receive do
      {:byte, data, ms} ->
        IO.write("  reçu #{inspect(data)} à #{ms} ms\r\n")
        drain(n + byte_size(data), t0)
    after
      0 -> n
    end
  end

  # Un descripteur :raw ne se lit que depuis le processus qui l'a ouvert —
  # le lecteur ouvre donc lui-même.
  def reader(parent, path, t0) do
    spawn(fn ->
      case :file.open(String.to_charlist(path), [:read, :binary, :raw]) do
        {:ok, f} -> read_loop(parent, f, t0)
        error -> IO.write("  ouverture impossible : #{inspect(error)}\r\n")
      end
    end)
  end

  defp read_loop(parent, f, t0) do
    case :file.read(f, 1) do
      {:ok, data} ->
        send(parent, {:byte, data, System.monotonic_time(:millisecond) - t0})
        read_loop(parent, f, t0)

      other ->
        IO.write("  lecture close : #{inspect(other)}\r\n")
    end
  end
end

# ── Trouver le pty par son nom ───────────────────────────────────────────────
tty = :os.cmd(String.to_charlist("ps -o tty= -p #{System.pid()}")) |> to_string() |> String.trim()

path =
  if String.starts_with?(tty, "tty") do
    "/dev/#{tty}"
  else
    IO.puts("pas de pty visible par ps (#{inspect(tty)})")
    nil
  end

IO.puts("pty détecté : #{path || "aucun"}")

c =
  if path do
    stty = :os.cmd(String.to_charlist("stty -f #{path} -icanon -echo -isig min 1 time 0 2>&1"))
    IO.puts("stty -f : #{inspect(to_string(stty))}")
    IO.puts("état : " <> (:os.cmd(String.to_charlist("stty -f #{path} -a 2>&1 | head -2")) |> to_string()))

    # ── Fenêtre C : :file.read sur le pty nommé, écritures simultanées ──────
    t0 = System.monotonic_time(:millisecond)
    pid = Probe2.reader(self(), path, t0)
    got = Probe2.window("VOIE C (:file.read #{path}, avec écritures)", 6, true)
    Process.exit(pid, :kill)
    got
  else
    0
  end

# ── Fenêtre D : /dev/fd/0, le repli sans nom de pty ─────────────────────────
t0 = System.monotonic_time(:millisecond)
pid = Probe2.reader(self(), "/dev/fd/0", t0)
d = Probe2.window("VOIE D (:file.read /dev/fd/0)", 6)
Process.exit(pid, :kill)

if path, do: :os.cmd(String.to_charlist("stty -f #{path} sane 2>&1"))

IO.puts("\nVERDICT — voie C : #{c} octet(s), voie D : #{d} octet(s).")
IO.puts("Colle toute cette sortie dans la conversation.")
