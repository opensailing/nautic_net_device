defmodule RacingOrg.Tracker.Pro.HttpDataListing do
  @moduledoc """
  Starts an HTTP server to list the contents of `/data` for easy downloading of CAN log files.
  """
  def child_spec(_opts) do
    httpd_opts = [
      port: 80,
      server_name: ~c"data",
      server_root: ~c"/data",
      document_root: ~c"/data",
      bind_address: :any,
      modules: [:mod_dir, :mod_get]
    ]

    %{
      id: :httpd,
      start: {:inets, :start, [:httpd, httpd_opts]}
    }
  end
end
