# This file is responsible for configuring your application and its
# dependencies.
#
# This configuration file is loaded before any dependency and is restricted to
# this project.
import Config

# Enable the Nerves integration with Mix
Application.start(:nerves_bootstrap)

{git_commit, 0} = System.cmd("git", ["rev-parse", "HEAD"])
git_commit = String.trim(git_commit)

target =
  if Mix.env() == :test do
    :host
  else
    Mix.target()
  end

config :racing_org_tracker_pro,
  target: target,
  api_endpoint: System.fetch_env!("API_ENDPOINT"),
  udp_endpoint: System.fetch_env!("UDP_ENDPOINT"),
  product: System.fetch_env!("PRODUCT"),
  replay_log: System.get_env("REPLAY_LOG"),
  git_commit: git_commit

# Secure-transport wiring. The SessionHolder is cheap and starts in EVERY
# environment (the UDP send path + tests read it). The WSS ChannelClient, the
# boot-time self-registration provisioner, and the post-race BulkUploader are gated
# to the real device target AND the PINNED SERVER PUBLIC KEY being configured (see
# below); on host/test they never start. Each also self-gates at runtime (the
# ChannelClient idles unless registered + identity provisioned + server pinned; the
# BootProvisioner no-ops when not pinned), so this is belt-and-suspenders.
#
# There is NO separate build-time enable flag: the single "secure transport is
# configured" signal IS the pinned server public key below. Setting
# SECURE_TRANSPORT_SERVER_PUBLIC_KEY enables secure transport; unset leaves the
# secure-transport children dormant.
#
# UDP telemetry is AEAD-only: when a live session exists each DataSet is sealed and
# sent, and with no live session the datagram is dropped (never plaintext). There is
# no device-side plaintext kill switch / fallback flag.
#
# Provisioning value read from the BUILD-HOST environment at firmware-compile time
# (same mechanism as API_ENDPOINT above) and baked into the image. Unset (host/test
# or un-provisioned firmware) -> nil, and the secure-transport modules treat
# themselves as unconfigured and stay dormant: ServerIdentity is unpinned, so the
# initiator won't connect AND the BootProvisioner has no trusted server to register
# against (it no-ops). See docs/SECURE_TRANSPORT_REFLASH.md.
#   SECURE_TRANSPORT_SERVER_PUBLIC_KEY - the server's pinned Ed25519 public key
#       (raw 32 bytes or 64-char hex); the initiator verifies the HELLO signature
#       against it (no PKI). It is also the only config the boot self-registration
#       needs (no out-of-band claim token / nonce anymore — registration is tokenless
#       and an admin associates the device to an account after it registers). It is
#       the SINGLE enable for the secure-transport children.
config :racing_org_tracker_pro, RacingOrg.Tracker.Pro.SecureTransport.ServerIdentity,
  public_key: System.get_env("SECURE_TRANSPORT_SERVER_PUBLIC_KEY")

# Host/test fallback for Application.child_specs/2 inspection. Device builds
# override this in target.exs with the persistent /data diagnostics path and the
# same direct Coordinator/Target option vocabulary.
config :racing_org_tracker_pro,
  checkpoint_head_root: Path.join(System.tmp_dir!(), "racing_org_tracker_checkpoint_heads"),
  checkpoint_hydration_journal_path: Path.join(System.tmp_dir!(), "racing_org_tracker_checkpoint_hydration.journal")

config :racing_org_tracker_pro, RacingOrg.Tracker.Pro.FirmwareValidation.Coordinator,
  rollback_after_ms: 30 * 60 * 1_000,
  soak_period_ms: 5 * 60 * 1_000,
  retry_ms: 1_000,
  store_dir: Path.join(System.tmp_dir!(), "racing_org_tracker_firmware_validation")

# Data upload filter modes:
# :permissive - Allow data to be uploaded by any sensor for a data type
# :strict - Only allow data to be uploaded if a sensor is selected -- via a filter -- for the data type
# FUTURETODO: This should probably move to a runtime configuration value
config :racing_org_tracker_pro, :data_filtering, filter_mode: :permissive

# Customize non-Elixir parts of the firmware. See
# https://hexdocs.pm/nerves/advanced-configuration.html for details.

config :nerves, :firmware, rootfs_overlay: "rootfs_overlay"

# Set the SOURCE_DATE_EPOCH date for reproducible builds.
# See https://reproducible-builds.org/docs/source-date-epoch/ for more information

config :nerves, source_date_epoch: "1655934717"

# Use Ringlogger as the logger backend and remove :console.
# See https://hexdocs.pm/ring_logger/readme.html for more information on
# configuring ring_logger.

if target != :host do
  config :logger, backends: [RingLogger]
end

# Mint adapter (pure-Elixir, no NIFs). On the device Mint auto-uses castore for
# HTTPS certificate verification (verify_peer by default), resolved at runtime.
# Replaces hackney, whose 4.x line (required by tesla 1.20) drags in an unused
# QUIC/HTTP3 stack.
config :tesla, adapter: Tesla.Adapter.Mint

# Tesla 1.20 soft-deprecates the `use Tesla` builder macro (still fully
# supported) in favor of runtime configuration. We continue to use the builder
# in RacingOrg.Tracker.Pro.WebClients.HTTPClient, so silence the per-compile warning.
config :tesla, disable_deprecated_builder_warning: true

if target == :host or target == :"" do
  import_config "host_#{Mix.env()}.exs"
else
  import_config "target.exs"
end
