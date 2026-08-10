defmodule RacingOrg.Tracker.Pro.FirmwareValidation.HealthCriteria do
  @moduledoc """
  Pure health-criteria evaluator for the tracker A/B OTA validation gate.

  The caller supplies an exact target and a point-in-time snapshot. This module
  performs no process inspection, I/O, firmware validation, reboot, or rollback.
  It returns `:ready` only when every criterion passes. Before the target deadline,
  unmet criteria are returned as retryable `{:pending, unmet}` results; at or after
  the deadline the same closed diagnostics become `{:rollback_required, unmet}`.

  `process_health` is deliberately an aggregate supplied by the integration layer:
  `:supervisor` represents all required supervisor processes and `:owner` represents
  all required owner processes. The integration layer also owns the continuous-soak
  clock and must reset `soak_started_at_ms` whenever health continuity is broken.

  Input maps must have exactly the documented keys. Unknown keys, arbitrary metadata,
  PIDs, receipt payloads, and secrets are rejected. Diagnostics contain only stable
  atoms from `diagnostic_codes/0`; observed and expected values are never returned.
  """

  @max_u32 0xFFFF_FFFF
  @max_u64 0xFFFF_FFFF_FFFF_FFFF
  @git_sha_bytes 40
  @max_version_bytes 128

  @criteria [
    :firmware_version,
    :firmware_git_sha,
    :session_authentication,
    :credential_epoch,
    :desired_generation,
    :desired_generation_effective,
    :desired_generation_compatibility,
    :supervisor_health,
    :owner_health,
    :control_receipt_round_trip,
    :telemetry_receipt_round_trip,
    :outbox_integrity,
    :outbox_pressure,
    :soak_period,
    :input
  ]

  @diagnostic_codes [
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

  @status_registry %{
    process_health: [:healthy, :unhealthy],
    receipt_round_trip: [:succeeded, :pending, :failed],
    result: [:ready, :pending, :rollback_required]
  }

  @snapshot_keys [
    :firmware,
    :session,
    :desired_state,
    :process_health,
    :receipts,
    :outbox,
    :timing
  ]
  @snapshot_firmware_keys [:version, :git_sha]
  @session_keys [:authenticated, :credential_epoch]
  @desired_state_keys [:generation, :effective, :compatible]
  @process_health_keys [:supervisor, :owner]
  @receipt_keys [:control, :telemetry]
  @outbox_keys [:corrupt, :critical_pressure]
  @snapshot_timing_keys [:observed_at_ms, :soak_started_at_ms]

  @target_keys [
    :firmware,
    :credential_epoch,
    :desired_generation,
    :soak_period_ms,
    :deadline_at_ms
  ]
  @target_firmware_keys [:version, :git_sha]

  @typedoc "A criterion from the module's closed criteria registry."
  @type criterion ::
          :firmware_version
          | :firmware_git_sha
          | :session_authentication
          | :credential_epoch
          | :desired_generation
          | :desired_generation_effective
          | :desired_generation_compatibility
          | :supervisor_health
          | :owner_health
          | :control_receipt_round_trip
          | :telemetry_receipt_round_trip
          | :outbox_integrity
          | :outbox_pressure
          | :soak_period
          | :input

  @typedoc "A sanitized code from the module's closed diagnostic registry."
  @type diagnostic_code ::
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
          | :outbox_corrupt
          | :outbox_critical_pressure
          | :soak_period_incomplete
          | :invalid_snapshot
          | :invalid_target

  @type process_health_status :: :healthy | :unhealthy
  @type receipt_round_trip_status :: :succeeded | :pending | :failed

  @type snapshot :: %{
          firmware: %{version: binary(), git_sha: binary()},
          session: %{authenticated: boolean(), credential_epoch: non_neg_integer()},
          desired_state: %{
            generation: pos_integer(),
            effective: boolean(),
            compatible: boolean()
          },
          process_health: %{
            supervisor: process_health_status(),
            owner: process_health_status()
          },
          receipts: %{
            control: receipt_round_trip_status(),
            telemetry: receipt_round_trip_status()
          },
          outbox: %{corrupt: boolean(), critical_pressure: boolean()},
          timing: %{observed_at_ms: non_neg_integer(), soak_started_at_ms: non_neg_integer()}
        }

  @type target :: %{
          firmware: %{version: binary(), git_sha: binary()},
          credential_epoch: non_neg_integer(),
          desired_generation: pos_integer(),
          soak_period_ms: pos_integer(),
          deadline_at_ms: non_neg_integer()
        }

  @type unmet_criterion :: %{criterion: criterion(), diagnostic_code: diagnostic_code()}
  @type result ::
          :ready
          | {:pending, [unmet_criterion()]}
          | {:rollback_required, [unmet_criterion()]}

  @doc "Returns the closed, deterministic criterion ordering used by `evaluate/2`."
  @spec criteria() :: [criterion()]
  def criteria, do: @criteria

  @doc "Returns every sanitized diagnostic code that `evaluate/2` can emit."
  @spec diagnostic_codes() :: [diagnostic_code()]
  def diagnostic_codes, do: @diagnostic_codes

  @doc "Returns the accepted closed status registries for integration validation."
  @spec status_registry() :: %{
          process_health: [process_health_status()],
          receipt_round_trip: [receipt_round_trip_status()],
          result: [:ready | :pending | :rollback_required]
        }
  def status_registry, do: @status_registry

  @doc """
  Evaluates a structured health `snapshot` against the exact expected `target`.

  Malformed targets require rollback immediately because their deadline cannot be
  trusted. A malformed snapshot remains pending when a valid observed time proves
  the deadline has not arrived; otherwise it fails closed as rollback-required.
  """
  @spec evaluate(term(), term()) :: result()
  def evaluate(snapshot, target) do
    with {:ok, target} <- validate_target(target) do
      case observed_at(snapshot) do
        {:ok, observed_at_ms} ->
          evaluate_at(snapshot, target, observed_at_ms)

        :error ->
          {:rollback_required, [unmet(:input, :invalid_snapshot)]}
      end
    else
      :error -> {:rollback_required, [unmet(:input, :invalid_target)]}
    end
  end

  defp evaluate_at(snapshot, target, observed_at_ms) do
    case validate_snapshot(snapshot) do
      {:ok, snapshot} ->
        snapshot
        |> unmet_criteria(target)
        |> classify(observed_at_ms, target.deadline_at_ms)

      :error ->
        classify([unmet(:input, :invalid_snapshot)], observed_at_ms, target.deadline_at_ms)
    end
  end

  defp unmet_criteria(snapshot, target) do
    [
      failed_unless(
        snapshot.firmware.version == target.firmware.version,
        :firmware_version,
        :firmware_version_mismatch
      ),
      failed_unless(
        snapshot.firmware.git_sha == target.firmware.git_sha,
        :firmware_git_sha,
        :firmware_git_sha_mismatch
      ),
      failed_unless(
        snapshot.session.authenticated,
        :session_authentication,
        :session_not_authenticated
      ),
      failed_unless(
        snapshot.session.credential_epoch == target.credential_epoch,
        :credential_epoch,
        :credential_epoch_mismatch
      ),
      failed_unless(
        snapshot.desired_state.generation == target.desired_generation,
        :desired_generation,
        :desired_generation_mismatch
      ),
      failed_unless(
        snapshot.desired_state.effective,
        :desired_generation_effective,
        :desired_generation_not_effective
      ),
      failed_unless(
        snapshot.desired_state.compatible,
        :desired_generation_compatibility,
        :desired_generation_incompatible
      ),
      failed_unless(
        snapshot.process_health.supervisor == :healthy,
        :supervisor_health,
        :supervisor_unhealthy
      ),
      failed_unless(
        snapshot.process_health.owner == :healthy,
        :owner_health,
        :owner_unhealthy
      ),
      failed_unless(
        snapshot.receipts.control == :succeeded,
        :control_receipt_round_trip,
        :control_receipt_incomplete
      ),
      failed_unless(
        snapshot.receipts.telemetry == :succeeded,
        :telemetry_receipt_round_trip,
        :telemetry_receipt_incomplete
      ),
      failed_unless(not snapshot.outbox.corrupt, :outbox_integrity, :outbox_corrupt),
      failed_unless(
        not snapshot.outbox.critical_pressure,
        :outbox_pressure,
        :outbox_critical_pressure
      ),
      failed_unless(
        soak_elapsed?(snapshot.timing, target.soak_period_ms),
        :soak_period,
        :soak_period_incomplete
      )
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp classify([], _observed_at_ms, _deadline_at_ms), do: :ready

  defp classify(unmet_criteria, observed_at_ms, deadline_at_ms)
       when observed_at_ms < deadline_at_ms,
       do: {:pending, unmet_criteria}

  defp classify(unmet_criteria, _observed_at_ms, _deadline_at_ms),
    do: {:rollback_required, unmet_criteria}

  defp failed_unless(true, _criterion, _diagnostic_code), do: nil
  defp failed_unless(false, criterion, diagnostic_code), do: unmet(criterion, diagnostic_code)

  defp unmet(criterion, diagnostic_code),
    do: %{criterion: criterion, diagnostic_code: diagnostic_code}

  defp soak_elapsed?(%{observed_at_ms: observed_at_ms, soak_started_at_ms: soak_started_at_ms}, soak_period_ms) do
    observed_at_ms - soak_started_at_ms >= soak_period_ms
  end

  defp validate_snapshot(
         %{
           firmware: firmware,
           session: session,
           desired_state: desired_state,
           process_health: process_health,
           receipts: receipts,
           outbox: outbox,
           timing: timing
         } = snapshot
       ) do
    with true <- exact_keys?(snapshot, @snapshot_keys),
         true <- valid_snapshot_firmware?(firmware),
         true <- valid_session?(session),
         true <- valid_desired_state?(desired_state),
         true <- valid_process_health?(process_health),
         true <- valid_receipts?(receipts),
         true <- valid_outbox?(outbox),
         true <- valid_snapshot_timing?(timing) do
      {:ok, snapshot}
    else
      false -> :error
    end
  end

  defp validate_snapshot(_snapshot), do: :error

  defp validate_target(
         %{
           firmware: firmware,
           credential_epoch: credential_epoch,
           desired_generation: desired_generation,
           soak_period_ms: soak_period_ms,
           deadline_at_ms: deadline_at_ms
         } = target
       ) do
    with true <- exact_keys?(target, @target_keys),
         true <- valid_target_firmware?(firmware),
         true <- uint32?(credential_epoch),
         true <- positive_uint64?(desired_generation),
         true <- positive_uint64?(soak_period_ms),
         true <- uint64?(deadline_at_ms) do
      {:ok, target}
    else
      false -> :error
    end
  end

  defp validate_target(_target), do: :error

  defp observed_at(%{timing: %{observed_at_ms: observed_at_ms}}) do
    if uint64?(observed_at_ms), do: {:ok, observed_at_ms}, else: :error
  end

  defp observed_at(_snapshot), do: :error

  defp valid_snapshot_firmware?(%{version: version, git_sha: git_sha} = firmware) do
    exact_keys?(firmware, @snapshot_firmware_keys) and valid_version?(version) and valid_git_sha?(git_sha)
  end

  defp valid_snapshot_firmware?(_firmware), do: false

  defp valid_target_firmware?(%{version: version, git_sha: git_sha} = firmware) do
    exact_keys?(firmware, @target_firmware_keys) and valid_version?(version) and valid_git_sha?(git_sha)
  end

  defp valid_target_firmware?(_firmware), do: false

  defp valid_session?(%{authenticated: authenticated, credential_epoch: credential_epoch} = session) do
    exact_keys?(session, @session_keys) and is_boolean(authenticated) and uint32?(credential_epoch)
  end

  defp valid_session?(_session), do: false

  defp valid_desired_state?(%{generation: generation, effective: effective, compatible: compatible} = desired_state) do
    exact_keys?(desired_state, @desired_state_keys) and positive_uint64?(generation) and
      is_boolean(effective) and is_boolean(compatible)
  end

  defp valid_desired_state?(_desired_state), do: false

  defp valid_process_health?(%{supervisor: supervisor, owner: owner} = process_health) do
    exact_keys?(process_health, @process_health_keys) and
      supervisor in @status_registry.process_health and owner in @status_registry.process_health
  end

  defp valid_process_health?(_process_health), do: false

  defp valid_receipts?(%{control: control, telemetry: telemetry} = receipts) do
    exact_keys?(receipts, @receipt_keys) and control in @status_registry.receipt_round_trip and
      telemetry in @status_registry.receipt_round_trip
  end

  defp valid_receipts?(_receipts), do: false

  defp valid_outbox?(%{corrupt: corrupt, critical_pressure: critical_pressure} = outbox) do
    exact_keys?(outbox, @outbox_keys) and is_boolean(corrupt) and is_boolean(critical_pressure)
  end

  defp valid_outbox?(_outbox), do: false

  defp valid_snapshot_timing?(%{observed_at_ms: observed_at_ms, soak_started_at_ms: soak_started_at_ms} = timing) do
    exact_keys?(timing, @snapshot_timing_keys) and uint64?(observed_at_ms) and
      uint64?(soak_started_at_ms) and soak_started_at_ms <= observed_at_ms
  end

  defp valid_snapshot_timing?(_timing), do: false

  defp valid_version?(version) when is_binary(version) do
    byte_size(version) > 0 and byte_size(version) <= @max_version_bytes and String.valid?(version)
  end

  defp valid_version?(_version), do: false

  defp valid_git_sha?(git_sha) when is_binary(git_sha) and byte_size(git_sha) == @git_sha_bytes do
    git_sha
    |> :binary.bin_to_list()
    |> Enum.all?(fn byte -> byte in ?0..?9 or byte in ?a..?f end)
  end

  defp valid_git_sha?(_git_sha), do: false

  defp exact_keys?(map, keys) when is_map(map) do
    map_size(map) == length(keys) and Enum.all?(keys, &Map.has_key?(map, &1))
  end

  defp exact_keys?(_map, _keys), do: false

  defp uint32?(value), do: is_integer(value) and value >= 0 and value <= @max_u32
  defp uint64?(value), do: is_integer(value) and value >= 0 and value <= @max_u64
  defp positive_uint64?(value), do: is_integer(value) and value > 0 and value <= @max_u64
end
