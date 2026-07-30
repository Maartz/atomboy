defmodule Mix.Tasks.Atomboy.Atomvm do
  @shortdoc "Checks that the code runs under AtomVM (generic_unix build)"

  @moduledoc """
  The AtomVM guardrail: packs the application and runs it on the `generic_unix`
  build.

      mix atomboy.atomvm

  ## Why this is not the dev loop

  All the iteration happens on standard OTP, where ExUnit, tracing and a REPL
  are available. AtomVM implements only a subset of the BEAM instructions and of
  OTP — and that subset is not discovered by reading the docs, which lag behind
  the source.

  What this check catches is invisible on the Mac: a BEAM instruction missing
  from AtomVM's table, a missing OTP function, an Elixir construct that assumes
  a complete standard library. It is cheap today and very expensive in phase 2,
  when weeks of code will rest on it. Run it after each family of opcodes, not
  after each compile.

  ## Where AtomVM is

  The `generic_unix` build is looked up in `ATOMVM_BUILD`, otherwise in
  `../AtomVM/build` next to the project.

  ## What gets packed

  The application's modules, minus the Mix tasks — they depend on Mix, which
  does not exist under AtomVM, and have no business in what will be flashed.
  Added to those are `atomvmlib.avm` and `exavmlib.avm`, AtomVM's standard
  libraries for Erlang and Elixir.
  """

  use Mix.Task

  @entry_point Atomboy.AtomVM.Smoke
  @success "smoke_ok"

  @impl true
  def run(_args) do
    Mix.Task.run("compile")

    with {:ok, build} <- locate_atomvm(),
         {:ok, avm} <- pack(build) do
      execute(build, avm)
    else
      {:error, message} -> Mix.raise(message)
    end
  end

  defp locate_atomvm do
    build = System.get_env("ATOMVM_BUILD") || Path.expand("../AtomVM/build", File.cwd!())

    cond do
      not File.regular?(Path.join(build, "src/AtomVM")) ->
        {:error,
         """
         AtomVM binary not found in #{build}.

         Point somewhere else with ATOMVM_BUILD, or build the generic_unix
         build:

             cd /path/to/AtomVM && mkdir -p build && cd build
             cmake .. && make -j8 AtomVM PackBEAM atomvmlib exavmlib

         On macOS, AtomVM requires MbedTLS 2.x or 3.x — not the 4.x that
         Homebrew installs by default. It takes `brew install mbedtls@3` and
         then configuring with -DMBEDTLS_ROOT_DIR=/opt/homebrew/opt/mbedtls@3.
         """}

      not File.regular?(Path.join(build, "libs/atomvmlib.avm")) ->
        {:error, "atomvmlib.avm missing from #{build} — run `make atomvmlib exavmlib`."}

      true ->
        {:ok, build}
    end
  end

  defp pack(build) do
    output = Path.join(Mix.Project.build_path(), "atomboy.avm")

    inputs =
      app_beams() ++
        [
          Path.join(build, "libs/atomvmlib.avm"),
          Path.join(build, "libs/exavmlib/lib/exavmlib.avm")
        ]

    Mix.Atomboy.Packbeam.create(build, output, inputs, @entry_point)
    {:ok, output}
  end

  defp app_beams do
    Mix.Project.compile_path()
    |> Path.join("*.beam")
    |> Path.wildcard()
    |> Enum.reject(&String.starts_with?(Path.basename(&1), "Elixir.Mix."))
  end

  defp execute(build, avm) do
    {output, code} =
      System.cmd(Path.join(build, "src/AtomVM"), [avm], stderr_to_stdout: true)

    cond do
      code != 0 ->
        Mix.raise("AtomVM exited with an error (code #{code}):\n#{output}")

      String.contains?(output, @success) ->
        Mix.shell().info("AtomVM: the code loads and runs.\n\n#{String.trim(output)}")

      true ->
        # Exit 0 but no marker: the program did not make it to the end. An
        # `undef` on a function missing from AtomVM looks exactly like this.
        Mix.raise("""
        AtomVM did not produce the success marker. Raw output:

        #{String.trim(output)}
        """)
    end
  end
end
