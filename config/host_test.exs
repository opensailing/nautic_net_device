#
# Configuration for testing the app in local development (not on-device).
#
import Config

config :logger, :default_handler, false

# Don't start these servers for testing; we will supervise them manually
# in the test cases
config :racing_org_tracker_pro, RacingOrg.Tracker.Pro.CAN, false
config :racing_org_tracker_pro, RacingOrg.Tracker.Pro.Discovery, false
config :racing_org_tracker_pro, RacingOrg.Tracker.Pro.Serial, false

# Upstream signal selection: never write to the target's /data path under test.
# Tests pass explicit per-test temp store dirs; this is a defensive default for
# the application-supervised instance on a CI/host machine.
config :racing_org_tracker_pro,
  upstream_directory: Path.join(System.tmp_dir!(), "racing_org_tracker_upstream_test")

# Device-identity key store: never write to the target's /data path under test.
# Tests pass an explicit per-test temp `:base_path`; this is a defensive default
# so an unparameterized call cannot touch /data on a CI/host machine.
config :racing_org_tracker_pro, RacingOrg.Tracker.Pro.SecureTransport.KeyStore,
  base_path: Path.join(System.tmp_dir!(), "racing_org_tracker_keystore_test")

# The application boots an NMEA 2000 VirtualDevice as part of its supervision
# tree. Give it the Fake driver so the tree starts without real CAN hardware.
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
