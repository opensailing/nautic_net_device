defmodule NauticNet.Discovery.Server do
  use GenServer

  require Logger

  alias NauticNet.DeviceInfo
  alias NauticNet.NMEA2000.J1939.ISOAddressClaimParams
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
    GenServer.call(@name, {:handle_address_claim_packet, packet})
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
    {:ok, %{table: table}}
  end

  @impl GenServer
  def handle_call({:handle_address_claim_packet, packet}, _sender, state) do
    existing_info =
      case :ets.lookup(state.table, packet.source_addr) do
        [] -> %DeviceInfo{}
        [{_key, info}] -> info
      end

    new_info =
      Map.merge(existing_info, %{
        source_addr: packet.source_addr,
        manufacturer_code: packet.parameters.manufacturer_code,
        unique_number: packet.parameters.unique_number
      })

    if new_info != existing_info do
      Logger.info("New device info: #{inspect(new_info)}")
      :ets.insert(state.table, {packet.source_addr, new_info})
    end

    {:reply, {:ok, new_info}, state}
  end
end
