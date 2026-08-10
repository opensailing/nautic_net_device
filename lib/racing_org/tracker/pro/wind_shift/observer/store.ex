defmodule RacingOrg.Tracker.Pro.WindShift.Observer.Store do
  @moduledoc """
  Durable, atomic, corruption-safe persistence of the wind-shift
  `RacingOrg.Tracker.Pro.WindShift.Observer`'s SESSION state — the sailing-day
  session identity (started_at_ms + running centroid/TWS sums), the upstream
  sync sequence, and the not-yet-synced timeline rows / events — so a mid-day
  reboot keeps the SAME session and sequence instead of starting a new one.

  The main session snapshot deliberately excludes the estimation cores (means /
  envelope / Kalman cycle / step detector). A separate fixed-format sidecar
  stores only the SHA-256 fingerprint of the last accepted authoritative runtime
  snapshot, never the runtime map itself. That marker makes exact redelivery a
  durable no-op without defining another runtime-state codec.

  Mirrors `RacingOrg.Tracker.Pro.Calibration.Observer.Store`: the snapshot is
  written to a temp file and atomically renamed into place, so a crash
  mid-write can never leave a partially written file. Loading a missing,
  unreadable, corrupt, or unknown-version file returns `:empty` rather than
  raising — the Observer simply starts a fresh session.

  This is a SEPARATE file (`observer.wind_shift`) from
  `RacingOrg.Tracker.Pro.WindShift.Store`'s `current.wind_shift` (the
  server-pushed policy owned by `WindShift.Config`); both live under the same
  `:wind_shift_directory` without clashing.

  ## Persisted shape

      %{
        session: %{started_at_ms: integer(), lat_sum: float(), lon_sum: float(),
                   pos_n: non_neg_integer(), tws_sum: float(), tws_n: non_neg_integer()} | nil,
        seq: non_neg_integer(),
        pending_timeline: [map()],
        pending_events: [map()],
        last_summary: map() | nil
      }
  """

  require Logger

  @filename "observer.wind_shift"
  @authoritative_filename "observer.wind_shift.authoritative"
  @authoritative_magic "WSAF"
  @authoritative_version 1
  @fingerprint_bytes 32
  # Bump if the persisted representation changes incompatibly; older/unknown
  # versions are ignored on load (the Observer starts a fresh session).
  @format_version 1

  @doc "Atomically persist the Observer `snapshot` under `dir`. Best-effort; never raises."
  @spec save(Path.t(), map()) :: :ok | {:error, term()}
  def save(dir, %{} = snapshot) do
    File.mkdir_p!(dir)
    path = path(dir)
    tmp = path <> ".tmp"
    File.write!(tmp, :erlang.term_to_binary({@format_version, snapshot}))
    File.rename!(tmp, path)
    :ok
  rescue
    error ->
      Logger.warning("Failed to persist wind-shift observer state to #{inspect(dir)}: #{inspect(error)}")
      {:error, error}
  end

  @doc "Persist the fixed SHA-256 fingerprint of the last accepted authoritative runtime snapshot."
  @spec save_authoritative_fingerprint(Path.t(), <<_::256>>) :: :ok | {:error, term()}
  def save_authoritative_fingerprint(dir, fingerprint)
      when is_binary(fingerprint) and byte_size(fingerprint) == @fingerprint_bytes do
    File.mkdir_p!(dir)
    path = authoritative_path(dir)
    tmp = path <> ".tmp"
    File.write!(tmp, <<@authoritative_magic, @authoritative_version, fingerprint::binary>>)
    File.rename!(tmp, path)
    :ok
  rescue
    error ->
      Logger.warning("Failed to persist wind-shift authoritative fingerprint to #{inspect(dir)}: #{inspect(error)}")
      {:error, error}
  end

  @doc "Load the last accepted authoritative runtime fingerprint, or `:empty`."
  @spec load_authoritative_fingerprint(Path.t()) :: {:ok, <<_::256>>} | :empty
  def load_authoritative_fingerprint(dir) do
    case File.read(authoritative_path(dir)) do
      {:ok, binary} -> decode_authoritative_fingerprint(binary, dir)
      {:error, :enoent} -> :empty
      {:error, reason} -> warn_empty(dir, "could not read authoritative fingerprint", reason)
    end
  end

  @doc "Load the persisted snapshot from `dir`, or `:empty` if absent/unusable."
  @spec load(Path.t()) :: {:ok, map()} | :empty
  def load(dir) do
    case File.read(path(dir)) do
      {:ok, binary} -> decode(binary, dir)
      {:error, :enoent} -> :empty
      {:error, reason} -> warn_empty(dir, "could not read", reason)
    end
  end

  @doc "Remove any persisted snapshot under `dir`."
  @spec clear(Path.t()) :: :ok
  def clear(dir) do
    _ = File.rm(path(dir))
    _ = File.rm(authoritative_path(dir))
    :ok
  end

  defp decode(binary, dir) do
    case safe_binary_to_term(binary) do
      {@format_version, %{} = snapshot} -> {:ok, snapshot}
      _other -> warn_empty(dir, "unrecognized/incompatible", :format)
    end
  rescue
    error -> warn_empty(dir, "corrupt", error)
  end

  defp decode_authoritative_fingerprint(
         <<@authoritative_magic, @authoritative_version, fingerprint::binary-size(@fingerprint_bytes)>>,
         _dir
       ),
       do: {:ok, fingerprint}

  defp decode_authoritative_fingerprint(_binary, dir),
    do: warn_empty(dir, "unrecognized/incompatible authoritative fingerprint", :format)

  defp safe_binary_to_term(binary), do: :erlang.binary_to_term(binary, [:safe])

  defp warn_empty(dir, what, detail) do
    Logger.warning("Ignoring #{what} persisted wind-shift observer state in #{inspect(dir)}: #{inspect(detail)}")
    :empty
  end

  defp path(dir), do: Path.join(dir, @filename)
  defp authoritative_path(dir), do: Path.join(dir, @authoritative_filename)
end
