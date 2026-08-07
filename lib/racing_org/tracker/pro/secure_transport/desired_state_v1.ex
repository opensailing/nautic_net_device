defmodule RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1 do
  @moduledoc """
  Frozen pure constants and closed registries for Desired State v1.

  This namespace contains no database, channel, persistence, supervision, or config
  application behavior. Runtime delivery is intentionally layered on these byte contracts.
  """

  @version 0x01
  @desired_state_version 0x0001
  @section_set_version 0x0001
  @purpose_control_v1 0x81

  @chunk_size 61_440
  @max_plaintext_size 65_536
  @max_manifest_size 16_384
  @max_section_size 16_777_216
  @max_generation_size 33_554_432
  @max_secret_size 1_024
  @max_capability_versions 8
  @max_capabilities 64
  @max_missing_ranges_per_section 512
  @max_missing_ranges 1_024

  @sections [
    {:assignment, 0x01, 0x0001, true},
    {:calibration, 0x02, 0x0001, false},
    {:clock_source, 0x03, 0x0001, false},
    {:computed_values, 0x04, 0x0001, false},
    {:polar, 0x05, 0x0001, true},
    {:tracking, 0x06, 0x0001, false},
    {:upstream, 0x07, 0x0001, false},
    {:wifi, 0x08, 0x0001, true},
    {:wind_shift, 0x09, 0x0001, false}
  ]
  @section_by_name Map.new(@sections, fn {name, code, schema, tombstone} ->
                     {name, %{code: code, schema_version: schema, tombstone_allowed: tombstone}}
                   end)
  @section_by_code Map.new(@sections, fn {name, code, schema, tombstone} ->
                     {code, %{name: name, schema_version: schema, tombstone_allowed: tombstone}}
                   end)

  @capabilities [
    {:atomic_generation, 0x0001, 0x0001},
    {:secret_injection, 0x0002, 0x0001},
    {:bounded_wifi_trial, 0x0003, 0x0001},
    {:assignment, 0x0101, 0x0001},
    {:calibration, 0x0102, 0x0001},
    {:clock_source, 0x0103, 0x0001},
    {:computed_values, 0x0104, 0x0001},
    {:polar, 0x0105, 0x0001},
    {:tracking, 0x0106, 0x0001},
    {:upstream, 0x0107, 0x0001},
    {:wifi, 0x0108, 0x0001},
    {:wind_shift, 0x0109, 0x0001}
  ]
  @capability_by_name Map.new(@capabilities, fn {name, id, version} ->
                        {name, %{id: id, version: version}}
                      end)
  @capability_by_id Map.new(@capabilities, fn {name, id, version} ->
                      {id, %{name: name, version: version}}
                    end)

  @message_types %{
    control_accept: {0x01, :server_to_device},
    readiness: {0x02, :device_to_server},
    manifest_delivery: {0x03, :server_to_device},
    section_chunk: {0x04, :server_to_device},
    resume: {0x05, :device_to_server},
    secret_delivery: {0x06, :server_to_device},
    ack: {0x07, :device_to_server}
  }
  @message_by_code Map.new(@message_types, fn {name, {code, direction}} ->
                     {code, {name, direction}}
                   end)

  @payload_domains %{
    control_accept: "RacingOrg-ControlAccept-v1",
    readiness: "RacingOrg-ControlReadiness-v1",
    manifest_delivery: "RacingOrg-DesiredStateManifestDelivery-v1",
    section_chunk: "RacingOrg-DesiredStateSectionChunk-v1",
    resume: "RacingOrg-DesiredStateResume-v1",
    secret_delivery: "RacingOrg-DesiredStateSecret-v1",
    ack: "RacingOrg-DesiredStateAck-v1"
  }

  @offer_domain "RacingOrg-ControlOffer-v1"
  @manifest_domain "RacingOrg-DesiredStateManifest-v1"
  @section_domain "RacingOrg-DesiredStateSection-v1"
  @secret_digest_domain "RacingOrg-DesiredStateSecretDigest-v1"

  @secret_kinds %{wifi_psk: 0x01}
  @secret_kind_by_code Map.new(@secret_kinds, fn {name, code} -> {code, name} end)

  @ack_statuses %{staged: 0x01, effective: 0x02, rejected: 0x03}
  @ack_status_by_code Map.new(@ack_statuses, fn {name, code} -> {code, name} end)

  @rejection_phases %{
    manifest: 0x01,
    transfer: 0x02,
    staging: 0x03,
    apply: 0x04,
    wifi_trial: 0x05,
    activation: 0x06
  }
  @rejection_phase_by_code Map.new(@rejection_phases, fn {name, code} -> {code, name} end)

  @rejection_codes %{
    malformed_manifest: 0x0001,
    incompatible_desired_state_version: 0x0002,
    incompatible_section_set: 0x0003,
    incompatible_firmware: 0x0004,
    incompatible_capability: 0x0005,
    duplicate_section: 0x0006,
    missing_section: 0x0007,
    unknown_section: 0x0008,
    unsupported_section_schema: 0x0009,
    manifest_hash_mismatch: 0x000A,
    section_hash_mismatch: 0x000B,
    stale_generation: 0x000C,
    generation_hash_conflict: 0x000D,
    boot_id_mismatch: 0x000E,
    storage_epoch_mismatch: 0x000F,
    chunk_bounds: 0x0010,
    chunk_conflict: 0x0011,
    transfer_incomplete: 0x0012,
    missing_secret: 0x0013,
    unexpected_secret: 0x0014,
    secret_reference_mismatch: 0x0015,
    section_validation_failed: 0x0016,
    section_apply_failed: 0x0017,
    storage_failed: 0x0018,
    wifi_trial_failed: 0x0019,
    activation_failed: 0x001A,
    internal_failure: 0x001B
  }
  @rejection_code_by_code Map.new(@rejection_codes, fn {name, code} -> {code, name} end)

  @reserved_message_ranges [
    {0x08..0x1F, :desired_state_extensions},
    {0x20..0x2F, :commands_task_69},
    {0x30..0x4F, :receipts_checkpoints_task_68},
    {0x50..0x5F, :health_ota_task_70},
    {0x60..0x7F, :future_standard},
    {0x80..0xFF, :unassigned_private}
  ]

  def version, do: @version
  def desired_state_version, do: @desired_state_version
  def section_set_version, do: @section_set_version
  def purpose_control_v1, do: @purpose_control_v1
  def chunk_size, do: @chunk_size
  def max_plaintext_size, do: @max_plaintext_size
  def max_manifest_size, do: @max_manifest_size
  def max_section_size, do: @max_section_size
  def max_generation_size, do: @max_generation_size
  def max_secret_size, do: @max_secret_size
  def max_capability_versions, do: @max_capability_versions
  def max_capabilities, do: @max_capabilities
  def max_missing_ranges_per_section, do: @max_missing_ranges_per_section
  def max_missing_ranges, do: @max_missing_ranges

  def sections, do: Enum.map(@sections, &elem(&1, 0))

  def section_code(name) when is_atom(name) do
    case Map.fetch(@section_by_name, name) do
      {:ok, section} -> section.code
      :error -> {:error, :unknown_section}
    end
  end

  def section_code(_), do: {:error, :unknown_section}

  def section_name(code) when is_integer(code) do
    case Map.fetch(@section_by_code, code) do
      {:ok, section} -> section.name
      :error -> {:error, :unknown_section}
    end
  end

  def section_name(_), do: {:error, :unknown_section}

  def section_schema_version(name) do
    case Map.fetch(@section_by_name, name) do
      {:ok, section} -> section.schema_version
      :error -> {:error, :unknown_section}
    end
  end

  def tombstone_allowed?(name) do
    case Map.fetch(@section_by_name, name) do
      {:ok, section} -> section.tombstone_allowed
      :error -> false
    end
  end

  def capabilities, do: @capabilities

  def capability_code(name) when is_atom(name) do
    case Map.fetch(@capability_by_name, name) do
      {:ok, capability} -> {:ok, capability.id, capability.version}
      :error -> {:error, :unknown_capability}
    end
  end

  def capability_code(_), do: {:error, :unknown_capability}

  def capability_name(id) when is_integer(id) do
    case Map.fetch(@capability_by_id, id) do
      {:ok, capability} -> {:ok, capability.name, capability.version}
      :error -> {:error, :unknown_capability}
    end
  end

  def capability_name(_), do: {:error, :unknown_capability}

  def message_types, do: @message_types
  def reserved_message_ranges, do: @reserved_message_ranges

  def message_type(name) when is_atom(name) do
    case Map.fetch(@message_types, name) do
      {:ok, {code, direction}} -> {:ok, code, direction}
      :error -> {:error, :unsupported_message_type}
    end
  end

  def message_type(code) when is_integer(code) do
    case Map.fetch(@message_by_code, code) do
      {:ok, {name, direction}} -> {:ok, name, direction}
      :error -> {:error, :unsupported_message_type}
    end
  end

  def message_type(_), do: {:error, :unsupported_message_type}

  def payload_domain(type), do: Map.fetch!(@payload_domains, type)
  def offer_domain, do: @offer_domain
  def manifest_domain, do: @manifest_domain
  def section_domain, do: @section_domain
  def secret_digest_domain, do: @secret_digest_domain

  def secret_kind(kind) when is_atom(kind) do
    case Map.fetch(@secret_kinds, kind) do
      {:ok, code} -> {:ok, code}
      :error -> {:error, :unknown_secret_kind}
    end
  end

  def secret_kind(code) when is_integer(code) do
    case Map.fetch(@secret_kind_by_code, code) do
      {:ok, kind} -> {:ok, kind}
      :error -> {:error, :unknown_secret_kind}
    end
  end

  def secret_kind(_), do: {:error, :unknown_secret_kind}

  def ack_status(status) when is_atom(status) do
    case Map.fetch(@ack_statuses, status) do
      {:ok, code} -> {:ok, code}
      :error -> {:error, :unknown_ack_status}
    end
  end

  def ack_status(code) when is_integer(code) do
    case Map.fetch(@ack_status_by_code, code) do
      {:ok, status} -> {:ok, status}
      :error -> {:error, :unknown_ack_status}
    end
  end

  def ack_status(_), do: {:error, :unknown_ack_status}

  def rejection_phase(phase) when is_atom(phase) do
    case Map.fetch(@rejection_phases, phase) do
      {:ok, code} -> {:ok, code}
      :error -> {:error, :unknown_rejection_phase}
    end
  end

  def rejection_phase(code) when is_integer(code) do
    case Map.fetch(@rejection_phase_by_code, code) do
      {:ok, phase} -> {:ok, phase}
      :error -> {:error, :unknown_rejection_phase}
    end
  end

  def rejection_phase(_), do: {:error, :unknown_rejection_phase}

  def rejection_code(reason) when is_atom(reason) do
    case Map.fetch(@rejection_codes, reason) do
      {:ok, code} -> {:ok, code}
      :error -> {:error, :unknown_rejection_code}
    end
  end

  def rejection_code(code) when is_integer(code) do
    case Map.fetch(@rejection_code_by_code, code) do
      {:ok, reason} -> {:ok, reason}
      :error -> {:error, :unknown_rejection_code}
    end
  end

  def rejection_code(_), do: {:error, :unknown_rejection_code}
end
