#
# Configuration for running the app on the device.
#
import Config

case System.get_env("CAN_DRIVER") do
  "canusb" ->
    config :racing_org_tracker_pro, RacingOrg.Tracker.Pro.CAN,
      driver: {RacingOrg.Tracker.Pro.CAN.CANUSB.Driver, start_logging?: true},
      handlers: [
        RacingOrg.Tracker.Pro.PacketHandler.DiscoverDevices,
        RacingOrg.Tracker.Pro.PacketHandler.Inspect,
        RacingOrg.Tracker.Pro.PacketHandler.SetTimeFromGPS,
        RacingOrg.Tracker.Pro.PacketHandler.EmitTelemetry
      ]

  "pican-m" ->
    config :nmea, NMEA.VirtualDevice,
      driver: {NMEA.NMEA2000.Driver.NgCan, []},
      class_code: 25,
      function_code: 130,
      manufacture_code: 999,
      manufacture_string: "Dockyard - www.dockyard.com",
      product_code: 888,
      previous_address: 34,
      device_instance: 0,
      data_instance: 0,
      system_instance: 0,
      model_id: "proto-123",
      model_version: "v1.0.0",
      software_version: "v0.0.1",
      serial_number: "12345",
      load_equivelency_number: 0,
      certification_level: :level_a

  "fake" ->
    config :racing_org_tracker_pro, RacingOrg.Tracker.Pro.CAN, driver: RacingOrg.Tracker.Pro.CAN.Fake.Driver

  "disabled" ->
    config :racing_org_tracker_pro, RacingOrg.Tracker.Pro.CAN, false

  _else ->
    raise "the CAN_DRIVER environment variable must be one of: canusb, pican-m, disabled"
end

config :racing_org_tracker_pro, RacingOrg.Tracker.Pro.Serial,
  driver: RacingOrg.Tracker.Pro.Serial.SixFab.Driver,
  handlers: [RacingOrg.Tracker.Pro.PacketHandler.SetTimeFromGPS]

config :racing_org_tracker_pro,
  data_set_directory: "/data/datasets",
  assignment_directory: "/data/assignment",
  polar_directory: "/data/polars",
  race_archive_directory: "/data/races",
  tracking_directory: "/data/tracking",
  upstream_directory: "/data/upstream",
  computed_values_directory: "/data/computed_values",
  clock_source_directory: "/data/clock_source",
  calibration_directory: "/data/calibration",
  wind_shift_directory: "/data/wind_shift"

# NervesHub remote management (OTA firmware updates + remote console).
#
# Replaces the old Tailscale-for-remote-access setup: the device connects
# *outbound* to a NervesHub instance, so it works through cellular NAT with no
# VPN. Configured via env vars at build time and gated on them being present —
# without them, NervesHubLink is disabled (`connect: false`) and the device
# still boots normally.
#
# Provision a Product in NervesHub and set:
#   NERVES_HUB_HOST    the device-endpoint hostname of your NervesHub instance
#   NERVES_HUB_KEY     from the Product's "Shared Secrets" settings
#   NERVES_HUB_SECRET  from the Product's "Shared Secrets" settings
nerves_hub_host = System.get_env("NERVES_HUB_HOST")
nerves_hub_key = System.get_env("NERVES_HUB_KEY")
nerves_hub_secret = System.get_env("NERVES_HUB_SECRET")

# Firmware-update signature verification. NervesHubLink applies an OTA only if the
# downloaded `.fw` is signed by one of these fwup public keys (sign with the matching
# `fwup-key.priv` via `fwup -S -s fwup-key.priv ...` — see the release flow). Because
# the key is baked into the firmware and `request_fwup_public_keys` is left at its
# default `false`, the device trusts ONLY this pinned key and never asks the server to
# hand it a verification key — the server cannot substitute its own. The list supports
# overlap for rotation: bake the new key alongside the old, OTA that out, then rotate
# the signing key and later drop the old entry. Public keys are safe to commit; the
# private half lives only in 1Password.
fwup_public_keys = ["v2Qo/t6aqBf0nAJu6P9HPDzttBIyiSTOh8CIw4JTXQw="]

if nerves_hub_host && nerves_hub_key && nerves_hub_secret do
  config :nerves_hub_link,
    connect: true,
    host: nerves_hub_host,
    fwup_public_keys: fwup_public_keys,
    # Enable the NervesHub remote IEx "Console" (an IEx session against the running
    # app, over the NervesHub connection). Off by default; we turn it on for remote
    # diagnosis/management of a cellular-only device. (System Shell is the separate
    # LocalShell/expty extension — a bash shell — already available.)
    remote_iex: true,
    shared_secret: [
      product_key: nerves_hub_key,
      product_secret: nerves_hub_secret
    ]
else
  config :nerves_hub_link, connect: false, fwup_public_keys: fwup_public_keys
end

config :logger, level: :info

# Use shoehorn to start the main application. See the shoehorn
# docs for separating out critical OTP applications such as those
# involved with firmware updates.

config :shoehorn,
  init: [:nerves_runtime, :nerves_pack],
  app: Mix.Project.config()[:app]

# Nerves Runtime can enumerate hardware devices and send notifications via
# SystemRegistry. This slows down startup and not many programs make use of
# this feature.

config :nerves_runtime, :kernel, use_system_registry: false

# Erlinit can be configured without a rootfs_overlay. See
# https://github.com/nerves-project/erlinit/ for more information on
# configuring erlinit.

config :nerves,
  erlinit: [
    hostname_pattern: "nerves-%s"
  ]

# Configure the device for SSH IEx prompt access and firmware updates
#
# * See https://hexdocs.pm/nerves_ssh/readme.html for general SSH configuration
# * See https://hexdocs.pm/ssh_subsystem_fwup/readme.html for firmware updates

authorized_keys =
  System.get_env("AUTHORIZED_KEYS", "")
  |> String.split(";")
  |> Enum.map(&String.trim/1)
  |> Enum.reject(&(&1 == ""))

if authorized_keys == [],
  do:
    Mix.raise("""
    No SSH public keys found in AUTHORIZED_KEYS environment variable. An ssh authorized key is needed to
    log into the Nerves device and update firmware on it using ssh.
    See your project's config.exs for this error message.
    """)

config :nerves_ssh, authorized_keys: authorized_keys

# Configure the network using vintage_net
# See https://github.com/nerves-networking/vintage_net for more information
# Wi-Fi is configured ONLY when credentials were baked in at build time. On a
# cellular-only deployment build (no creds), `wlan0` is left UNCONFIGURED so
# wpa_supplicant never runs and the radio never scans (scanning is the bulk of the
# Wi-Fi power draw) — and `:wifi_enabled` is set false so `RacingOrg.Tracker.Pro.WiFiPower` powers
# the radio down at boot to save battery. With creds present (bench/dev build), Wi-Fi
# is a normal client and provides LAN/SSH access; cellular is still used in the field.
wifi_ssid = System.get_env("VINTAGE_NET_WIFI_SSID")
wifi_psk = System.get_env("VINTAGE_NET_WIFI_PSK")
wifi_enabled? = is_binary(wifi_ssid) and wifi_ssid != "" and is_binary(wifi_psk) and wifi_psk != ""

config :racing_org_tracker_pro, :wifi_enabled, wifi_enabled?

wlan0_config =
  if wifi_enabled? do
    [
      {"wlan0",
       %{
         type: VintageNetWiFi,
         vintage_net_wifi: %{
           networks: [%{key_mgmt: :wpa_psk, ssid: wifi_ssid, psk: wifi_psk}]
         },
         ipv4: %{method: :dhcp}
       }}
    ]
  else
    []
  end

config :vintage_net,
  regulatory_domain: "US",
  config:
    [
      {"usb0", %{type: VintageNetDirect}},
      {"eth0",
       %{
         type: VintageNetEthernet,
         ipv4: %{method: :dhcp}
       }}
    ] ++
      wlan0_config ++
      [
        {"wwan0",
         %{
           type: VintageNetQMI,
           vintage_net_qmi: %{service_providers: [%{apn: "super"}]}
         }}
      ]

config :mdns_lite,
  # The `hosts` key specifies what hostnames mdns_lite advertises.  `:hostname`
  # advertises the device's hostname.local. For the official Nerves systems, this
  # is "nerves-<4 digit serial#>.local".  The `"nerves"` host causes mdns_lite
  # to advertise "nerves.local" for convenience. If more than one Nerves device
  # is on the network, it is recommended to delete "nerves" from the list
  # because otherwise any of the devices may respond to nerves.local leading to
  # unpredictable behavior.

  hosts: [:hostname],
  ttl: 120,

  # Advertise the following services over mDNS.
  services: [
    %{
      protocol: "ssh",
      transport: "tcp",
      port: 22
    },
    %{
      protocol: "sftp-ssh",
      transport: "tcp",
      port: 22
    },
    %{
      protocol: "epmd",
      transport: "tcp",
      port: 4369
    }
  ]

# Import target specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
# Uncomment to use target specific configurations

# import_config "#{Mix.target()}.exs"
