defmodule NauticNet.DataSetUploader do
  @moduledoc """
  Reads DataSets from disk and attempts to upload them to the server.

  On upload success, the file is delete. On failure, it will retry after 1 second.

  See also: NauticNet.DataSetRecorder
  """
  use GenServer

  require Logger

  alias NauticNet.DataSetRecorder
  alias NauticNet.Protobuf
  alias NauticNet.Protobuf.DataSet
  alias NauticNet.WebClients.HTTPClient
  alias NauticNet.WebClients.UDPClient

  @retry_after :timer.seconds(1)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def add_file(path) do
    send(__MODULE__, {:upload, path})
  end

  def init(opts) do
    via = opts[:via] || :http
    dataset_dir = DataSetRecorder.dataset_directory(opts)
    pending_files = list_pending_files(dataset_dir)

    for path <- pending_files do
      send(self(), {:upload, path})
    end

    Logger.info("Found #{length(pending_files)} files in #{dataset_dir} pending upload")

    send(self(), :ping)

    {:ok,
     %{
       dataset_dir: dataset_dir,
       via: via
     }}
  end

  defp list_pending_files(dir) do
    dir
    |> File.ls!()
    |> Enum.map(fn filename -> Path.join(dir, filename) end)
  end

  def handle_info({:upload, path}, %{via: via, dataset_dir: dir} = state) do
    binary = File.read!(path)
    size = byte_size(binary)

    case upload_data_set(binary, via) do
      :ok ->
        File.rm!(path)

        Logger.debug("Uploaded #{path} (#{size} bytes); #{length(File.ls!(dir))} file(s) remain")

      {:error, reason} ->
        Logger.warn("Error uploading #{path}: #{inspect(reason)}")
        Process.send_after(self(), {:upload, path}, @retry_after)
    end

    {:noreply, state}
  end

  def handle_info(:ping, state) do
    Protobuf.new_data_set([], boat_identifier: NauticNet.boat_identifier())
    |> DataSet.encode()
    |> upload_data_set(state.via)

    Process.send_after(self(), :ping, :timer.seconds(60))
    {:noreply, state}
  end

  defp upload_data_set(binary, :http) do
    case HTTPClient.post_data_set(binary) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp upload_data_set(binary, :udp) do
    UDPClient.send_data_set(binary)
    :ok
  end
end
