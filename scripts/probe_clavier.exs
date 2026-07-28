# La sonde clavier : quelle voie livre les frappes une à une sur CE terminal ?
#
#     mix run scripts/probe_clavier.exs
#
# Deux fenêtres de 6 secondes s'ouvrent l'une après l'autre. Pendant chacune,
# tape quelques touches (lettres, flèches). Chaque octet reçu s'affiche avec
# son horodatage. À la fin, coller toute la sortie.

defmodule Probe do
  def window(label, seconds, read_fun) do
    IO.write("\r\n=== #{label} — tape des touches pendant #{seconds} s ===\r\n")
    parent = self()
    t0 = System.monotonic_time(:millisecond)

    pid =
      spawn(fn ->
        Enum.each(1..100, fn _ ->
          case read_fun.() do
            {:ok, data} ->
              ms = System.monotonic_time(:millisecond) - t0
              IO.write("  reçu #{inspect(data)} à #{ms} ms\r\n")
              send(parent, :got)

            other ->
              IO.write("  lecture terminée : #{inspect(other)}\r\n")
              Process.sleep(:infinity)
          end
        end)
      end)

    Process.sleep(seconds * 1000)
    Process.exit(pid, :kill)

    got =
      Enum.count(Stream.repeatedly(fn ->
        receive do
          :got -> true
        after
          0 -> nil
        end
      end)
      |> Stream.take_while(& &1))

    IO.write("=== #{label} : #{got} octet(s) reçu(s) ===\r\n")
    got
  end
end

IO.puts("TERM=#{System.get_env("TERM")}  user=#{inspect(Process.whereis(:user))}")
IO.puts("getopts avant : #{inspect(:io.getopts())}")

# ── Voie A : l'API raw d'OTP 26 ───────────────────────────────────────────────
res = try do
  :shell.start_interactive({:noshell, :raw})
catch
  kind, err -> {kind, err}
end

IO.puts("start_interactive(raw) : #{inspect(res)}")
IO.puts("getopts après : #{inspect(:io.getopts())}")

a = Probe.window("VOIE A (IO.getn via prim_tty raw)", 6, fn ->
  case IO.getn("", 1) do
    data when is_binary(data) -> {:ok, data}
    other -> other
  end
end)

try do
  :shell.start_interactive({:noshell, :cooked})
catch
  _, _ -> :ok
end

# ── Voie B : cat < /dev/tty dans un port, stty à la main ─────────────────────
IO.write("\r\n(bascule voie B…)\r\n")
:os.cmd(~c"stty -icanon -echo -isig min 1 time 0 < /dev/tty")

port =
  try do
    Port.open({:spawn, ~c"sh -c 'exec cat < /dev/tty'"}, [:binary])
  catch
    kind, err ->
      IO.puts("port impossible : #{inspect({kind, err})}")
      nil
  end

b =
  if port do
    b = Probe.window("VOIE B (port cat < /dev/tty)", 6, fn ->
      receive do
        {^port, {:data, data}} -> {:ok, data}
        other -> other
      end
    end)

    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} -> :os.cmd(String.to_charlist("kill #{os_pid}"))
      _ -> :ok
    end

    catch_ = fn -> Port.close(port) end
    try do catch_.() catch _, _ -> :ok end
    b
  else
    0
  end

:os.cmd(~c"stty sane < /dev/tty")

IO.puts("\nVERDICT — voie A : #{a} octet(s), voie B : #{b} octet(s).")
IO.puts("Colle toute cette sortie dans la conversation.")
