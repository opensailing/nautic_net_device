defmodule NauticNet.Discovery.Server do
  use GenServer

  require Logger

  alias NauticNet.DeviceInfo
  alias NauticNet.Network
  alias NauticNet.NMEA2000.Manufacturers
  alias NauticNet.NMEA2000.J1939.ISOAddressClaimParams
  alias NauticNet.NMEA2000.J1939.ProductInformationParams
  alias NauticNet.NMEA2000.Packet

  @name __MODULE__
  @table __MODULE__

  def start_link(false), do: :ignore

  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: @name)
  end

  @doc """
  Ingests a packet that could
  """

  def handle_packet(%Packet{parameters: %ISOAddressClaimParams{}} = packet) do
    GenServer.call(@name, {:handle_packet, packet})
  end

  def handle_packet(%Packet{parameters: %ProductInformationParams{}} = packet) do
    GenServer.call(@name, {:handle_packet, packet})
  end

  def handle_packet(_packet), do: :ignored

  @doc """
  Returns a single device's info.

  Returns {:ok, map} if the source address is known, and :error if it is unknown
  """
  def fetch(source_address) do
    case :ets.lookup(@table, source_address) do
      [{_, device_info}] -> {:ok, device_info}
      [] -> :error
    end
  end

  @doc """
  Returns a map of all known device infos with the source address as keys
  """
  def all do
    @table
    |> :ets.match({:_, :"$1"})
    |> List.flatten()
    |> Map.new(&{&1.source_addr, &1})
  end

  @doc """
  Deletes all discovered devices.
  """
  def forget_all do
    Logger.info("Forgetting all known hardware")
    :ets.delete_all_objects(@table)
  end

  @impl GenServer
  def init(_config) do
    table = :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])

    # Wait for CANBUS to initialize on first boot
    Process.send_after(self(), :poll_all_devices, :timer.seconds(5))

    {:ok, %{table: table}}
  end

  @impl GenServer
  def handle_call({:handle_packet, %Packet{parameters: %ISOAddressClaimParams{} = params} = packet}, _sender, state) do
    info =
      merge_device_info(state.table, packet.source_addr, %{
        source_addr: packet.source_addr,
        manufacturer_code: params.manufacturer_code,
        unique_number: params.unique_number,
        manufacturer_name: Manufacturers.get(params.manufacturer_code) || "Unknown"
      })

    {:reply, {:ok, info}, state}
  end

  def handle_call({:handle_packet, %Packet{parameters: %ProductInformationParams{} = params} = packet}, _sender, state) do
    info = merge_device_info(state.table, packet.source_addr, Map.from_struct(params))

    {:reply, {:ok, info}, state}
  end

  @impl GenServer
  def handle_info(:poll_all_devices, state) do
    Network.request_address_claims()
    Network.request_product_infos()

    # Wait a few seconds to give devices an opportunity to asynchronously respond
    Process.send_after(self(), :upload_devices, :timer.seconds(5))

    # Keep periodically polling the network
    Process.send_after(self(), :poll_all_devices, :timer.minutes(5))

    {:noreply, state}
  end

  def handle_info(:upload_devices, state) do
    all()
    |> Enum.map(fn {_source_addr, %DeviceInfo{} = device_info} ->
      NauticNet.Protobuf.NetworkDevice.new(
        hw_id: DeviceInfo.hw_id(device_info),
        name: device_info.model_id
      )
    end)
    |> NauticNet.DataSetRecorder.add_network_devices()

    {:noreply, state}
  end

  defp merge_device_info(table, source_addr, changes) do
    existing_info =
      case :ets.lookup(table, source_addr) do
        [] -> %DeviceInfo{}
        [{_key, info}] -> info
      end

    # If the hardware identifiers have changed, there is a new device at this source address, so wipe out existing info
    existing_info =
      if changes[:unique_number] &&
           changes[:manufacturer_code] &&
           changes[:unique_number] != existing_info.unique_number &&
           changes[:manufacturer_code] != existing_info.manufacturer_code do
        %DeviceInfo{}
      else
        existing_info
      end

    new_info = Map.merge(existing_info, changes)

    if new_info != existing_info do
      Logger.info("New device info: #{inspect(new_info)}")
      :ets.insert(table, {source_addr, new_info})
    end

    new_info
  end
end
