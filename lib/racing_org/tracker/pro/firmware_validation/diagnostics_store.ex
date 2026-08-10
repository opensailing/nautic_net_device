defmodule RacingOrg.Tracker.Pro.FirmwareValidation.DiagnosticsStore do
  @moduledoc """
  Crash-safe storage for the closed OTA trial diagnostic record.

  The persisted term contains only a static trial phase, an exact sanitized
  `HealthCriteria` result, relative timing budgets, and validated target
  identity. Snapshots, PIDs, session identifiers, cryptographic keys, receipt
  payloads, outbox entries, and arbitrary metadata are rejected before bytes are
  written.
  """

  alias RacingOrg.Tracker.Pro.DesiredState.AtomicFile
  alias RacingOrg.Tracker.Pro.FirmwareValidation.HealthCriteria
  alias RacingOrg.Tracker.Pro.SecureTransport.KeyStore.FileSystem

  @filename "trial.diagnostics"
  @format_version 1
  @max_u32 0xFFFF_FFFF
  @max_generation 0x7FFF_FFFF_FFFF_FFFF
  @max_u64 0xFFFF_FFFF_FFFF_FFFF
  @max_version_bytes 128
  @git_sha_bytes 40
  @phases [:monitoring, :validation_decided, :validated, :rollback_decided, :reboot_pending]
  @record_keys [:phase, :result, :timing, :target]
  @timing_keys [:remaining_deadline_ms, :healthy_for_ms]
  @target_keys [:firmware, :credential_epoch, :desired_generation, :soak_period_ms]
  @firmware_keys [:version, :git_sha]
  @unmet_keys [:criterion, :diagnostic_code]

  @criterion_codes %{
    firmware_version: [:firmware_version_mismatch],
    firmware_git_sha: [:firmware_git_sha_mismatch],
    session_authentication: [:session_not_authenticated],
    credential_epoch: [:credential_epoch_mismatch],
    desired_generation: [:desired_generation_mismatch],
    desired_generation_effective: [:desired_generation_not_effective],
    desired_generation_compatibility: [:desired_generation_incompatible],
    supervisor_health: [:supervisor_unhealthy],
    owner_health: [:owner_unhealthy],
    control_receipt_round_trip: [:control_receipt_incomplete],
    telemetry_receipt_round_trip: [:telemetry_receipt_incomplete],
    outbox_integrity: [:outbox_corrupt],
    outbox_pressure: [:outbox_critical_pressure],
    soak_period: [:soak_period_incomplete],
    input: [:invalid_snapshot, :invalid_target]
  }

  @type phase :: :monitoring | :validation_decided | :validated | :rollback_decided | :reboot_pending
  @type target_identity :: %{
          firmware: %{version: binary(), git_sha: binary()},
          credential_epoch: non_neg_integer(),
          desired_generation: pos_integer(),
          soak_period_ms: pos_integer()
        }
  @type timing :: %{remaining_deadline_ms: non_neg_integer(), healthy_for_ms: non_neg_integer()}
  @type record :: %{
          phase: phase(),
          result: HealthCriteria.result(),
          timing: timing(),
          target: target_identity()
        }

  @doc "Atomically persists an exact sanitized trial record."
  @spec save(Path.t(), term(), keyword()) :: :ok | {:error, term()}
  def save(dir, record, opts \\ []) do
    with {:ok, record} <- validate_record(record),
         {:ok, contents} <- encode(record) do
      write_authoritative(dir, contents, opts)
    end
  rescue
    _exception -> {:error, :invalid_record}
  catch
    _kind, _reason -> {:error, :invalid_record}
  end

  @doc "Strictly loads the durable record, preserving absence, corruption, format, and I/O outcomes."
  @spec load(Path.t(), keyword()) :: {:ok, record()} | :empty | {:error, term()}
  def load(dir, opts \\ []) do
    case file_system(opts).read(path(dir)) do
      {:ok, binary} -> decode(binary)
      {:error, :enoent} -> :empty
      {:error, reason} -> {:error, {:read, reason}}
      _other -> {:error, :corrupt}
    end
  rescue
    _exception -> {:error, :corrupt}
  catch
    _kind, _reason -> {:error, :corrupt}
  end

  @doc "Durably removes the current trial record."
  @spec clear(Path.t(), keyword()) :: :ok | {:error, term()}
  def clear(dir, opts \\ []) do
    AtomicFile.remove(path(dir), atomic_opts(dir, opts))
  end

  @doc false
  @spec path(Path.t()) :: Path.t()
  def path(dir), do: Path.join(dir, @filename)

  defp write_authoritative(dir, contents, opts) do
    AtomicFile.write(path(dir), contents, atomic_opts(dir, opts))
  end

  defp encode(record) do
    {:ok, :erlang.term_to_binary({@format_version, record})}
  rescue
    _exception -> {:error, :invalid_record}
  catch
    _kind, _reason -> {:error, :invalid_record}
  end

  defp decode(binary) do
    case :erlang.binary_to_term(binary, [:safe]) do
      {@format_version, record} -> validate_record(record)
      {_other_version, _record} -> {:error, :unrecognized_format}
      _other -> {:error, :corrupt}
    end
  rescue
    _exception -> {:error, :corrupt}
  catch
    _kind, _reason -> {:error, :corrupt}
  end

  defp validate_record(record) when is_map(record) do
    with true <- exact_keys?(record, @record_keys),
         {:ok, phase} <- validate_phase(record.phase),
         {:ok, result} <- validate_result(record.result),
         true <- phase_matches_result?(phase, result),
         {:ok, timing} <- validate_timing(record.timing),
         {:ok, target} <- validate_target(record.target) do
      {:ok, %{phase: phase, result: result, timing: timing, target: target}}
    else
      _other -> {:error, :invalid_record}
    end
  end

  defp validate_record(_record), do: {:error, :invalid_record}

  defp validate_phase(phase) when phase in @phases, do: {:ok, phase}
  defp validate_phase(_phase), do: :error

  defp validate_result(:ready), do: {:ok, :ready}

  defp validate_result({status, unmet}) when status in [:pending, :rollback_required] and is_list(unmet) do
    with true <- unmet != [],
         true <- length(unmet) <= length(HealthCriteria.criteria()),
         {:ok, canonical} <- validate_unmet(unmet),
         true <- criteria_ordered_and_unique?(canonical) do
      {:ok, {status, canonical}}
    else
      _other -> :error
    end
  end

  defp validate_result(_result), do: :error

  defp validate_unmet(unmet) do
    Enum.reduce_while(unmet, {:ok, []}, fn item, {:ok, acc} ->
      case validate_unmet_item(item) do
        {:ok, canonical} -> {:cont, {:ok, [canonical | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      :error -> :error
    end
  end

  defp validate_unmet_item(item) when is_map(item) do
    with true <- exact_keys?(item, @unmet_keys),
         criterion when is_atom(criterion) <- item.criterion,
         diagnostic_code when is_atom(diagnostic_code) <- item.diagnostic_code,
         codes when is_list(codes) <- Map.get(@criterion_codes, criterion),
         true <- diagnostic_code in codes do
      {:ok, %{criterion: criterion, diagnostic_code: diagnostic_code}}
    else
      _other -> :error
    end
  end

  defp validate_unmet_item(_item), do: :error

  defp criteria_ordered_and_unique?(unmet) do
    indexes = Enum.map(unmet, &criterion_index(&1.criterion))
    indexes == Enum.sort(indexes) and length(indexes) == MapSet.size(MapSet.new(indexes))
  end

  defp criterion_index(criterion) do
    Enum.find_index(HealthCriteria.criteria(), &(&1 == criterion))
  end

  defp phase_matches_result?(:monitoring, result), do: result == :ready or match?({:pending, _unmet}, result)
  defp phase_matches_result?(phase, :ready) when phase in [:validation_decided, :validated], do: true

  defp phase_matches_result?(phase, {:rollback_required, _unmet})
       when phase in [:rollback_decided, :reboot_pending],
       do: true

  defp phase_matches_result?(_phase, _result), do: false

  defp validate_timing(timing) when is_map(timing) do
    with true <- exact_keys?(timing, @timing_keys),
         true <- uint64?(timing.remaining_deadline_ms),
         true <- uint64?(timing.healthy_for_ms) do
      {:ok,
       %{
         remaining_deadline_ms: timing.remaining_deadline_ms,
         healthy_for_ms: timing.healthy_for_ms
       }}
    else
      _other -> :error
    end
  end

  defp validate_timing(_timing), do: :error

  defp validate_target(target) when is_map(target) do
    with true <- exact_keys?(target, @target_keys),
         {:ok, firmware} <- validate_firmware(target.firmware),
         true <- target.credential_epoch in 0..@max_u32,
         true <- target.desired_generation in 1..@max_generation,
         true <- target.soak_period_ms in 1..@max_u64 do
      {:ok,
       %{
         firmware: firmware,
         credential_epoch: target.credential_epoch,
         desired_generation: target.desired_generation,
         soak_period_ms: target.soak_period_ms
       }}
    else
      _other -> :error
    end
  end

  defp validate_target(_target), do: :error

  defp validate_firmware(firmware) when is_map(firmware) do
    with true <- exact_keys?(firmware, @firmware_keys),
         true <- valid_version?(firmware.version),
         true <- valid_git_sha?(firmware.git_sha) do
      {:ok, %{version: firmware.version, git_sha: firmware.git_sha}}
    else
      _other -> :error
    end
  end

  defp validate_firmware(_firmware), do: :error

  defp valid_version?(version) when is_binary(version) do
    byte_size(version) in 1..@max_version_bytes and String.valid?(version)
  end

  defp valid_version?(_version), do: false

  defp valid_git_sha?(git_sha) when is_binary(git_sha) and byte_size(git_sha) == @git_sha_bytes do
    String.match?(git_sha, ~r/\A[0-9a-f]{40}\z/)
  end

  defp valid_git_sha?(_git_sha), do: false

  defp uint64?(value), do: is_integer(value) and value in 0..@max_u64

  defp exact_keys?(map, keys) do
    map_size(map) == length(keys) and Enum.all?(keys, &Map.has_key?(map, &1))
  end

  defp atomic_opts(dir, opts) do
    opts
    |> Keyword.take([:file_system, :fault_injector, :temp_suffix])
    |> Keyword.put(:directory_root, dir)
  end

  defp file_system(opts), do: Keyword.get(opts, :file_system, FileSystem)
end
