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
end
