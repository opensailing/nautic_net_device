defmodule RacingOrg.Tracker.Pro.DataSetUploader do
  @moduledoc """
  Moves encoded DataSets from the legacy on-disk spool to their configured owner.

  Logger deployments use durable delivery: the exact file bytes are admitted to
  the Outbox and the legacy file is removed only after a valid durable admission
  receipt. Uplink deployments may retain the legacy transport strategy because
  they have no Outbox owner.

  See also: RacingOrg.Tracker.Pro.DataSetRecorder
  """
  use GenServer

  require Logger

  alias RacingOrg.Tracker.Pro.DataSetRecorder
  alias RacingOrg.Tracker.Pro.DurableDelivery.Producer.DataSet, as: DurableProducer
  alias RacingOrg.Tracker.Protobuf.DataSet
  alias RacingOrg.Tracker.Pro.WebClients.HTTPClient
  alias RacingOrg.Tracker.Pro.WebClients.UDPClient

  @retry_after :timer.seconds(1)

  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  def add_file(path) do
    send(__MODULE__, {:upload, path})
  end

  @impl true
  def init(opts) do
    delivery = Keyword.get(opts, :delivery, :legacy)
    dataset_dir = DataSetRecorder.dataset_directory(opts)
    pending_files = list_pending_files(dataset_dir)

    state = %{
      dataset_dir: dataset_dir,
      delivery: delivery,
      via: Keyword.get(opts, :via, :http),
      outbox: Keyword.get(opts, :outbox),
      producer: Keyword.get(opts, :producer, DurableProducer),
      upload: Keyword.get(opts, :upload, &upload_data_set/2),
      remove_file: Keyword.get(opts, :remove_file, &File.rm/1),
      retry_after: Keyword.get(opts, :retry_after, @retry_after),
      ping?: delivery == :legacy and Keyword.get(opts, :ping?, true)
    }

    for path <- pending_files do
      send(self(), {:upload, path})
    end

    Logger.info("Found #{length(pending_files)} legacy DataSet files pending delivery")

    if state.ping?, do: send(self(), :ping)

    {:ok, state}
  end

  defp list_pending_files(dir) do
    dir
    |> File.ls!()
    |> Enum.sort()
    |> Enum.map(&Path.join(dir, &1))
  end

  @impl true
  def handle_info({:upload, path}, %{delivery: :durable} = state) do
    case File.read(path) do
      {:ok, binary} -> admit_to_outbox(path, binary, state)
      {:error, :enoent} -> :ok
      {:error, reason} -> retry_upload(path, {:read_source, reason}, state)
    end

    {:noreply, state}
  end

  def handle_info({:upload, path}, %{delivery: :legacy} = state) do
    case File.read(path) do
      {:ok, binary} -> upload_legacy(path, binary, state)
      {:error, :enoent} -> :ok
      {:error, reason} -> retry_upload(path, {:read_source, reason}, state)
    end

    {:noreply, state}
  end

  def handle_info({:remove, path}, state) do
    remove_authoritative_source(path, state)
    {:noreply, state}
  end

  def handle_info(:ping, %{ping?: true} = state) do
    RacingOrg.Tracker.Pro.data_set([])
    |> DataSet.encode()
    |> safe_upload(state)

    Process.send_after(self(), :ping, :timer.seconds(60))
    {:noreply, state}
  end

  def handle_info(:ping, state), do: {:noreply, state}

  defp admit_to_outbox(path, binary, state) do
    result = safe_admit(binary, path, state)

    case result do
      {:ok, receipt} ->
        if valid_admission_receipt?(receipt) do
          remove_authoritative_source(path, state)
        else
          retry_upload(path, :invalid_outbox_response, state)
        end

      {:error, reason} ->
        retry_upload(path, reason, state)

      _other ->
        retry_upload(path, :invalid_outbox_response, state)
    end
  end

  defp safe_admit(binary, path, state) do
    state.producer.admit(binary, outbox: state.outbox, source_id: path)
  rescue
    _exception -> {:error, :producer_failure}
  catch
    kind, _reason when kind in [:throw, :exit] -> {:error, :producer_failure}
  end

  defp valid_admission_receipt?(%{
         stream: :telemetry,
         device_id: <<_::128>>,
         credential_epoch: credential_epoch,
         storage_epoch: <<_::128>>,
         sequence: sequence,
         payload_hash: <<_::256>>,
         cumulative_sequence: cumulative_sequence
       })
       when is_integer(credential_epoch) and credential_epoch >= 0 and is_integer(sequence) and sequence > 0 and
              is_integer(cumulative_sequence) and cumulative_sequence >= 0,
       do: true

  defp valid_admission_receipt?(_receipt), do: false

  defp upload_legacy(path, binary, state) do
    case safe_upload(binary, state) do
      :ok -> remove_authoritative_source(path, state)
      {:error, reason} -> retry_upload(path, reason, state)
      _other -> retry_upload(path, :invalid_legacy_upload_response, state)
    end
  end

  defp safe_upload(binary, state) do
    state.upload.(binary, state.via)
  rescue
    exception -> {:error, {:legacy_upload_failure, exception}}
  catch
    kind, reason when kind in [:throw, :exit] -> {:error, {:legacy_upload_failure, {kind, reason}}}
  end

  defp remove_authoritative_source(path, state) do
    case safe_remove(path, state) do
      :ok ->
        Logger.debug(
          "Removed legacy DataSet source after its configured owner accepted it; #{pending_count(state.dataset_dir)} file(s) remain"
        )

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        Logger.warning("Legacy DataSet source removal failed after acceptance: #{inspect(reason)}; retrying")
        Process.send_after(self(), {:remove, path}, state.retry_after)
    end
  end

  defp safe_remove(path, state) do
    state.remove_file.(path)
  rescue
    exception -> {:error, {:remove_source_failure, exception}}
  catch
    kind, reason when kind in [:throw, :exit] -> {:error, {:remove_source_failure, {kind, reason}}}
  end

  defp retry_upload(path, reason, state) do
    Logger.warning("DataSet delivery was not accepted: #{inspect(reason)}; retaining legacy source and retrying")
    Process.send_after(self(), {:upload, path}, state.retry_after)
  end

  defp pending_count(dir) do
    case File.ls(dir) do
      {:ok, files} -> length(files)
      {:error, _reason} -> :unknown
    end
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
