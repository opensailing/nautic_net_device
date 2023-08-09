defmodule NauticNet.DataSetRecorder do
  @moduledoc """
  Writes DataSets to disk so that we don't lose it, and then enqueues it for upload to the server.

  The files are written to /data/datasets/{random base-64} when on device in the raw Protobuf format, which can
  be sent directly to server without any changes.

  See also: NauticNet.DataSetUploader
  """
  use GenServer

  require Logger

  alias NauticNet.DataSetUploader
  alias NauticNet.Protobuf
  alias NauticNet.Protobuf.DataSet

  @default_dataset_dir Application.get_env(:nautic_net_device, :data_set_directory)

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def add_data_points(data_points) do
    GenServer.cast(__MODULE__, {:add_data_points, data_points})
  end

  def add_network_devices(network_devices) do
    GenServer.cast(__MODULE__, {:add_network_devices, network_devices})
  end

  def init(opts) do
    Process.flag(:trap_exit, true)

    # Chunking can be specified as {x, :points} or {x, :bytes}
    chunk_every = opts[:chunk_every] || {500, :points}

    {:ok, %{data_points: [], temp_dir: dataset_directory(opts), chunk_every: chunk_every}}
  end

  def handle_cast({:add_data_points, new_data_points}, state) do
    all_data_points = new_data_points ++ state.data_points
    {chunks_to_save, next_data_points} = chunkify(all_data_points, state.chunk_every)

    for data_points <- chunks_to_save do
      save_data_points(data_points, state)
    end

    {:noreply, %{state | data_points: next_data_points}}
  end

  def handle_cast({:add_network_devices, network_devices}, state) do
    # Don't bother chunking up the DataSet if we are just sending device info
    save_network_devices(network_devices, state)

    {:noreply, state}
  end

  # Returns a tuple of {chunks_of_data_points_to_save, remaining_data_points}
  defp chunkify(data_points, {max_points, :points}) do
    data_points
    |> Enum.chunk_every(max_points)
    |> Enum.split(-1)
    |> then(fn {chunks, [rest]} -> {chunks, rest} end)
  end

  defp chunkify(data_points, {max_bytes, :bytes}) do
    data_points
    |> Protobuf.chunk_into_data_sets(max_bytes)
    |> Enum.map(fn data_set -> data_set.data_points end)
    |> Enum.split(-1)
    |> then(fn {chunks, [rest]} -> {chunks, rest} end)
  end

  defp save_data_points(data_points, state) do
    data_set =
      Protobuf.new_data_set(data_points,
        boat_identifier: NauticNet.boat_identifier()
      )

    path = Path.join(state.temp_dir, data_set.ref)
    File.write!(path, DataSet.encode(data_set))
    Logger.info("Saved #{length(data_points)} data points to #{path}")

    DataSetUploader.add_file(path)
  end

  defp save_network_devices(network_devices, state) do
    data_set =
      Protobuf.new_data_set([],
        boat_identifier: NauticNet.boat_identifier(),
        network_devices: network_devices
      )

    path = Path.join(state.temp_dir, data_set.ref)
    File.write!(path, DataSet.encode(data_set))
    Logger.info("Saved #{length(network_devices)} network devices to #{path}")

    DataSetUploader.add_file(path)
  end

  def terminate(_reason, state) do
    save_data_points(state.data_points, state)
  end

  @doc """
  Returns the directory to save the datasets to. If the directory does not exist
  create it before returning
  """
  @spec dataset_directory(Keyword.t()) :: String.t()
  def dataset_directory(opts) do
    if tmp_dir = opts[:temp_dir] do
      :ok = File.mkdir_p!(tmp_dir)
      tmp_dir
    else
      :ok = File.mkdir_p!(@default_dataset_dir)
      @default_dataset_dir
    end
  end
end
