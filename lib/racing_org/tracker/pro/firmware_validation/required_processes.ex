defmodule RacingOrg.Tracker.Pro.FirmwareValidation.RequiredProcesses do
  @moduledoc """
  Projects required supervisor and owner liveness into closed health statuses.

  Process resolution, owner discovery, and liveness inspection are injectable.
  Empty, malformed, unavailable, or exceptional sources fail closed.
  """

  alias RacingOrg.Tracker.Pro.DesiredState.Applier
  alias RacingOrg.Tracker.Pro.DesiredState.Manager
  alias RacingOrg.Tracker.Pro.DesiredState.OperationalGate
  alias RacingOrg.Tracker.Pro.DurableDelivery.Outbox.Owner
  alias RacingOrg.Tracker.Pro.SecureTransport.{BootProvisioner, ChannelClient, SessionHolder}

  @default_supervisors [
    RacingOrg.Tracker.Pro.DesiredState.RuntimeIdentity,
    BootProvisioner,
    SessionHolder,
    Applier,
    Manager,
    OperationalGate,
    Owner,
    ChannelClient
  ]

  @type status :: %{supervisor: :healthy | :unhealthy, owner: :healthy | :unhealthy}

  @doc "Returns aggregate fail-closed health for required supervisors and owners."
  @spec status(keyword()) :: status()
  def status(opts \\ [])

  def status(opts) when is_list(opts) do
    process_resolver = Keyword.get(opts, :process_resolver, &default_resolve/1)
    alive_reader = Keyword.get(opts, :alive_reader, &Process.alive?/1)

    %{
      supervisor:
        health(
          healthy_references?(
            Keyword.get(opts, :supervisors, @default_supervisors),
            process_resolver,
            alive_reader
          )
        ),
      owner:
        health(
          healthy_owners?(
            Keyword.get(opts, :owners_reader, &Applier.owners/0),
            process_resolver,
            alive_reader
          )
        )
    }
  end

  def status(_opts), do: %{supervisor: :unhealthy, owner: :unhealthy}

  defp healthy_owners?(reader, process_resolver, alive_reader) when is_function(reader, 0) do
    case safe_call(reader) do
      {:ok, owners} when is_map(owners) and map_size(owners) > 0 ->
        healthy_references?(Map.values(owners), process_resolver, alive_reader)

      _unavailable ->
        false
    end
  end

  defp healthy_owners?(_reader, _process_resolver, _alive_reader), do: false

  defp healthy_references?(references, process_resolver, alive_reader)
       when is_list(references) and references != [] do
    Enum.all?(references, fn reference ->
      with {:ok, {:ok, pid}} <- safe_call(fn -> process_resolver.(reference) end),
           {:ok, true} <- safe_call(fn -> alive_reader.(pid) end) do
        true
      else
        _unhealthy -> false
      end
    end)
  end

  defp healthy_references?(_references, _process_resolver, _alive_reader), do: false

  defp default_resolve(pid) when is_pid(pid), do: {:ok, pid}

  defp default_resolve(reference) do
    case GenServer.whereis(reference) do
      pid when is_pid(pid) -> {:ok, pid}
      nil -> :error
    end
  rescue
    _exception -> :error
  catch
    _kind, _reason -> :error
  end

  defp safe_call(fun) do
    {:ok, fun.()}
  rescue
    _exception -> :error
  catch
    _kind, _reason -> :error
  end

  defp health(true), do: :healthy
  defp health(false), do: :unhealthy
end
