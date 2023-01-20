defmodule NauticNet.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @max_unfragmented_udp_payload_size {508, :bytes}

  @impl true
  def start(_type, _args) do
    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: NauticNet.Supervisor]

    children =
      List.flatten([
        NauticNet.Telemetry,
        {NauticNet.CAN, can_config()},
        {NauticNet.Discovery, discovery_config()},
        {NauticNet.WebClients.UDPClient.Server, udp_config()},
        {NauticNet.DataSetRecorder, chunk_every: @max_unfragmented_udp_payload_size},
        {NauticNet.DataSetUploader, via: :udp},
        # {NauticNet.DataSetUploader, via: :http},
        children(target())
      ])

    Supervisor.start_link(children, opts)
  end

  def children(:host) do
    []
  end

  def children(_device_target) do
    [
      NauticNet.HttpDataListing
    ]
  end

  def target do
    Application.get_env(:nautic_net_device, :target)
  end

  def can_config do
    Application.get_env(:nautic_net_device, NauticNet.CAN, [])
  end

  def discovery_config do
    Application.get_env(:nautic_net_device, NauticNet.Discovery, [])
  end

  def udp_config do
    endpoint = Application.get_env(:nautic_net_device, :udp_endpoint, "localhost:4001")
    [hostname, port] = String.split(endpoint, ":")

    [hostname: hostname, port: String.to_integer(port)]
  end
end
