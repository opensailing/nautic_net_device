defmodule NauticNet.Discovery do
  @moduledoc """
  Handles the discovery and lookup of metadata for devices on the NMEA2000 network.
  """
  use GenServer

  alias NauticNet.Discovery
  alias NauticNet.Protobuf.NetworkDevice
  alias NMEA.NMEA2000.VirtualDevice
  alias NMEA.NMEA2000.VirtualDevice.NetworkMonitor.DeviceInfo

  def start_link(config) do
    GenServer.start_link(__MODULE__, config)
  end

  def init(args) do
    vd_pid = Map.get(args, :virtual_device_pid)
    {:ok, {:interval, timer_ref}}= :timer.send_interval(5000, :update_devices)
    {:ok, %{timer_ref: timer_ref, virtual_device_pid: vd_pid}}
  end

  def handle_info(:update_devices, state) do
    state.virtual_device_pid
    |> VirtualDevice.known_network_devices()
    |> Enum.map(fn {_source_addr, %DeviceInfo{} = device_info} ->
      NetworkDevice.new(
        hw_id: NauticNet.DeviceInfo.hw_id(device_info.nmea_name),
        name: device_info.model_id
      )
    end)
    |> NauticNet.DataSetRecorder.add_network_devices()

    {:noreply, state}
  end
end
