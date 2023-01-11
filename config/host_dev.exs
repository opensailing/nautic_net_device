import Config

config :logger, level: :debug, backends: [:console]

config :nautic_net_device, NauticNet.CAN,
  driver: NauticNet.CAN.Fake.Driver,
  handlers: [
    NauticNet.PacketHandler.DiscoverDevices,
    NauticNet.PacketHandler.EmitTelemetry
    # {NauticNet.PacketHandler.CreateGPSLog, format: :gpx},
    # {NauticNet.PacketHandler.CreateGPSLog, format: :csv},
    # NauticNet.PacketHandler.SetTimeFromGPS,
    # NauticNet.PacketHandler.Inspect
  ]
