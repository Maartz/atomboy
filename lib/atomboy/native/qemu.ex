defmodule Atomboy.Native.Qemu do
  @moduledoc """
  Runs an image under `qemu-system-riscv32` and collects what it emitted.

  Serial output goes to a file rather than to standard output: the result
  protocol is binary, and `-nographic` interleaves qemu's own messages into the
  stream. A file gives clean bytes.

  A watchdog is not optional. An interpreter under construction loops -- it is
  the most common failure mode of this work -- and `System.cmd/3` has no way to
  interrupt anything. Hence the port, the `os_pid` and the `kill`.
  """

  @executable "qemu-system-riscv32"
  @timeout 30_000

  @typedoc "The outcome of one run."
  @type result :: %{
          status: :ok | :timeout,
          exit_status: integer() | nil,
          serial: binary(),
          duration_us: non_neg_integer()
        }

  @doc "Is qemu installed? Tests that need it exclude themselves otherwise."
  @spec available?() :: boolean()
  def available?, do: System.find_executable(@executable) != nil

  @doc """
  Runs an image and returns whatever came out of the serial port.

  Options: `:timeout` in milliseconds, `:icount` to enable deterministic
  instruction counting (required to read the `instret` CSR), and `:dir` to
  choose where temporary files land.
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
    executable = System.find_executable(@executable) || raise "#{@executable} not found"

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

  # Closing the port is not enough: qemu never reads its standard input and
  # would survive the close. It takes the signal.
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
