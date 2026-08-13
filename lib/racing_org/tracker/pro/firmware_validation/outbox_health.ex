defmodule RacingOrg.Tracker.Pro.FirmwareValidation.OutboxHealth do
  @moduledoc """
  Projects the durable Outbox Owner status onto firmware health criteria.

  The owner status adapter and critical-pressure threshold are injectable. Any
  unavailable, malformed, unbound, quarantined, or non-accepting state fails closed.
  """

  alias RacingOrg.Tracker.Pro.DurableDelivery.Outbox.Owner

  @default_critical_pressure_percent 90
  @status_keys [
    :accepting,
    :quarantined,
    :storage_epoch_bound,
    :pending_entries,
    :pending_bytes,
    :disk_bytes,
    :max_entries,
    :max_bytes,
    :max_disk_bytes,
    :loss_authorizations,
    :streams
  ]
  @closed %{corrupt: true, critical_pressure: true}

  @type status :: %{corrupt: boolean(), critical_pressure: boolean()}

  @doc "Reads and sanitizes durable outbox integrity and pressure."
  @spec read(keyword()) :: status()
  def read(opts \\ [])

  def read(opts) when is_list(opts) do
    status_reader = Keyword.get(opts, :status_reader, fn -> Owner.status(Owner) end)
    threshold = threshold(Keyword.get(opts, :critical_pressure_percent, @default_critical_pressure_percent))

    with {:ok, owner_status} <- safe_read(status_reader),
         {:ok, usage} <- exact_healthy_status(owner_status) do
      %{
        corrupt: false,
        critical_pressure:
          critical?(usage.pending_entries, usage.max_entries, threshold) or
            critical?(usage.pending_bytes, usage.max_bytes, threshold) or
            critical?(usage.disk_bytes, usage.max_disk_bytes, threshold)
      }
    else
      _unhealthy -> @closed
    end
  end

  def read(_opts), do: @closed

  defp exact_healthy_status(status) when is_map(status) do
    with true <- exact_keys?(status, @status_keys),
         true <- status.accepting,
         false <- status.quarantined,
         true <- status.storage_epoch_bound,
         true <- nonnegative?(status.pending_entries),
         true <- nonnegative?(status.pending_bytes),
         true <- nonnegative?(status.disk_bytes),
         true <- positive?(status.max_entries),
         true <- positive?(status.max_bytes),
         true <- positive?(status.max_disk_bytes),
         true <- nonnegative?(status.loss_authorizations),
         true <- positive?(status.streams) do
      {:ok, status}
    else
      _invalid -> :error
    end
  end

  defp exact_healthy_status(_status), do: :error

  defp critical?(used, maximum, threshold_percent) do
    used * 100 >= maximum * threshold_percent
  end

  defp threshold(value) when value in 1..100, do: value
  defp threshold(_value), do: @default_critical_pressure_percent

  defp safe_read(reader) when is_function(reader, 0) do
    {:ok, reader.()}
  rescue
    _exception -> :error
  catch
    _kind, _reason -> :error
  end

  defp safe_read(_reader), do: :error
  defp nonnegative?(value), do: is_integer(value) and value >= 0
  defp positive?(value), do: is_integer(value) and value > 0

  defp exact_keys?(map, keys) do
    map_size(map) == length(keys) and Enum.all?(keys, &Map.has_key?(map, &1))
  end
end
