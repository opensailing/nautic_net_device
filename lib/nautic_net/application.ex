defmodule NauticNet.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @max_unfragmented_udp_payload_size {508, :bytes}

  @impl true
  def start(_type, _args) do
    opts = [strategy: :one_for_one, name: NauticNet.Supervisor]

    children = children(product(), target())

    Supervisor.start_link(children, opts)
  end

  # Product: NMEA 2000 standalone, on-board device
  defp children(:logger, target) do
    http_server = if target == :host, do: [], else: [NauticNet.HttpDataListing]

    [
      NauticNet.Telemetry,
      {NauticNet.CAN, can_config()},
      {NauticNet.Discovery, discovery_config()},
      {NauticNet.WebClients.UDPClient, udp_config()},
      {NauticNet.DataSetRecorder, chunk_every: @max_unfragmented_udp_payload_size},
      {NauticNet.DataSetUploader, via: :udp}
    ] ++ http_server
  end

  # Product: Base station receiver node for nautic_net_tracker_mini
  defp children(:uplink, _target) do
    [
      {NauticNet.WebClients.UDPClient, udp_config()},
      {NauticNet.DataSetRecorder, chunk_every: @max_unfragmented_udp_payload_size},
      {NauticNet.DataSetUploader, via: :udp},
      NauticNet.BaseStation
    ]
  end

  defp product do
    case Application.get_env(:nautic_net_device, :product) do
      "logger" ->
        :logger

      "uplink" ->
        :uplink

      unexpected ->
        raise """
        unexpected PRODUCT #{inspect(unexpected)}; must be one of:

             - "logger" for NMEA2000 device
             - "uplink" for mini tracker base station uplink node

        """
    end
  end

  defp target do
    Application.get_env(:nautic_net_device, :target)
  end

  defp can_config do
    Application.get_env(:nautic_net_device, NauticNet.CAN, [])
  end

  defp discovery_config do
    Application.get_env(:nautic_net_device, NauticNet.Discovery, [])
  end

  defp udp_config do
    endpoint = Application.get_env(:nautic_net_device, :udp_endpoint, "localhost:4001")
    [hostname, port] = String.split(endpoint, ":")

    [hostname: hostname, port: String.to_integer(port)]
  end
end
