defmodule RacingOrg.Tracker.Pro.Calibration.Detect.Leg do
  @moduledoc """
  A completed steady sailing leg, summarized as aggregates.

  Emitted by `RacingOrg.Tracker.Pro.Calibration.Detect.Legs` when a steady
  segment ends and is long enough to count. Downstream calibration estimators
  consume legs (and leg *pairs*) instead of raw samples, so a leg carries only
  scalar summaries — never the samples themselves.

  Angle conventions: `heading_mean`/`cog_mean` are circular means in
  `[0, 360)`; `heading_sd` is the circular standard deviation.
  `awa_mean_signed` keeps the signed apparent wind angle (starboard positive,
  `±180`), while `awa_abs_mean` is the mean of `|awa|` — the two differ when
  the AWA jitters around a mean, and estimators need both. `side` is derived
  from the sign of `awa_mean_signed`.

  Fields sourced from optional channels (`cog_mean`, `sog_mean`, `tws_mean`,
  `tws_sd`, `heel_mean`) are `nil` when the channel was absent for the whole
  leg.
  """

  alias RacingOrg.Tracker.Pro.RuntimeSnapshot

  @enforce_keys [:started_ms, :ended_ms, :duration_s, :samples, :side]
  defstruct [
    :started_ms,
    :ended_ms,
    :duration_s,
    :samples,
    :side,
    :heading_mean,
    :heading_sd,
    :cog_mean,
    :sog_mean,
    :stw_mean,
    :stw_sd,
    :awa_mean_signed,
    :awa_abs_mean,
    :aws_mean,
    :tws_mean,
    :tws_sd,
    :heel_mean
  ]

  @type side :: :starboard | :port

  @type t :: %__MODULE__{
          started_ms: integer(),
          ended_ms: integer(),
          duration_s: float(),
          samples: pos_integer(),
          side: side(),
          heading_mean: float() | nil,
          heading_sd: float(),
          cog_mean: float() | nil,
          sog_mean: float() | nil,
          stw_mean: float(),
          stw_sd: float(),
          awa_mean_signed: float(),
          awa_abs_mean: float(),
          aws_mean: float(),
          tws_mean: float() | nil,
          tws_sd: float() | nil,
          heel_mean: float() | nil
        }

  @snapshot_fields ~w(
    awa_abs_mean awa_mean_signed aws_mean cog_mean ended_age_ms heading_mean
    heading_sd heel_mean samples sog_mean started_age_ms stw_mean stw_sd
    tws_mean tws_sd
  )a
  @max_speed_mps 655.32
  @max_tws_mps 1_310.64
  @max_heel_deg 188.0
  @snapshot_error {:error, :invalid_leg_snapshot}

  @typedoc """
  Closed runtime representation of a completed leg.

  Monotonic timestamps are ages relative to the observer's capture clock, never
  absolute BEAM monotonic values. They are bounded and rebased by `restore/3`;
  no source metadata or arbitrary extension keys are accepted.
  """
  @type snapshot :: %{
          required(:started_age_ms) => non_neg_integer(),
          required(:ended_age_ms) => non_neg_integer(),
          required(:samples) => pos_integer(),
          required(:heading_mean) => float() | nil,
          required(:heading_sd) => float(),
          required(:cog_mean) => float() | nil,
          required(:sog_mean) => float() | nil,
          required(:stw_mean) => float(),
          required(:stw_sd) => float(),
          required(:awa_mean_signed) => float(),
          required(:awa_abs_mean) => float(),
          required(:aws_mean) => float(),
          required(:tws_mean) => float() | nil,
          required(:tws_sd) => float() | nil,
          required(:heel_mean) => float() | nil
        }

  @doc """
  Project a completed leg into its closed runtime snapshot.

  `captured_at_ms` must come from the same monotonic clock as the leg. Future or
  unbounded timestamps fail closed.
  """
  @spec snapshot(t(), integer()) :: {:ok, snapshot()} | {:error, :invalid_leg_snapshot}
  def snapshot(%__MODULE__{} = leg, captured_at_ms) when is_integer(captured_at_ms) do
    with {:ok, started_age_ms} <- RuntimeSnapshot.timestamp_age(leg.started_ms, captured_at_ms),
         {:ok, ended_age_ms} <- RuntimeSnapshot.timestamp_age(leg.ended_ms, captured_at_ms) do
      snapshot = %{
        started_age_ms: started_age_ms,
        ended_age_ms: ended_age_ms,
        samples: leg.samples,
        heading_mean: leg.heading_mean,
        heading_sd: leg.heading_sd,
        cog_mean: leg.cog_mean,
        sog_mean: leg.sog_mean,
        stw_mean: leg.stw_mean,
        stw_sd: leg.stw_sd,
        awa_mean_signed: leg.awa_mean_signed,
        awa_abs_mean: leg.awa_abs_mean,
        aws_mean: leg.aws_mean,
        tws_mean: leg.tws_mean,
        tws_sd: leg.tws_sd,
        heel_mean: leg.heel_mean
      }

      case validate_snapshot(snapshot) do
        :ok -> {:ok, snapshot}
        :error -> @snapshot_error
      end
    else
      _ -> @snapshot_error
    end
  rescue
    _ -> @snapshot_error
  end

  def snapshot(_leg, _captured_at_ms), do: @snapshot_error

  @doc """
  Rehydrate a validated leg snapshot against `restored_at_ms`.

  `elapsed_ms` is powered-off/delivery wall time since capture. It is added to
  both timestamp ages before rebasing so old legs cannot appear adjacent to new
  sailing. Validation completes before a `%Leg{}` is constructed.
  """
  @spec restore(snapshot(), integer(), non_neg_integer()) ::
          {:ok, t()} | {:error, :invalid_leg_snapshot}
  def restore(snapshot, restored_at_ms, elapsed_ms \\ 0)

  def restore(snapshot, restored_at_ms, elapsed_ms)
      when is_map(snapshot) and is_integer(restored_at_ms) and is_integer(elapsed_ms) do
    with :ok <- validate_snapshot(snapshot),
         {:ok, started_ms} <-
           RuntimeSnapshot.restore_timestamp(snapshot.started_age_ms, restored_at_ms, elapsed_ms),
         {:ok, ended_ms} <-
           RuntimeSnapshot.restore_timestamp(snapshot.ended_age_ms, restored_at_ms, elapsed_ms) do
      {:ok,
       %__MODULE__{
         started_ms: started_ms,
         ended_ms: ended_ms,
         duration_s: (snapshot.started_age_ms - snapshot.ended_age_ms) / 1000,
         samples: snapshot.samples,
         side: if(snapshot.awa_mean_signed >= 0.0, do: :starboard, else: :port),
         heading_mean: snapshot.heading_mean,
         heading_sd: snapshot.heading_sd,
         cog_mean: snapshot.cog_mean,
         sog_mean: snapshot.sog_mean,
         stw_mean: snapshot.stw_mean,
         stw_sd: snapshot.stw_sd,
         awa_mean_signed: snapshot.awa_mean_signed,
         awa_abs_mean: snapshot.awa_abs_mean,
         aws_mean: snapshot.aws_mean,
         tws_mean: snapshot.tws_mean,
         tws_sd: snapshot.tws_sd,
         heel_mean: snapshot.heel_mean
       }}
    else
      _ -> @snapshot_error
    end
  rescue
    _ -> @snapshot_error
  end

  def restore(_snapshot, _restored_at_ms, _elapsed_ms), do: @snapshot_error

  defp validate_snapshot(snapshot) do
    with :ok <- RuntimeSnapshot.exact_keys(snapshot, @snapshot_fields),
         {:ok, _started_age_ms} <- RuntimeSnapshot.validate_age(snapshot.started_age_ms),
         {:ok, _ended_age_ms} <- RuntimeSnapshot.validate_age(snapshot.ended_age_ms),
         true <- snapshot.started_age_ms > snapshot.ended_age_ms,
         elapsed_ms = snapshot.started_age_ms - snapshot.ended_age_ms,
         true <- is_integer(snapshot.samples) and snapshot.samples >= 2,
         true <- snapshot.samples <= elapsed_ms + 1,
         true <- angle?(snapshot.heading_mean),
         true <- RuntimeSnapshot.finite_between?(snapshot.heading_sd, 0.0, 180.0),
         true <- optional_angle?(snapshot.cog_mean),
         true <- optional_speed?(snapshot.sog_mean),
         true <- is_nil(snapshot.cog_mean) == is_nil(snapshot.sog_mean),
         true <- speed?(snapshot.stw_mean),
         true <- RuntimeSnapshot.finite_between?(snapshot.stw_sd, 0.0, @max_speed_mps),
         true <- RuntimeSnapshot.finite_between?(snapshot.awa_mean_signed, -180.0, 180.0),
         true <- RuntimeSnapshot.finite_between?(snapshot.awa_abs_mean, 0.0, 180.0),
         true <- abs(snapshot.awa_mean_signed) <= snapshot.awa_abs_mean,
         true <- speed?(snapshot.aws_mean),
         true <- optional_tws?(snapshot.tws_mean),
         true <- RuntimeSnapshot.finite_between_or_nil?(snapshot.tws_sd, 0.0, @max_tws_mps),
         true <- is_nil(snapshot.tws_mean) == is_nil(snapshot.tws_sd),
         true <- RuntimeSnapshot.finite_between_or_nil?(snapshot.heel_mean, -@max_heel_deg, @max_heel_deg) do
      :ok
    else
      _ -> :error
    end
  end

  defp angle?(value), do: RuntimeSnapshot.finite_between?(value, 0.0, 359.999_999_999)
  defp optional_angle?(nil), do: true
  defp optional_angle?(value), do: angle?(value)
  defp speed?(value), do: RuntimeSnapshot.finite_between?(value, 0.0, @max_speed_mps)
  defp optional_speed?(nil), do: true
  defp optional_speed?(value), do: speed?(value)
  defp optional_tws?(nil), do: true
  defp optional_tws?(value), do: RuntimeSnapshot.finite_between?(value, 0.0, @max_tws_mps)
end
