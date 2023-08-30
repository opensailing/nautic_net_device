#
# Configuration for running the app in local development (not on-device).
#

import Config

alias NauticNet.NMEA2000.J1939

config :logger, level: :debug, backends: [:console]

config :nautic_net_device, NauticNet.CAN,
  driver: NauticNet.CAN.Fake.Driver,
  handlers: [
    NauticNet.PacketHandler.DiscoverDevices,
    NauticNet.PacketHandler.EmitTelemetry,
    # {NauticNet.PacketHandler.CreateGPSLog, format: :gpx},
    # {NauticNet.PacketHandler.CreateGPSLog, format: :csv},
    # NauticNet.PacketHandler.SetTimeFromGPS,
    {NauticNet.PacketHandler.Inspect,
     only: [
       J1939.ISORequestParams,
       J1939.ISOAddressClaimParams,
       J1939.ProductInformationParams
     ]}
  ]

config :nautic_net_device, NauticNet.Serial,
  driver: NauticNet.Serial.Fake.Driver,
  handlers: [NauticNet.PacketHandler.SetTimeFromGPS]
