defmodule NauticNet.DataSetUploader do
  @moduledoc """
  Reads DataSets from disk and attempts to upload them to the server.

  On upload success, the file is delete. On failure, it will retry after 1 second.

  See also: NauticNet.DataSetRecorder
  """
  use GenServer

  require Logger

  alias NauticNet.WebClient

  @retry_after :timer.seconds(1)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def add_file(path) do
    GenServer.cast(__MODULE__, {:add_file, path})
  end

  def init(opts) do
    temp_dir = opts[:temp_dir] || "/tmp/datasets"
    send(self(), :upload_next)
    {:ok, %{pending_files: list_pending_files(temp_dir), temp_dir: temp_dir, retrying?: false}}
  end

  defp list_pending_files(temp_dir) do
    temp_dir
    |> File.ls!()
    |> Enum.map(fn filename -> Path.join(temp_dir, filename) end)
  end

  def handle_cast({:add_file, path}, state) do
    unless state.retrying? do
      send(self(), :upload_next)
    end

    {:noreply, %{state | pending_files: [path | state.pending_files]}}
  end

  def handle_info(:upload_next, %{pending_files: []} = state), do: {:noreply, state}

  def handle_info(:upload_next, %{pending_files: [path | rest]} = state) do
    binary = File.read!(path)

    case WebClient.post_data_set(binary) do
      {:ok, _} ->
        Logger.info("Uploaded #{path}; #{length(rest)} file(s) remaining")
        File.rm!(path)
        send(self(), :upload_next)
        {:noreply, %{state | pending_files: rest, retrying?: false}}

      {:error, reason} ->
        Logger.warn("Error uploading #{path}: #{inspect(reason)}; #{length(state.pending_files)} file(s) remaining")
        Process.send_after(self(), :upload_next, @retry_after)
        {:noreply, %{state | pending_files: state.pending_files, retrying?: true}}
    end
  end
end
