defmodule RacingOrg.Tracker.Pro.FirmwareValidation.Target do
  @moduledoc """
  Reads the exact authority that defines one firmware validation target.

  Runtime compatibility, durable identity, the Manager's active pointer, and the
  OperationalGate's open binding must all describe one exact authority. Missing,
  malformed, drifting, or unavailable sources remain pending.
  """

  alias RacingOrg.Tracker.Pro.DesiredState.{Manager, OperationalGate, Runtime}

  @max_u32 0xFFFF_FFFF
  @max_generation 0x7FFF_FFFF_FFFF_FFFF
  @max_u64 0xFFFF_FFFF_FFFF_FFFF
  @git_sha_bytes 40
  @max_version_bytes 128
  @compatibility_keys [:firmware_version, :firmware_git_sha, :capabilities]
  @identity_keys [:device_id, :credential_epoch, :boot_id, :storage_epoch]
  @manager_status_keys [:active, :gate, :identity, :recovery_error, :checkpoint_hydration]
  @hydration_keys [:state, :binding, :coordinator_available?]
  @pointer_keys [:device_id, :credential_epoch, :storage_epoch, :generation, :manifest_hash]
  @binding_keys [:credential_epoch, :storage_epoch, :generation, :manifest_hash]

  @type result :: {:ok, map()} | :pending

  @doc "Reads a sanitized target identity from exact runtime authority."
  @spec read(keyword()) :: result()
  def read(opts \\ [])

  def read(opts) when is_list(opts) do
    with {:ok, compatibility} <- safe_read(reader(opts, :compatibility_reader, &Runtime.compatibility/0)),
         {:ok, {:ok, identity}} <- safe_read(reader(opts, :identity_reader, &Runtime.identity/0)),
         {:ok, manager_status} <- safe_read(reader(opts, :manager_reader, &Manager.status/0)),
         {:ok, gate_status} <- safe_read(reader(opts, :gate_reader, &OperationalGate.status/0)),
         {:ok, firmware} <- exact_firmware(compatibility),
         {:ok, identity} <- exact_identity(identity),
         {:ok, active, manager_gate} <- exact_manager_authority(manager_status, identity),
         {:ok, gate_binding} <- exact_open_binding(gate_status),
         true <- manager_gate == gate_binding,
         true <- Map.take(active, @binding_keys) == gate_binding,
         {:ok, soak_period_ms} <- positive_u64(Keyword.get(opts, :soak_period_ms)) do
      {:ok,
       %{
         firmware: firmware,
         credential_epoch: identity.credential_epoch,
         desired_generation: active.generation,
         soak_period_ms: soak_period_ms
       }}
    else
      _unavailable_or_inexact -> :pending
    end
  end

  def read(_opts), do: :pending

  defp reader(opts, key, default), do: Keyword.get(opts, key, default)

  defp exact_firmware(
         %{
           firmware_version: version,
           firmware_git_sha: git_sha,
           capabilities: capabilities
         } = compatibility
       )
       when is_list(capabilities) do
    if exact_keys?(compatibility, @compatibility_keys) and valid_version?(version) and valid_git_sha?(git_sha) do
      {:ok, %{version: version, git_sha: git_sha}}
    else
      :error
    end
  end

  defp exact_firmware(_compatibility), do: :error

  defp exact_identity(identity) when is_map(identity) do
    with true <- exact_keys?(identity, @identity_keys),
         true <- valid_identifier?(identity.device_id),
         true <- identity.credential_epoch in 0..@max_u32,
         true <- valid_identifier?(identity.boot_id),
         true <- valid_identifier?(identity.storage_epoch) do
      {:ok, identity}
    else
      _invalid -> :error
    end
  end

  defp exact_identity(_identity), do: :error

  defp exact_manager_authority(
         %{
           active: active,
           gate: gate,
           identity: manager_identity,
           recovery_error: nil,
           checkpoint_hydration: checkpoint_hydration
         } = manager_status,
         identity
       ) do
    with true <- exact_keys?(manager_status, @manager_status_keys),
         true <- manager_identity == identity,
         {:ok, active} <- exact_pointer(active),
         :ok <- exact_hydration(checkpoint_hydration, active),
         {:ok, manager_binding} <- exact_open_binding(gate),
         true <- active.device_id == identity.device_id,
         true <- active.credential_epoch == identity.credential_epoch,
         true <- active.storage_epoch == identity.storage_epoch do
      {:ok, active, manager_binding}
    else
      _invalid -> :error
    end
  end

  defp exact_manager_authority(_manager_status, _identity), do: :error

  defp exact_hydration(nil, _active), do: :ok

  defp exact_hydration(
         %{state: :ready, binding: binding, coordinator_available?: true} = hydration,
         active
       ) do
    if exact_keys?(hydration, @hydration_keys) and binding == active do
      :ok
    else
      :error
    end
  end

  defp exact_hydration(_hydration, _active), do: :error

  defp exact_pointer(pointer) when is_map(pointer) do
    with true <- exact_keys?(pointer, @pointer_keys),
         true <- valid_identifier?(pointer.device_id),
         true <- pointer.credential_epoch in 0..@max_u32,
         true <- valid_identifier?(pointer.storage_epoch),
         true <- pointer.generation in 1..@max_generation,
         true <- valid_hash?(pointer.manifest_hash) do
      {:ok, pointer}
    else
      _invalid -> :error
    end
  end

  defp exact_pointer(_pointer), do: :error

  defp exact_open_binding({:open, binding}) when is_map(binding) do
    with true <- exact_keys?(binding, @binding_keys),
         true <- binding.credential_epoch in 0..@max_u32,
         true <- valid_identifier?(binding.storage_epoch),
         true <- binding.generation in 1..@max_generation,
         true <- valid_hash?(binding.manifest_hash) do
      {:ok, binding}
    else
      _invalid -> :error
    end
  end

  defp exact_open_binding(_gate_status), do: :error

  defp safe_read(reader) when is_function(reader, 0) do
    {:ok, reader.()}
  rescue
    _exception -> :error
  catch
    _kind, _reason -> :error
  end

  defp safe_read(_reader), do: :error

  defp positive_u64(value) when value in 1..@max_u64, do: {:ok, value}
  defp positive_u64(_value), do: :error

  defp valid_version?(version) when is_binary(version) do
    byte_size(version) in 1..@max_version_bytes and String.valid?(version)
  end

  defp valid_version?(_version), do: false

  defp valid_git_sha?(git_sha) when is_binary(git_sha) and byte_size(git_sha) == @git_sha_bytes do
    git_sha
    |> :binary.bin_to_list()
    |> Enum.all?(fn byte -> byte in ?0..?9 or byte in ?a..?f end)
  end

  defp valid_git_sha?(_git_sha), do: false
  defp valid_identifier?(value), do: is_binary(value) and byte_size(value) == 16 and value != <<0::128>>
  defp valid_hash?(value), do: is_binary(value) and byte_size(value) == 32

  defp exact_keys?(map, keys) do
    map_size(map) == length(keys) and Enum.all?(keys, &Map.has_key?(map, &1))
  end
end
