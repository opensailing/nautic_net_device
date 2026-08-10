defmodule RacingOrg.Tracker.Pro.Calibration.Observer.Store do
  @moduledoc """
  Atomic local durability for the calibration Observer's portable learner state.

  Format 3 stores one closed canonical learner envelope: a UTC capture anchor,
  canonical `Calibration.Checkpoint` content, an AWS relative-time sidecar, and
  the optional bounded capture coordinate and digest of the last accepted runtime
  restore. Process-local monotonic timestamps are never persisted directly.

  Format 2 is read only for safe migration. Its non-AWS learner state is offered
  to the Observer for validation, while AWS estimators are discarded because
  their absolute BEAM-monotonic regime timestamps cannot be rebased after a VM
  restart. Missing, corrupt, oversized, or unknown data produces `:empty`.
  """

  require Logger

  alias RacingOrg.Tracker.Pro.RuntimeSnapshot

  @filename "observer.calibration"
  @format_version 3
  @max_bytes 8_388_608
  @envelope_fields [
    :captured_at_utc_ms,
    :last_restore_captured_at_utc_ms,
    :last_restore_digest,
    :learner,
    :learner_time_basis
  ]
  @legacy_fields [:awa_estimators, :stw_estimators, :aws_estimators, :prev_applied, :seq]

  @doc "Atomically persist one closed format-3 Observer envelope."
  @spec save(Path.t(), map()) :: :ok | {:error, term()}
  def save(dir, %{} = envelope) do
    with :ok <- stage(dir, envelope) do
      case commit(dir) do
        :ok ->
          :ok

        {:error, _reason} = error ->
          _ = discard(dir)
          error
      end
    end
  end

  def save(_dir, _envelope), do: {:error, :invalid_envelope}

  @doc false
  @spec stage(Path.t(), map()) :: :ok | {:error, term()}
  def stage(dir, %{} = envelope) do
    with :ok <- validate_envelope(envelope),
         :ok <- File.mkdir_p(dir),
         {:ok, binary} <- encode(envelope),
         :ok <- File.write(temp_path(dir), binary) do
      :ok
    else
      {:error, reason} = error ->
        Logger.warning("Failed to stage calibration observer state to #{inspect(dir)}: #{inspect(reason)}")
        error
    end
  rescue
    error ->
      Logger.warning("Failed to stage calibration observer state to #{inspect(dir)}: #{inspect(error)}")
      {:error, error}
  end

  def stage(_dir, _envelope), do: {:error, :invalid_envelope}

  @doc false
  @spec commit(Path.t()) :: :ok | {:error, term()}
  def commit(dir) do
    case File.rename(temp_path(dir), path(dir)) do
      :ok ->
        :ok

      {:error, reason} = error ->
        Logger.warning("Failed to commit calibration observer state in #{inspect(dir)}: #{inspect(reason)}")
        error
    end
  end

  @doc false
  @spec discard(Path.t()) :: :ok | {:error, term()}
  def discard(dir), do: remove_file(temp_path(dir))

  @doc false
  @spec pending?(Path.t()) :: boolean()
  def pending?(dir), do: File.regular?(temp_path(dir))

  @doc "Load a closed format-3 envelope, a safe format-2 migration, or `:empty`."
  @spec load(Path.t()) :: {:ok, map()} | :empty
  def load(dir) do
    file = path(dir)

    case File.stat(file) do
      {:ok, %{size: size}} when size <= @max_bytes ->
        case File.read(file) do
          {:ok, binary} when byte_size(binary) <= @max_bytes -> decode(binary, dir)
          {:ok, _oversized} -> warn_empty(dir, "oversized", :format)
          {:error, reason} -> warn_empty(dir, "could not read", reason)
        end

      {:ok, _oversized} ->
        warn_empty(dir, "oversized", :format)

      {:error, :enoent} ->
        :empty

      {:error, reason} ->
        warn_empty(dir, "could not stat", reason)
    end
  end

  @doc "Remove any persisted snapshot under `dir`."
  @spec clear(Path.t()) :: :ok | {:error, term()}
  def clear(dir) do
    with :ok <- remove_file(path(dir)),
         :ok <- remove_file(temp_path(dir)) do
      :ok
    end
  end

  defp decode(binary, dir) do
    case safe_binary_to_term(binary) do
      {@format_version, %{} = envelope} ->
        if validate_envelope(envelope) == :ok,
          do: {:ok, envelope},
          else: warn_empty(dir, "invalid", :format)

      {2, %{} = legacy} ->
        case migrate_legacy(legacy) do
          {:ok, migrated} -> {:ok, %{legacy_learner: migrated}}
          :error -> warn_empty(dir, "invalid legacy", :format)
        end

      _other ->
        warn_empty(dir, "unrecognized/incompatible", :format)
    end
  rescue
    error -> warn_empty(dir, "corrupt", error)
  end

  defp validate_envelope(envelope) do
    with :ok <- RuntimeSnapshot.exact_keys(envelope, @envelope_fields),
         {:ok, _utc_ms} <- RuntimeSnapshot.utc_ms(envelope.captured_at_utc_ms),
         true <- valid_optional_utc_ms?(envelope.last_restore_captured_at_utc_ms),
         true <- is_map(envelope.learner) and not is_struct(envelope.learner),
         true <- is_list(envelope.learner_time_basis),
         true <- is_nil(envelope.last_restore_digest) or valid_digest?(envelope.last_restore_digest) do
      :ok
    else
      _ -> {:error, :invalid_envelope}
    end
  end

  defp valid_digest?(digest), do: is_binary(digest) and byte_size(digest) == 32
  defp valid_optional_utc_ms?(nil), do: true
  defp valid_optional_utc_ms?(value), do: match?({:ok, _utc_ms}, RuntimeSnapshot.utc_ms(value))

  defp migrate_legacy(legacy) do
    with :ok <- RuntimeSnapshot.exact_keys(legacy, @legacy_fields),
         true <- is_map(legacy.awa_estimators) and not is_struct(legacy.awa_estimators),
         true <- is_map(legacy.stw_estimators) and not is_struct(legacy.stw_estimators),
         true <- is_map(legacy.aws_estimators) and not is_struct(legacy.aws_estimators),
         true <- is_map(legacy.prev_applied) and not is_struct(legacy.prev_applied),
         true <- is_integer(legacy.seq) and legacy.seq >= 0 do
      {:ok, %{legacy | aws_estimators: %{}}}
    else
      _ -> :error
    end
  end

  defp encode(envelope) do
    binary = :erlang.term_to_binary({@format_version, envelope})
    if byte_size(binary) <= @max_bytes, do: {:ok, binary}, else: {:error, :snapshot_too_large}
  end

  defp safe_binary_to_term(binary), do: :erlang.binary_to_term(binary, [:safe])

  defp remove_file(file) do
    case File.rm(file) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp warn_empty(dir, what, detail) do
    Logger.warning("Ignoring #{what} persisted calibration observer state in #{inspect(dir)}: #{inspect(detail)}")

    :empty
  end

  defp path(dir), do: Path.join(dir, @filename)
  defp temp_path(dir), do: path(dir) <> ".tmp"
end
