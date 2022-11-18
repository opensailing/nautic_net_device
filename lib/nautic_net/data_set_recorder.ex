defmodule NauticNet.DataSetRecorder do
  use GenServer

  require Logger

  alias NauticNet.DataSetUploader
  alias NauticNet.Protobuf
  alias NauticNet.Protobuf.DataSet

  @data_points_per_file 500

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

    {:ok, %{data_points: [], temp_dir: temp_dir}}
  end

  def handle_cast({:add_data_points, data_points}, state) do
    state = %{state | data_points: data_points ++ state.data_points}

    if length(state.data_points) >= @data_points_per_file do
      {:noreply, save_data_points(state)}
    else
      {:noreply, state}
    end
  end

  defp save_data_points(state) do
    data_set = Protobuf.new_data_set(state.data_points)

    path = Path.join(state.temp_dir, data_set.ref)
    File.write!(path, DataSet.encode(data_set))
    Logger.info("Saved #{length(state.data_points)} data points to #{path}")

    DataSetUploader.add_file(path)

    %{state | data_points: []}
  end

  def terminate(_reason, state) do
    save_data_points(state)
  end
end
