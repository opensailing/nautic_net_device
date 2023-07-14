#
# Configuration for running the app on the device.
#
import Config

handlers = [
  NauticNet.PacketHandler.DiscoverDevices,
  # NauticNet.PacketHandler.Inspect,
  NauticNet.PacketHandler.SetTimeFromGPS,
  NauticNet.PacketHandler.EmitTelemetry
]

case System.get_env("CAN_DRIVER") do
  "canusb" ->
    config :nautic_net_device, NauticNet.CAN,
      driver: {NauticNet.CAN.CANUSB.Driver, start_logging?: true},
      handlers: handlers

  "pican-m" ->
    config :nautic_net_device, NauticNet.CAN,
      driver: {NauticNet.CAN.PiCAN.Driver, []},
      handlers: handlers

  "fake" ->
    config :nautic_net_device, NauticNet.CAN,
      driver: NauticNet.CAN.Fake.Driver,
      handlers: handlers

  "disabled" ->
    config :nautic_net_device, NauticNet.CAN, false

  _else ->
    raise "the CAN_DRIVER environment variable must be one of: canusb, pican-m, disabled"
end

config :nautic_net_device,
  tailscale_auth_key: System.get_env("TAILSCALE_AUTH_KEY")

config :logger, level: :debug

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
config :vintage_net,
  regulatory_domain: "US",
  config: [
    {"usb0", %{type: VintageNetDirect}},
    {"eth0",
     %{
       type: VintageNetEthernet,
       ipv4: %{method: :dhcp}
     }},
    {"wlan0",
     %{
       type: VintageNetWiFi,
       vintage_net_wifi: %{
         networks: [
           %{
             key_mgmt: :wpa_psk,
             ssid: System.get_env("VINTAGE_NET_WIFI_SSID"),
             psk: System.get_env("VINTAGE_NET_WIFI_PSK")
           }
         ]
       },
       ipv4: %{method: :dhcp}
     }},
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
