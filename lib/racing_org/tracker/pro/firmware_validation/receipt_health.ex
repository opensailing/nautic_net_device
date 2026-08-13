defmodule RacingOrg.Tracker.Pro.FirmwareValidation.ReceiptHealth do
  @moduledoc """
  Fail-closed adapters for control and telemetry receipt round trips.

  Read-side receipt probes and the authenticated Outbox Owner acknowledgement are
  injected so integration can prove exact transport round trips without exposing
  receipt payloads to health snapshots.
  """

  alias RacingOrg.Tracker.Pro.DurableDelivery.Outbox.Owner

  @statuses [:succeeded, :pending, :failed]

  @type status :: :succeeded | :pending | :failed

  @doc "Reads exact control and telemetry round-trip statuses."
  @spec read(keyword()) :: %{control: status(), telemetry: status()}
  def read(opts \\ [])

  def read(opts) when is_list(opts) do
    %{
      control: read_status(Keyword.get(opts, :control_reader, fn -> :pending end)),
      telemetry: read_status(Keyword.get(opts, :telemetry_reader, fn -> :pending end))
    }
  end

  def read(_opts), do: %{control: :failed, telemetry: :failed}

  @doc "Acknowledges one authenticated receipt through the durable owner adapter."
  @spec acknowledge(map(), keyword()) :: :succeeded | :failed
  def acknowledge(receipt, opts \\ [])

  def acknowledge(receipt, opts) when is_map(receipt) and is_list(opts) do
    acknowledger =
      Keyword.get(opts, :acknowledger, fn authenticated_receipt, acknowledge_opts ->
        Owner.acknowledge(Owner, authenticated_receipt, acknowledge_opts)
      end)

    case safe_call(fn -> acknowledger.(receipt, idempotent: true) end) do
      {:ok, {:ok, removed}} when is_list(removed) -> :succeeded
      _unacknowledged -> :failed
    end
  end

  def acknowledge(_receipt, _opts), do: :failed

  defp read_status(reader) do
    case safe_call(reader) do
      {:ok, status} when status in @statuses -> status
      _invalid -> :failed
    end
  end

  defp safe_call(fun) when is_function(fun, 0) do
    {:ok, fun.()}
  rescue
    _exception -> :error
  catch
    _kind, _reason -> :error
  end

  defp safe_call(_fun), do: :error
end
