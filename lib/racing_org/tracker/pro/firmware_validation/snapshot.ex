defmodule RacingOrg.Tracker.Pro.FirmwareValidation.Snapshot do
  @moduledoc """
  Builds the closed point-in-time input consumed by `HealthCriteria`.

  Every source is projected onto the exact health snapshot shape. Source errors,
  exits, malformed values, and absent receipt/outbox integrations fail closed;
  raw sessions, owner references, receipt payloads, and outbox entries are never
  copied into the returned snapshot.
  """

  alias RacingOrg.Tracker.Pro
  alias RacingOrg.Tracker.Pro.DesiredState.Applier
  alias RacingOrg.Tracker.Pro.DesiredState.Manager
  alias RacingOrg.Tracker.Pro.SecureTransport.SessionHolder

  @max_u32 0xFFFF_FFFF
  @max_generation 0x7FFF_FFFF_FFFF_FFFF
  @receipt_statuses [:succeeded, :pending, :failed]

  @type timing :: %{observed_at_ms: integer(), soak_started_at_ms: integer()}

  @doc "Builds an exact, sanitized health-criteria snapshot."
  @spec build(timing(), keyword()) :: map()
  def build(timing, opts \\ []) do
    {session, session_source_healthy?} = session_projection(reader(opts, :session_reader, &default_session_reader/1))

    {desired_state, manager_source_healthy?} =
      manager_projection(reader(opts, :manager_reader, &default_manager_reader/1))

    {owner_health, applier_source_healthy?} =
      owner_projection(
        reader(opts, :applier_owners_reader, &default_applier_owners_reader/1),
        Keyword.get(opts, :owner_alive_reader, &default_owner_alive?/1)
      )

    source_process_health = %{
      supervisor: health_status(session_source_healthy? and manager_source_healthy? and applier_source_healthy?),
      owner: owner_health
    }

    %{
      firmware: %{
        version:
          opts
          |> reader(:firmware_version_reader, &default_firmware_version_reader/1)
          |> read_binary(),
        git_sha:
          opts
          |> reader(:git_commit_reader, &default_git_commit_reader/1)
          |> read_binary()
      },
      session: session,
      desired_state: desired_state,
      process_health: process_health(opts, source_process_health),
      receipts: receipt_health(opts),
      outbox: outbox_status(Keyword.get(opts, :outbox_reader, fn -> :unavailable end)),
      timing: normalize_timing(timing)
    }
  end

  defp reader(opts, key, default_builder) do
    Keyword.get_lazy(opts, key, fn -> default_builder.(opts) end)
  end

  defp default_firmware_version_reader(_opts) do
    fn ->
      case Application.spec(:racing_org_tracker_pro, :vsn) do
        nil -> ""
        version -> to_string(version)
      end
    end
  end

  defp default_git_commit_reader(_opts), do: &Pro.git_commit/0

  defp default_session_reader(opts) do
    session_holder = Keyword.get(opts, :session_holder, SessionHolder)
    fn -> SessionHolder.get_current_session(session_holder) end
  end

  defp default_manager_reader(opts) do
    manager = Keyword.get(opts, :manager, Manager)
    fn -> Manager.status(manager) end
  end

  defp default_applier_owners_reader(opts) do
    applier = Keyword.get(opts, :applier, Applier)
    fn -> Applier.owners(applier) end
  end

  defp read_binary(reader) do
    case safe_read(reader) do
      {:ok, value} when is_binary(value) -> value
      _other -> ""
    end
  end

  defp session_projection(reader) do
    case safe_read(reader) do
      {:ok, {:ok, %{credential_epoch: epoch}}} when epoch in 0..@max_u32 ->
        {%{authenticated: true, credential_epoch: epoch}, true}

      {:ok, {:error, :no_session}} ->
        {%{authenticated: false, credential_epoch: 0}, true}

      _other ->
        {%{authenticated: false, credential_epoch: 0}, false}
    end
  end

  defp manager_projection(reader) do
    case safe_read(reader) do
      {:ok, %{active: active, gate: gate, recovery_error: recovery_error}}
      when is_map(active) ->
        case active_generation(active) do
          {:ok, generation} ->
            desired_state = %{
              generation: generation,
              effective: effective?(active, gate),
              compatible: is_nil(recovery_error)
            }

            {desired_state, true}

          :error ->
            {unhealthy_desired_state(), false}
        end

      _other ->
        {unhealthy_desired_state(), false}
    end
  end

  defp active_generation(%{generation: generation})
       when generation in 1..@max_generation,
       do: {:ok, generation}

  defp active_generation(_active), do: :error

  defp effective?(active, {:open, binding}) when is_map(binding) do
    Map.take(active, [:credential_epoch, :storage_epoch, :generation, :manifest_hash]) == binding
  end

  defp effective?(_active, _gate), do: false

  defp unhealthy_desired_state do
    %{generation: 1, effective: false, compatible: false}
  end

  defp owner_projection(reader, owner_alive_reader) do
    case safe_read(reader) do
      {:ok, owners} when is_map(owners) and map_size(owners) > 0 ->
        owner_health =
          if Enum.all?(Map.values(owners), &safe_owner_alive?(owner_alive_reader, &1)) do
            :healthy
          else
            :unhealthy
          end

        {owner_health, true}

      {:ok, owners} when is_map(owners) ->
        {:unhealthy, true}

      _other ->
        {:unhealthy, false}
    end
  end

  defp safe_owner_alive?(reader, owner) do
    case safe_read(fn -> reader.(owner) end) do
      {:ok, true} -> true
      _other -> false
    end
  end

  defp default_owner_alive?(pid) when is_pid(pid), do: Process.alive?(pid)

  defp default_owner_alive?(owner) do
    case GenServer.whereis(owner) do
      pid when is_pid(pid) -> Process.alive?(pid)
      nil -> false
    end
  rescue
    _exception -> false
  catch
    _kind, _reason -> false
  end

  defp process_health(opts, source_process_health) do
    case Keyword.fetch(opts, :process_health_reader) do
      {:ok, reader} -> aggregate_process_health(reader)
      :error -> source_process_health
    end
  end

  defp aggregate_process_health(reader) do
    case safe_read(reader) do
      {:ok, %{supervisor: supervisor, owner: owner}}
      when supervisor in [:healthy, :unhealthy] and owner in [:healthy, :unhealthy] ->
        %{supervisor: supervisor, owner: owner}

      _unavailable ->
        %{supervisor: :unhealthy, owner: :unhealthy}
    end
  end

  defp receipt_health(opts) do
    case Keyword.fetch(opts, :receipt_health_reader) do
      {:ok, reader} -> aggregate_receipt_health(reader)
      :error -> legacy_receipt_health(opts)
    end
  end

  defp aggregate_receipt_health(reader) do
    case safe_read(reader) do
      {:ok, %{control: control, telemetry: telemetry}}
      when control in @receipt_statuses and telemetry in @receipt_statuses ->
        %{control: control, telemetry: telemetry}

      _unavailable ->
        %{control: :failed, telemetry: :failed}
    end
  end

  defp legacy_receipt_health(opts) do
    %{
      control: receipt_status(Keyword.get(opts, :control_receipt_reader, fn -> :pending end)),
      telemetry: receipt_status(Keyword.get(opts, :telemetry_receipt_reader, fn -> :pending end))
    }
  end

  defp receipt_status(reader) do
    case safe_read(reader) do
      {:ok, status} when status in @receipt_statuses -> status
      _other -> :pending
    end
  end

  defp outbox_status(reader) do
    case safe_read(reader) do
      {:ok, %{corrupt: corrupt?, critical_pressure: pressure?}}
      when is_boolean(corrupt?) and is_boolean(pressure?) ->
        %{corrupt: corrupt?, critical_pressure: pressure?}

      _other ->
        %{corrupt: true, critical_pressure: true}
    end
  end

  defp normalize_timing(%{observed_at_ms: observed_at_ms, soak_started_at_ms: soak_started_at_ms})
       when is_integer(observed_at_ms) and observed_at_ms >= 0 and is_integer(soak_started_at_ms) and
              soak_started_at_ms >= 0 and soak_started_at_ms <= observed_at_ms do
    %{observed_at_ms: observed_at_ms, soak_started_at_ms: soak_started_at_ms}
  end

  defp normalize_timing(_timing), do: %{observed_at_ms: 0, soak_started_at_ms: 0}

  defp health_status(true), do: :healthy
  defp health_status(false), do: :unhealthy

  defp safe_read(reader) do
    {:ok, reader.()}
  rescue
    _exception -> :error
  catch
    _kind, _reason -> :error
  end
end
