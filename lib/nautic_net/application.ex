defmodule NauticNet.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  require Logger

  @max_unfragmented_udp_payload_size {508, :bytes}

  @impl true
  def start(_type, _args) do
    opts = [strategy: :one_for_one, name: NauticNet.Supervisor]

    children = children(product(), target())

    with {:ok, sup} <- Supervisor.start_link(children, opts) do
      start_virtual_device_and_handlers(sup)
      maybe_replay_log()
      maybe_start_tailscale()
      {:ok, sup}
    end
  end

  defp start_virtual_device_and_handlers(sup) do
    {:ok, emit_telemetry_pid} = Supervisor.start_child(sup, NauticNet.PacketHandler.EmitTelemetry)
    {:ok, system_time_pid} = Supervisor.start_child(sup, NauticNet.PacketHandler.SetTimeFromGPS)
    {:ok, pid} = on_start = Supervisor.start_child(sup, {NMEA.NMEA2000.VirtualDevice, virtual_device_config()})
    # Discovery is not a handler but requires the VirtualDevice pid
    {:ok, _discovery_pid} = Supervisor.start_child(sup, {NauticNet.Discovery, %{virtual_device_pid: pid}})

    # Handlers must be a list of pids which define a
    # def handle_info({:data, data})
    # See NMEA.NMEA2000.VirtualDevice.AddressManager for an example
    handlers = [emit_telemetry_pid, system_time_pid]

    # Register the handlers with the virtual device
    for handler <- handlers do
      NMEA.NMEA2000.VirtualDevice.register_handler(pid, handler)
    end

    on_start
  end

  # Product: NMEA 2000 standalone, on-board device
  defp children(:logger, _target) do
    [
      NauticNet.Telemetry,
      {NMEA.NMEA2000.Driver.SocketcandTCP, can_config()},
      {NauticNet.Serial, serial_config()},
      {NauticNet.WebClients.UDPClient, udp_config()},
      {NauticNet.DataSetRecorder, chunk_every: @max_unfragmented_udp_payload_size},
      {NauticNet.DataSetUploader, via: :udp}
    ]
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

  defp virtual_device_config do
    %{
      driver: {NMEA.NMEA2000.Driver.SocketcandTCP, []},
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
      certification_level: :level_a,
      save_fn: fn key, value ->
        File.write("/root/#{key}.setting", :erlang.term_to_binary(value))
      end,
      retrieve_fn: fn key ->
        "/root/#{key}.setting"
        |> File.read()
        |> case do
          {:ok, setting} -> :erlang.binary_to_term(setting)
          {:error, _reason} -> nil
        end
      end
    }
  end

  defp serial_config do
    Application.get_env(:nautic_net_device, NauticNet.Serial, [])
  end

  defp discovery_config do
    Application.get_env(:nautic_net_device, NauticNet.Discovery, [])
  end

  defp udp_config do
    endpoint = Application.get_env(:nautic_net_device, :udp_endpoint, "localhost:4001")
    [hostname, port] = String.split(endpoint, ":")

    [hostname: hostname, port: String.to_integer(port)]
  end

  def maybe_replay_log do
    if filename = Application.get_env(:nautic_net_device, :replay_log) do
      NauticNet.DeviceCLI.replay_log(filename, realtime?: true)
    end
  end

  defp maybe_start_tailscale do
    if NauticNet.Tailscale.enabled?() do
      NauticNet.Tailscale.start!()
      Logger.info("Tailscale started")
    else
      Logger.info("Tailscale will not start: no auth key provided")
    end
  end
end
