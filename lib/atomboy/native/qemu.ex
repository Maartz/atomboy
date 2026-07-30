defmodule Atomboy.Native.Qemu do
  @moduledoc """
  Lance une image sous `qemu-system-riscv32` et récupère ce qu'elle a émis.

  La sortie série part dans un fichier plutôt que sur l'entrée-sortie standard :
  le protocole de résultats est binaire, et `-nographic` mêle au flux les
  messages de qemu lui-même. Un fichier donne des octets propres.

  Un délai de garde est indispensable. Un interpréteur en cours d'écriture boucle
  — c'est le mode de panne le plus courant du chantier — et `System.cmd/3` n'a
  aucun moyen d'interrompre. D'où le port, le `os_pid`, et le `kill`.
  """

  @executable "qemu-system-riscv32"
  @timeout 30_000

  @typedoc "Le résultat d'une exécution."
  @type result :: %{
          status: :ok | :timeout,
          exit_status: integer() | nil,
          serial: binary(),
          duration_us: non_neg_integer()
        }

  @doc "qemu est-il installé ? Les tests qui en dépendent s'excluent sinon."
  @spec available?() :: boolean()
  def available?, do: System.find_executable(@executable) != nil

  @doc """
  Exécute une image et renvoie ce qui est sorti par le port série.

  Options : `:timeout` en millisecondes, `:icount` pour activer le comptage
  déterministe d'instructions (nécessaire à la lecture du CSR `instret`), et
  `:dir` pour choisir où déposer les fichiers temporaires.
  """
  @spec run(binary(), keyword()) :: result()
  def run(image, opts \\ []) when is_binary(image) do
    timeout = Keyword.get(opts, :timeout, @timeout)
    dir = Keyword.get_lazy(opts, :dir, &tmp_dir/0)
    File.mkdir_p!(dir)

    image_path = Path.join(dir, "image.bin")
    serial_path = Path.join(dir, "serial.bin")
    File.write!(image_path, image)
    File.rm(serial_path)

    args =
      [
        "-machine",
        "virt",
        "-bios",
        "none",
        "-kernel",
        image_path,
        "-display",
        "none",
        "-serial",
        "file:" <> serial_path,
        "-smp",
        "1",
        "-no-reboot"
      ] ++ if Keyword.get(opts, :icount, false), do: ["-icount", "shift=0"], else: []

    {duration_us, {status, exit_status}} = :timer.tc(fn -> spawn_qemu(args, timeout) end)

    %{
      status: status,
      exit_status: exit_status,
      serial:
        File.read(serial_path)
        |> case do
          {:ok, bytes} -> bytes
          {:error, _} -> ""
        end,
      duration_us: duration_us
    }
  end

  defp spawn_qemu(args, timeout) do
    executable = System.find_executable(@executable) || raise "#{@executable} introuvable"

    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :hide,
        args: args
      ])

    await(port, timeout)
  end

  defp await(port, timeout) do
    receive do
      {^port, {:exit_status, status}} -> {:ok, status}
      {^port, {:data, _}} -> await(port, timeout)
    after
      timeout ->
        kill(port)
        {:timeout, nil}
    end
  end

  # Fermer le port ne suffit pas : qemu ne lit pas son entrée standard et
  # survivrait à la fermeture. Il faut le signal.
  defp kill(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> System.cmd("kill", ["-9", Integer.to_string(pid)], stderr_to_stdout: true)
      nil -> :ok
    end

    if Port.info(port), do: Port.close(port)
    :ok
  end

  defp tmp_dir do
    Path.join([
      System.tmp_dir!(),
      "atomboy-native",
      Integer.to_string(System.unique_integer([:positive]))
    ])
  end
end
