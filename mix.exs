defmodule NauticNet.Device.MixProject do
  use Mix.Project

  @app :nautic_net_device
  @version "0.1.0"
  @all_device_targets [:rpi2, :nautic_net_rpi2, :nautic_net_rpi3]

  def project do
    [
      app: @app,
      version: @version,
      elixir: "~> 1.9",
      archives: [nerves_bootstrap: "~> 1.10"],
      start_permanent: Mix.env() == :prod,
      build_embedded: true,
      deps: deps(),
      releases: [{@app, release()}],
      preferred_cli_target: [run: :host, test: :host]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      mod: {NauticNet.Application, []},
      extra_applications: [:logger, :runtime_tools, :inets, :crypto]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # Dependencies for all targets
      {:nerves, "~> 1.7.15", runtime: false},
      {:shoehorn, "~> 0.8.0"},
      {:ring_logger, "~> 0.8.3"},
      {:toolshed, "~> 0.2.13"},
      {:ssh_subsystem_fwup, "~> 0.6.1"},

      # Dependencies for all targets except :host
      {:nerves_runtime, "~> 0.11.6", targets: @all_device_targets},
      {:nerves_pack, "~> 0.6.0", targets: @all_device_targets},

      # Dependencies for specific targets
      # NOTE: It's generally low risk and recommended to follow minor version
      # bumps to Nerves systems. Since these include Linux kernel and Erlang
      # version updates, please review their release notes in case
      # changes to your application are needed.
      # {:nerves_system_rpi2, "1.20.1", runtime: false, targets: :rpi2},

      # For a precompiled system artifact:
      # {:nautic_net_system_rpi2, "1.20.1",
      #  github: "DockYard/nautic_net_system_rpi2", runtime: false, targets: :nautic_net_rpi2},

      # For iterating on systems locally:
      # {:nautic_net_system_rpi2,
      #  path: "../../../nautic_net_system_rpi2", runtime: false, targets: :nautic_net_rpi2},
      {:nautic_net_system_rpi3, path: "../nautic_net_system_rpi3", runtime: false, targets: :nautic_net_rpi3},

      # NauticNet libraries
      # {:nautic_net_protobuf, github: "DockYard/nautic_net_protobuf"},
      {:nautic_net_nmea2000, github: "DockYard/nautic_net_nmea2000"},
      # Local dev:
      # {:nautic_net_nmea2000, path: "../nautic_net_nmea2000"},
      {:nautic_net_protobuf, path: "../nautic_net_protobuf"},

      # CANUSB serial communication
      {:circuits_uart, "~> 1.3"},

      # Dev tools
      {:mix_test_watch, "~> 1.0", only: [:dev, :test], runtime: false},

      # Telemetry
      {:telemetry, "~> 1.0"},
      {:telemetry_metrics, "~> 0.6.1"},

      # Cellular
      {:vintage_net_qmi, "~> 0.3.2", targets: @all_device_targets},

      # HTTP client
      {:tesla, "~> 1.4"},
      {:hackney, "~> 1.17"},
      {:jason, ">= 1.0.0"}
    ]
  end

  def release do
    [
      overwrite: true,
      # Erlang distribution is not started automatically.
      # See https://hexdocs.pm/nerves_pack/readme.html#erlang-distribution
      cookie: "#{@app}_cookie",
      include_erts: &Nerves.Release.erts/0,
      steps: [&Nerves.Release.init/1, :assemble],
      strip_beams: Mix.env() == :prod or [keep: ["Docs"]]
    ]
  end
end
