defmodule RacingOrg.Tracker.Pro.Device.MixProject do
  use Mix.Project

  @app :racing_org_tracker_pro
  # 0.7.0: first 64-bit (aarch64) firmware — racing_org_system_rpi3 v3.0.0
  @version "0.7.0"
  @all_device_targets [:racing_org_rpi3]

  def project do
    [
      app: @app,
      # NervesHub product name. Nerves bakes `:name || :app` into the firmware's
      # `meta-product`, and NervesHub matches uploads against a Product of that exact
      # name. The OTP app stays `:racing_org_tracker_pro`; only the firmware product label
      # changes. Must match the NervesHub Product name exactly.
      name: "tracker-pro",
      version: @version,
      elixir: "~> 1.17",
      archives: [nerves_bootstrap: "~> 1.13"],
      start_permanent: Mix.env() == :prod,
      build_embedded: true,
      deps: deps(),
      releases: [{@app, release()}],
      aliases: aliases()
    ]
  end

  def cli do
    [preferred_targets: [run: :host, test: :host]]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      mod: {RacingOrg.Tracker.Pro.Application, []},
      extra_applications: [:logger, :runtime_tools, :inets, :crypto]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # Dependencies for all targets
      {:nerves, "~> 1.14", runtime: false},
      {:shoehorn, "~> 0.9"},
      {:ring_logger, "~> 0.11"},
      {:toolshed, "~> 0.4"},
      {:ssh_subsystem_fwup, "~> 0.6.1"},

      # Slipstream powers the device's outbound, CGNAT-friendly WSS command
      # channel to RacingOrg (RacingOrg.Tracker.Pro.SecureTransport.ChannelClient). It is
      # already resolved transitively via :nerves_hub_link (1.2.2 in mix.lock);
      # depend on it explicitly (and on all targets, so host tests can drive the
      # channel logic) and pin it to the resolved minor.
      {:slipstream, "~> 1.2"},

      # CANUSB serial communication
      {:circuits_uart, "~> 1.5"},

      # Dev tools
      {:mix_test_watch, "~> 1.0", only: [:dev, :test], runtime: false},
      {:stream_data, "~> 1.3", only: [:dev, :test], runtime: false},

      # Telemetry
      {:telemetry, "~> 1.0"},
      {:telemetry_metrics, "~> 1.1"},

      # HTTP client. Mint is the Tesla adapter: pure-Elixir, no NIFs, and on the
      # device it auto-uses castore for HTTPS cert verification (verify_peer) at
      # runtime. We do NOT use hackney: tesla 1.20 requires hackney >= 4.0.2, whose
      # 4.x line bundles a full QUIC/HTTP3 stack this device never uses.
      {:tesla, "~> 1.4"},
      {:mint, "~> 1.0"},
      {:jason, ">= 1.0.0"}
    ] ++ target_deps() ++ racing_org_deps()
  end

  defp target_deps do
    if Mix.env() == :test do
      []
    else
      [
        {:nerves_time, "~> 0.4.5", targets: @all_device_targets},

        # Dependencies for all targets except :host
        {:nerves_runtime, "~> 0.13", targets: @all_device_targets},
        {:nerves_pack, "~> 0.7", targets: @all_device_targets},

        # Remote management: OTA firmware updates + remote console via NervesHub.
        # castore provides the CA bundle nerves_hub_link uses for its TLS
        # connection (it's an optional dep there, so depend on it explicitly).
        {:nerves_hub_link, "~> 2.12", targets: @all_device_targets},
        {:castore, "~> 1.0", targets: @all_device_targets},

        # NervesHub Device Extensions (negotiated at runtime; also allow them at the
        # product level in NervesHub). Health + Geo ship inside nerves_hub_link and are
        # always available; Health reports alarms via the OTP :alarm_handler. LocalShell
        # is only added to the extension set when :expty is compiled in, so depend on it
        # explicitly. NOTE: nerves_hub_link decides LocalShell availability at ITS compile
        # time via Code.ensure_loaded?(ExPTY), so after adding :expty force a recompile:
        # `mix deps.compile nerves_hub_link --force`.
        #
        # Do NOT add :alarmist here. nerves_hub_link 2.12 compiles its alarm adapter
        # against whichever handler is present at ITS compile time; if it compiles without
        # Alarmist it calls `:alarm_handler.get_alarms()`, but Alarmist (when present)
        # REPLACES the default :alarm_handler at runtime -> that call returns
        # `{:error, :bad_module}` and NervesHubLink.Socket.init/1 CRASHES, taking the whole
        # nerves_hub_link app down (device never connects to NervesHub). See alarms.ex:39.
        {:expty, "~> 0.2.1", targets: @all_device_targets},

        # Cellular
        {:vintage_net_qmi, "~> 0.4", targets: @all_device_targets},

        # :nmea pulls in ng_can, a Linux/SocketCAN NIF (needs <linux/can.h>) that
        # only builds on the Nerves target. Override it to target-only so host
        # builds — which use the Fake CAN driver — don't try to compile the NIF.
        # :nmea references NgCan only at runtime, so host compilation is unaffected.
        {:ng_can, github: "rosepointnav/ng_can", override: true, targets: @all_device_targets}
      ]
    end
  end

  defp racing_org_deps do
    if deps_path = System.get_env("RACING_ORG_DEPS_PATH") do
      # Local development
      deps = [
        {:racing_org_tracker_nmea2000, path: Path.join(deps_path, "racing_org_tracker_nmea2000")},
        racing_org_tracker_protobuf_dep(deps_path),
        {:nmea, path: Path.join(deps_path, "nmea")}
      ]

      if Mix.env() == :test do
        deps
      else
        deps ++
          [
            {:racing_org_system_rpi3,
             path: Path.join(deps_path, "racing_org_system_rpi3"), runtime: false, targets: @all_device_targets}
          ]
      end
    else
      # Pull from GitHub
      deps = [
        {:racing_org_tracker_nmea2000, git: "git@github.com:opensailing/racing_org_tracker_nmea2000.git"},
        racing_org_tracker_protobuf_dep(),
        racing_org_nmea_dep()
      ]

      if Mix.env() == :test do
        deps
      else
        deps ++ [racing_org_system_dep()]
      end
    end
  end

  # Point at a local racing_org_tracker_protobuf checkout with RACING_ORG_TRACKER_PROTOBUF_PATH
  # while developing the wire contract; otherwise pull main from GitHub.
  defp racing_org_tracker_protobuf_dep(deps_path \\ nil) do
    cond do
      path = System.get_env("RACING_ORG_TRACKER_PROTOBUF_PATH") ->
        {:racing_org_tracker_protobuf, path: path}

      deps_path ->
        {:racing_org_tracker_protobuf, path: Path.join(deps_path, "racing_org_tracker_protobuf")}

      true ->
        {:racing_org_tracker_protobuf,
         git: "git@github.com:opensailing/racing_org_tracker_protobuf.git", branch: "main"}
    end
  end

  # The Nerves system fork is only fetched when building target firmware. Point
  # at a local checkout with RACING_ORG_SYSTEM_PATH for system development;
  # otherwise pull the OTP 28 branch from GitHub.
  defp racing_org_system_dep do
    base = [runtime: false, targets: @all_device_targets]

    if path = System.get_env("RACING_ORG_SYSTEM_PATH") do
      # Local system development: build the local source from scratch.
      {:racing_org_system_rpi3, [path: path, nerves: [compile: true]] ++ base}
    else
      # Normal build: download the PREBUILT artifact from the fork's GitHub
      # releases (artifact_sites {:github_releases, ...} -> the v<version> release).
      # No local Buildroot build and no case-sensitive volume needed.
      {:racing_org_system_rpi3,
       [git: "git@github.com:opensailing/racing_org_tracker_pro_rpi3.git", branch: "main"] ++ base}
    end
  end

  # Point at a local nmea checkout with RACING_ORG_NMEA_PATH while developing the
  # library; otherwise pull from GitHub.
  defp racing_org_nmea_dep do
    if path = System.get_env("RACING_ORG_NMEA_PATH") do
      {:nmea, path: path}
    else
      {:nmea, git: "git@github.com:opensailing/nmea", branch: "ng-can-optional"}
    end
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

  def aliases do
    [
      "firmware.upload": ["firmware", "upload"]
    ]
  end
end
