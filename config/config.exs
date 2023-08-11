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

config :nautic_net_device,
  target: Mix.target(),
  api_endpoint: System.fetch_env!("API_ENDPOINT"),
  udp_endpoint: System.fetch_env!("UDP_ENDPOINT"),
  product: System.fetch_env!("PRODUCT"),
  replay_log: System.get_env("REPLAY_LOG"),
  git_commit: git_commit

# Customize non-Elixir parts of the firmware. See
# https://hexdocs.pm/nerves/advanced-configuration.html for details.

config :nerves, :firmware, rootfs_overlay: "rootfs_overlay"

# Set the SOURCE_DATE_EPOCH date for reproducible builds.
# See https://reproducible-builds.org/docs/source-date-epoch/ for more information

config :nerves, source_date_epoch: "1655934717"

# Use Ringlogger as the logger backend and remove :console.
# See https://hexdocs.pm/ring_logger/readme.html for more information on
# configuring ring_logger.

config :logger, backends: [RingLogger]

config :tesla, adapter: Tesla.Adapter.Hackney

if Mix.target() == :host or Mix.target() == :"" do
  import_config "host_#{Mix.env()}.exs"
else
  import_config "target.exs"
end
