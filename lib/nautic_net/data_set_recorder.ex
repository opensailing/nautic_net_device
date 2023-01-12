defmodule NauticNet.DataSetRecorder do
  @moduledoc """
  Writes DataSets to disk so that we don't lose it, and then enqueues it for upload to the server.

  The files are written to /tmp/datasets/{random base-64} in the raw Protobuf format, which can
  be sent directly to server without any changes.

  See also: NauticNet.DataSetUploader
  """
  use GenServer

  require Logger

  alias NauticNet.DataSetUploader
  alias NauticNet.Protobuf
  alias NauticNet.Protobuf.DataSet

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def add_data_points(data_points) do
    GenServer.cast(__MODULE__, {:add_data_points, data_points})
  end

  def init(opts) do
    Process.flag(:trap_exit, true)
    temp_dir = opts[:temp_dir] || "/tmp/datasets"
    File.mkdir_p!(temp_dir)

    # Chunking can be specified as {x, :points} or {x, :bytes}
    chunk_every = opts[:chunk_every] || {500, :points}

    {:ok, %{data_points: [], temp_dir: temp_dir, chunk_every: chunk_every}}
  end

  def handle_cast({:add_data_points, new_data_points}, state) do
    all_data_points = new_data_points ++ state.data_points
    {chunks_to_save, next_data_points} = chunkify(all_data_points, state.chunk_every)

    for data_points <- chunks_to_save do
      save_data_points(data_points, state)
    end

    {:noreply, %{state | data_points: next_data_points}}
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

  def terminate(_reason, state) do
    save_data_points(state.data_points, state)
  end
end
