defmodule Atomboy.MixProject do
  use Mix.Project

  @version "0.3.0"

  def project do
    [
      app: :atomboy,
      version: version(),
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      # wx (the native window) lives in OTP, not in our deps: without this,
      # mix prunes its code path and :wx becomes unreachable.
      prune_code_paths: false,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      releases: releases()
    ]
  end

  # The version carries the commit SHA (and the time if the tree is dirty):
  # the Burrito binary extracts its contents into a cache named after the
  # version — without this, a rebuild under the same number runs the old code.
  # Every build now has its own key; the cache piles up in
  # ~/Library/Application Support/.burrito, to be purged now and then.
  defp version do
    case System.cmd("git", ["rev-parse", "--short", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} ->
        dirty =
          case System.cmd("git", ["status", "--porcelain"], stderr_to_stdout: true) do
            {"", 0} -> ""
            _ -> ".#{System.os_time(:second)}"
          end

        "#{@version}+#{String.trim(sha)}#{dirty}"

      _ ->
        # With no repository (Docker build: the context does not carry .git),
        # the SHA arrives through the environment — or the version stays bare.
        # A Docker ARG that was not supplied arrives as an empty string, not as
        # an absence.
        case System.get_env("ATOMBOY_SHA") do
          sha when sha in [nil, ""] -> @version
          sha -> "#{@version}+#{sha}"
        end
    end
  end

  def application do
    # No `extra_applications`: everything listed here ends up in the packbeam
    # flashed onto the ESP32, and AtomVM has neither :logger nor most of OTP.
    # Better that the constraint bites from phase 1 on the Mac than in phase 2
    # once the code has grown used to the comfort.
    #
    # In prod (the Burrito executable), the app starts Atomboy.CLI — the entry
    # point of the distributed binary. Never in dev/test: `mix test` must not
    # start a game.
    if Mix.env() == :prod, do: [mod: {Atomboy.CLI, []}], else: []
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    # A single dependency, and confined to packaging: Burrito wraps the release
    # (app + the whole BEAM) into one executable per platform. The emulator's
    # core stays dependency-free — every addition would be more code to fit
    # inside AtomVM, which implements only a subset of OTP. The corpus JSON is
    # decoded by Elixir 1.18's `JSON` module.
    [
      {:burrito, "~> 1.0", runtime: false}
    ]
  end

  defp releases do
    [
      atomboy: [
        applications: [wx: :load],
        steps: [:assemble, &Burrito.wrap/1],
        burrito: [
          targets: [
            macos_arm: [os: :darwin, cpu: :aarch64],
            linux_x64: [os: :linux, cpu: :x86_64]
          ]
        ]
      ]
    ]
  end
end
