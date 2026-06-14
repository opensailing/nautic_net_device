#
# Configuration for running the app in local development (not on-device).
#

import Config

alias RacingOrg.Tracker.NMEA2000.J1939

config :logger, level: :debug

config :nmea, NMEA.VirtualDevice,
  driver: {NMEA.NMEA2000.Driver.Fake, []},
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

config :racing_org_tracker, RacingOrg.Tracker.Pro.Serial,
  driver: RacingOrg.Tracker.Pro.Serial.Fake.Driver,
  handlers: [RacingOrg.Tracker.Pro.PacketHandler.SetTimeFromGPS]
