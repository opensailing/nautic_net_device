defmodule RacingOrg.Tracker.Pro.DurableDelivery.HealthEvent.V1 do
  @moduledoc """
  Closed, canonical v1 payload for durable tracker health evidence.

  The payload contains only firmware-validation evidence needed by operations. It
  deliberately excludes durable device/storage identity because the Outbox record
  binds those fields, and it has no generic metadata or free-form detail field.
  """

  @format_version 1
  @payload_tag :tracker_health_event
  @max_payload_bytes 4_096
  @max_u32 0xFFFF_FFFF
  @max_generation 0x7FFF_FFFF_FFFF_FFFF
  @max_u64 0xFFFF_FFFF_FFFF_FFFF
  @max_version_bytes 128
  @git_sha_bytes 40

  @event_types [
    :validation_pending,
    :validation_succeeded,
    :validation_failed,
    :rollback_deadline_expired,
    :required_processes_unhealthy,
    :outbox_unhealthy,
    :receipt_progress
  ]

  @receipt_streams [:control, :telemetry]

  @health_criteria_reasons [
    :firmware_version_mismatch,
    :firmware_git_sha_mismatch,
    :session_not_authenticated,
    :credential_epoch_mismatch,
    :desired_generation_mismatch,
    :desired_generation_not_effective,
    :desired_generation_incompatible,
    :supervisor_unhealthy,
    :owner_unhealthy,
    :control_receipt_incomplete,
    :telemetry_receipt_incomplete,
    :outbox_corrupt,
    :outbox_critical_pressure,
    :soak_period_incomplete,
    :invalid_snapshot,
    :invalid_target
  ]
  @validation_failure_reasons @health_criteria_reasons ++
                                [
                                  :firmware_validation_failed,
                                  :firmware_validation_uncertain,
                                  :firmware_validation_unavailable
                                ]
  @required_process_reasons [:supervisor_unhealthy, :owner_unhealthy]
  @outbox_reasons [:outbox_not_writable, :outbox_corrupt, :outbox_critical_pressure]
  @rollback_reasons [:rollback_deadline_expired]
  @reason_codes Enum.uniq(
                  @health_criteria_reasons ++
                    @validation_failure_reasons ++
                    @required_process_reasons ++ @outbox_reasons ++ @rollback_reasons
                )

  @common_keys [
    :event_type,
    :occurred_at_ms,
    :firmware_version,
    :firmware_git_sha,
    :target
  ]
  @target_keys [:credential_epoch, :desired_generation, :manifest_hash]
  @reason_keys @common_keys ++ [:reason_code]
  @receipt_progress_keys @common_keys ++ [:stream, :cumulative_sequence]
  @allowed_secret_like_keys [:credential_epoch]
  @secret_key_pattern ~r/(?:^|_)(?:password|passwd|passphrase|secret|token|private_key|privatekey|psk|authorization|api_key|apikey|cookie|session_id|nonce)(?:$|_)/i
  @secret_value_pattern ~r/(?:\A|[?&;\s])(?:password|passwd|passphrase|secret|token|psk|authorization|api[_-]?key|private[_-]?key)\s*[:=]/i
  @private_key_pattern ~r/-----BEGIN(?: [A-Z0-9]+)? PRIVATE KEY-----/i
  @bearer_pattern ~r/\Abearer\s+\S+/i

  @typedoc "Closed tracker health event type."
  @type event_type ::
          :validation_pending
          | :validation_succeeded
          | :validation_failed
          | :rollback_deadline_expired
          | :required_processes_unhealthy
          | :outbox_unhealthy
          | :receipt_progress

  @typedoc "Closed reason code with no free-form detail."
  @type reason_code ::
          :firmware_version_mismatch
          | :firmware_git_sha_mismatch
          | :session_not_authenticated
          | :credential_epoch_mismatch
          | :desired_generation_mismatch
          | :desired_generation_not_effective
          | :desired_generation_incompatible
          | :supervisor_unhealthy
          | :owner_unhealthy
          | :control_receipt_incomplete
          | :telemetry_receipt_incomplete
          | :outbox_not_writable
          | :outbox_corrupt
          | :outbox_critical_pressure
          | :soak_period_incomplete
          | :invalid_snapshot
          | :invalid_target
          | :firmware_validation_failed
          | :firmware_validation_uncertain
          | :firmware_validation_unavailable
          | :rollback_deadline_expired

  @typedoc "Target authority carried without device or storage identity."
  @type target :: %{
          credential_epoch: non_neg_integer(),
          desired_generation: pos_integer(),
          manifest_hash: <<_::256>>
        }

  @typedoc "Validated canonical event map."
  @type t :: map()

  @doc "Returns the closed event type registry in canonical order."
  @spec event_types() :: [event_type()]
  def event_types, do: @event_types

  @doc "Returns the authenticated receipt streams supported by health evidence."
  @spec receipt_streams() :: [:control | :telemetry]
  def receipt_streams, do: @receipt_streams

  @doc "Returns the closed reason-code registry in canonical order."
  @spec reason_codes() :: [reason_code()]
  def reason_codes, do: @reason_codes

  @doc "Validates and deterministically encodes one v1 health event."
  @spec encode(term()) :: {:ok, binary()} | {:error, term()}
  def encode(health_event) do
    with :ok <- reject_secrets(health_event),
         {:ok, canonical} <- validate(health_event),
         payload <- encode_canonical(canonical),
         true <- byte_size(payload) <= @max_payload_bytes do
      {:ok, payload}
    else
      false -> {:error, :health_event_payload_too_large}
      {:error, _reason} = error -> error
    end
  rescue
    _exception -> {:error, :invalid_health_event}
  catch
    _kind, _reason -> {:error, :invalid_health_event}
  end

  @doc "Decodes only exact canonical v1 bytes and revalidates the closed schema."
  @spec decode(term()) :: {:ok, t()} | {:error, term()}
  def decode(payload) when is_binary(payload) and byte_size(payload) <= @max_payload_bytes do
    with {:ok, decoded} <- decode_term(payload) do
      case decoded do
        {@format_version, @payload_tag, health_event} ->
          with :ok <- reject_secrets(health_event),
               {:ok, canonical} <- validate(health_event),
               true <- encode_canonical(canonical) == payload do
            {:ok, canonical}
          else
            false -> {:error, :invalid_health_event_payload}
            {:error, _reason} = error -> error
          end

        {version, @payload_tag, _health_event} when is_integer(version) ->
          {:error, :unsupported_health_event_version}

        _other ->
          {:error, :invalid_health_event_payload}
      end
    end
  end

  def decode(_payload), do: {:error, :invalid_health_event_payload}

  defp validate(%{event_type: event_type} = health_event) when event_type in @event_types do
    with :ok <- exact_variant_keys(health_event, event_type),
         :ok <- valid_u64(health_event.occurred_at_ms),
         :ok <- valid_firmware_version(health_event.firmware_version),
         :ok <- valid_git_sha(health_event.firmware_git_sha),
         {:ok, target} <- validate_target(health_event.target),
         :ok <- validate_variant(health_event, event_type) do
      {:ok, Map.put(health_event, :target, target)}
    else
      _invalid -> {:error, :invalid_health_event}
    end
  end

  defp validate(_health_event), do: {:error, :invalid_health_event}

  defp exact_variant_keys(health_event, :validation_succeeded),
    do: exact_keys(health_event, @common_keys)

  defp exact_variant_keys(health_event, event_type)
       when event_type in [
              :validation_pending,
              :validation_failed,
              :rollback_deadline_expired,
              :required_processes_unhealthy,
              :outbox_unhealthy
            ],
       do: exact_keys(health_event, @reason_keys)

  defp exact_variant_keys(health_event, :receipt_progress),
    do: exact_keys(health_event, @receipt_progress_keys)

  defp validate_variant(_health_event, :validation_succeeded), do: :ok

  defp validate_variant(%{reason_code: reason_code}, :validation_pending),
    do: member(reason_code, @health_criteria_reasons)

  defp validate_variant(%{reason_code: reason_code}, :validation_failed),
    do: member(reason_code, @validation_failure_reasons)

  defp validate_variant(%{reason_code: reason_code}, :rollback_deadline_expired),
    do: member(reason_code, @rollback_reasons)

  defp validate_variant(%{reason_code: reason_code}, :required_processes_unhealthy),
    do: member(reason_code, @required_process_reasons)

  defp validate_variant(%{reason_code: reason_code}, :outbox_unhealthy),
    do: member(reason_code, @outbox_reasons)

  defp validate_variant(%{stream: stream, cumulative_sequence: cumulative_sequence}, :receipt_progress) do
    with :ok <- member(stream, @receipt_streams),
         :ok <- valid_u64(cumulative_sequence) do
      :ok
    end
  end

  defp validate_target(target) when is_map(target) do
    with :ok <- exact_keys(target, @target_keys),
         :ok <- valid_u32(target.credential_epoch),
         :ok <- valid_generation(target.desired_generation),
         :ok <- valid_manifest_hash(target.manifest_hash) do
      {:ok,
       %{
         credential_epoch: target.credential_epoch,
         desired_generation: target.desired_generation,
         manifest_hash: target.manifest_hash
       }}
    end
  end

  defp validate_target(_target), do: {:error, :invalid_target}

  defp exact_keys(map, keys) when is_map(map) do
    if map_size(map) == length(keys) and Enum.all?(keys, &Map.has_key?(map, &1)),
      do: :ok,
      else: {:error, :invalid_keys}
  end

  defp exact_keys(_map, _keys), do: {:error, :invalid_keys}

  defp valid_firmware_version(version)
       when is_binary(version) and byte_size(version) in 1..@max_version_bytes do
    if String.valid?(version), do: :ok, else: {:error, :invalid_firmware_version}
  end

  defp valid_firmware_version(_version), do: {:error, :invalid_firmware_version}

  defp valid_git_sha(git_sha) when is_binary(git_sha) and byte_size(git_sha) == @git_sha_bytes do
    if String.match?(git_sha, ~r/\A[0-9a-f]{40}\z/), do: :ok, else: {:error, :invalid_firmware_git_sha}
  end

  defp valid_git_sha(_git_sha), do: {:error, :invalid_firmware_git_sha}

  defp valid_u32(value) when is_integer(value) and value in 0..@max_u32, do: :ok
  defp valid_u32(_value), do: {:error, :invalid_u32}

  defp valid_generation(value) when is_integer(value) and value in 1..@max_generation, do: :ok
  defp valid_generation(_value), do: {:error, :invalid_generation}

  defp valid_u64(value) when is_integer(value) and value in 0..@max_u64, do: :ok
  defp valid_u64(_value), do: {:error, :invalid_u64}

  defp valid_manifest_hash(<<_::256>>), do: :ok
  defp valid_manifest_hash(_manifest_hash), do: {:error, :invalid_manifest_hash}

  defp member(value, values) do
    if value in values, do: :ok, else: {:error, :unknown_enum_value}
  end

  defp reject_secrets(term) do
    if secret_bearing?(term, nil),
      do: {:error, :secret_bearing_health_event},
      else: :ok
  end

  defp secret_bearing?(map, _parent_key) when is_map(map) do
    Enum.any?(map, fn {key, value} ->
      secret_key?(key) or secret_bearing?(value, key)
    end)
  end

  defp secret_bearing?(list, parent_key) when is_list(list),
    do: Enum.any?(list, &secret_bearing?(&1, parent_key))

  defp secret_bearing?(tuple, parent_key) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.any?(&secret_bearing?(&1, parent_key))

  defp secret_bearing?(value, parent_key) when is_binary(value) do
    parent_key != :manifest_hash and textual_secret?(value)
  end

  defp secret_bearing?(_value, _parent_key), do: false

  defp secret_key?(key) when key in @allowed_secret_like_keys, do: false

  defp secret_key?(key) when is_atom(key) or is_binary(key) do
    key
    |> to_string()
    |> String.replace("-", "_")
    |> then(&Regex.match?(@secret_key_pattern, &1))
  end

  defp secret_key?(_key), do: false

  defp textual_secret?(value) do
    String.valid?(value) and
      (Regex.match?(@secret_value_pattern, value) or
         Regex.match?(@private_key_pattern, value) or
         Regex.match?(@bearer_pattern, value))
  end

  defp encode_canonical(health_event) do
    :erlang.term_to_binary(
      {@format_version, @payload_tag, health_event},
      [:deterministic, minor_version: 2]
    )
  end

  defp decode_term(payload) do
    {:ok, :erlang.binary_to_term(payload, [:safe])}
  rescue
    _exception -> {:error, :invalid_health_event_payload}
  catch
    _kind, _reason -> {:error, :invalid_health_event_payload}
  end
end
