defmodule RacingOrg.Tracker.Pro.Polar.Observer.Gate do
  @moduledoc """
  Steady-state admission filter for the observational ("sailed") polar.

  A logged boat-speed sample only belongs in the sailed polar if the boat was
  **sailing in quasi-steady state** when it was taken — settled on a stable point
  of sail, in steady wind, not maneuvering, not accelerating, and not under
  engine. Admitting transient data (mid-tack, in a puff, accelerating off a wave)
  would bias the per-cell speed percentile high or low. This module is the pure
  decision function that gates each sample.

  It is fed the recent **rolling window** of samples (most-recent LAST); the
  CURRENT sample is the last element. `evaluate/2` returns `:admit` or
  `{:reject, reason}` so the caller can both update the cell and log *why* a
  sample was dropped.

  ## Sample shape

  Each window element is a map with (SI units; angles in degrees):

    * `:t_ms` — monotonic timestamp, milliseconds (for rates).
    * `:tws_mps` — true wind speed (m/s).
    * `:twa_deg` — true wind angle (the angle used by the no-go band, unless
      `:angle_key` selects `:awa_deg`).
    * `:stw_mps` — speed through water (m/s).
    * `:heading_deg` — heading (deg, 0–360; wrap-aware turn rate).
    * `:heel_deg` — heel angle (deg, signed).
    * `:under_power?` (optional, boolean) and/or `:engine_rpm` (optional, number)
      — motoring signals; see "Motoring exclusion" below.

  ## Filters and defaults (with justification)

    * **No-go / maneuver band** (`:angle_band_deg`, default `{25.0, 165.0}`):
      admit only when the (folded, absolute) wind angle is in `[25°, 165°]`.
      Below ~25° the boat is in irons / the no-go zone; above ~165° it is
      dead-downwind where the main blankets the jib and STW is unrepresentative.
      This is the conventional "valid sailing" angle band.

    * **Steady wind** (`:max_tws_sd_mps`, default `0.2572` = 0.5 kn): reject when
      the standard deviation of TWS across the window exceeds the threshold. Half
      a knot is the usual "puff/lull" threshold — beyond it the wind is not
      steady enough to call a single operating point.

    * **Low rate of turn** (`:max_turn_rate_dps`, default `3.0` °/s): reject when
      the wrap-aware heading change rate over the window exceeds a few °/s. A
      tack or gybe slews the heading at ~10–30°/s, so 3°/s excludes maneuvers
      while still allowing gentle steering corrections.

    * **No acceleration** (`:max_accel_mps2`, default `0.05` m/s²): reject when
      `|dSTW/dt|` over the window exceeds the threshold — the quasi-steady
      requirement. The boat must be settled at a stable speed, not still building
      or bleeding speed.

    * **Heel band** (`:heel_band_deg`, default `{-45.0, 45.0}`): reject heel
      outside a wide, sane band. Expected heel varies a lot by boat and breeze,
      so the default is deliberately permissive (it mainly catches a knockdown /
      bad-sensor reading), and is meant to be tightened per boat.

    * **Minimum dwell** (`:min_dwell`, default `10`): require at least `N`
      samples in the window AND that **every** sample in it independently passes
      the per-sample gates (angle / heel / motoring). At ~1 Hz logging, 10
      samples is ~10 s of continuously settled sailing before THIS sample counts.

  ## Motoring exclusion (optional)

  If a motoring signal is present it excludes the sample: `:under_power? == true`,
  or `:engine_rpm` above `:engine_rpm_idle` (default `50.0`). When **no** motoring
  signal is present at all, the gate CANNOT detect motoring and must not reject on
  that basis — motoring contamination is then mitigated only by the other gates
  (steady wind, no turn, no accel, on-angle) plus using STW-based wind downstream.
  This is the expected path for devices without an engine-RPM / under-power feed.

  ## Reject precedence

  `evaluate/2` checks dwell first (an empty/short window can't be steady), then
  the window-wide rate filters (wind sd, turn rate, accel), then the current
  sample's per-sample gates. The first failing check's reason is returned:
  `:insufficient_dwell | :unsteady_wind | :turning | :accelerating |
  :no_go_angle | :heel_out_of_band | :motoring`.
  """

  @default_angle_band {25.0, 165.0}
  @default_heel_band {-45.0, 45.0}
  # 0.5 knot in m/s.
  @default_max_tws_sd_mps 0.2572
  @default_max_turn_rate_dps 3.0
  @default_max_accel_mps2 0.05
  @default_min_dwell 10
  @default_engine_rpm_idle 50.0

  @enforce_keys []
  defstruct angle_band_deg: @default_angle_band,
            heel_band_deg: @default_heel_band,
            max_tws_sd_mps: @default_max_tws_sd_mps,
            max_turn_rate_dps: @default_max_turn_rate_dps,
            max_accel_mps2: @default_max_accel_mps2,
            min_dwell: @default_min_dwell,
            engine_rpm_idle: @default_engine_rpm_idle,
            angle_key: :twa_deg

  @type sample :: %{optional(atom()) => term()}
  @type reason ::
          :insufficient_dwell
          | :unsteady_wind
          | :turning
          | :accelerating
          | :no_go_angle
          | :heel_out_of_band
          | :motoring
  @type decision :: :admit | {:reject, reason()}

  @type t :: %__MODULE__{
          angle_band_deg: {float(), float()},
          heel_band_deg: {float(), float()},
          max_tws_sd_mps: float(),
          max_turn_rate_dps: float(),
          max_accel_mps2: float(),
          min_dwell: pos_integer(),
          engine_rpm_idle: float(),
          angle_key: atom()
        }

  @doc """
  Build a gate config. See the module doc for every option and its default.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      angle_band_deg: Keyword.get(opts, :angle_band_deg, @default_angle_band),
      heel_band_deg: Keyword.get(opts, :heel_band_deg, @default_heel_band),
      max_tws_sd_mps: Keyword.get(opts, :max_tws_sd_mps, @default_max_tws_sd_mps),
      max_turn_rate_dps: Keyword.get(opts, :max_turn_rate_dps, @default_max_turn_rate_dps),
      max_accel_mps2: Keyword.get(opts, :max_accel_mps2, @default_max_accel_mps2),
      min_dwell: Keyword.get(opts, :min_dwell, @default_min_dwell),
      engine_rpm_idle: Keyword.get(opts, :engine_rpm_idle, @default_engine_rpm_idle),
      angle_key: Keyword.get(opts, :angle_key, :twa_deg)
    }
  end

  @doc """
  Decide whether the CURRENT (last) sample in `window` qualifies to update a
  cell. `window` is most-recent-last. Returns `:admit` or `{:reject, reason}`.
  """
  @spec evaluate(t(), [sample()]) :: decision()
  def evaluate(%__MODULE__{} = g, window) when is_list(window) do
    with :ok <- check_dwell(g, window),
         :ok <- check_wind_steadiness(g, window),
         :ok <- check_turn_rate(g, window),
         :ok <- check_acceleration(g, window),
         :ok <- check_window_per_sample(g, window) do
      :admit
    else
      {:reject, _} = rejection -> rejection
    end
  end

  # =====================================================================
  # Window-level checks
  # =====================================================================

  defp check_dwell(%__MODULE__{min_dwell: n}, window) do
    if length(window) >= n, do: :ok, else: {:reject, :insufficient_dwell}
  end

  defp check_wind_steadiness(%__MODULE__{max_tws_sd_mps: max_sd}, window) do
    sd = stddev(for s <- window, is_number(s[:tws_mps]), do: s[:tws_mps] + 0.0)

    if sd <= max_sd, do: :ok, else: {:reject, :unsteady_wind}
  end

  # Peak wrap-aware heading rate between consecutive samples in the window.
  defp check_turn_rate(%__MODULE__{max_turn_rate_dps: max_rate}, window) do
    if peak_rate(window, :heading_deg, &wrapped_delta/2) <= max_rate do
      :ok
    else
      {:reject, :turning}
    end
  end

  # Peak |dSTW/dt| between consecutive samples.
  defp check_acceleration(%__MODULE__{max_accel_mps2: max_accel}, window) do
    if peak_rate(window, :stw_mps, fn a, b -> b - a end) <= max_accel do
      :ok
    else
      {:reject, :accelerating}
    end
  end

  # Every sample in the window must independently pass the per-sample gates, so
  # the dwell is N consecutive GOOD samples (not just N samples present).
  defp check_window_per_sample(g, window) do
    Enum.reduce_while(window, :ok, fn s, _acc ->
      case per_sample(g, s) do
        :ok -> {:cont, :ok}
        {:reject, _} = rejection -> {:halt, rejection}
      end
    end)
  end

  # =====================================================================
  # Per-sample checks (angle band, heel band, motoring)
  # =====================================================================

  defp per_sample(g, sample) do
    with :ok <- check_motoring(g, sample),
         :ok <- check_angle(g, sample) do
      check_heel(g, sample)
    end
  end

  defp check_motoring(%__MODULE__{engine_rpm_idle: idle}, sample) do
    cond do
      Map.get(sample, :under_power?) == true -> {:reject, :motoring}
      is_number(sample[:engine_rpm]) and sample[:engine_rpm] > idle -> {:reject, :motoring}
      # No motoring signal (or explicitly not motoring) -> can't reject here.
      true -> :ok
    end
  end

  defp check_angle(%__MODULE__{angle_band_deg: {lo, hi}, angle_key: key}, sample) do
    angle = fold_abs(sample[key])

    if is_number(angle) and angle >= lo and angle <= hi do
      :ok
    else
      {:reject, :no_go_angle}
    end
  end

  defp check_heel(%__MODULE__{heel_band_deg: {lo, hi}}, sample) do
    heel = sample[:heel_deg]

    if is_number(heel) and heel >= lo and heel <= hi do
      :ok
    else
      {:reject, :heel_out_of_band}
    end
  end

  # =====================================================================
  # Math helpers
  # =====================================================================

  # Population standard deviation; 0.0 for <2 points (nothing to disagree on).
  defp stddev(values) when length(values) < 2, do: 0.0

  defp stddev(values) do
    n = length(values)
    mean = Enum.sum(values) / n
    var = Enum.reduce(values, 0.0, fn v, acc -> acc + (v - mean) * (v - mean) end) / n
    :math.sqrt(var)
  end

  # Peak absolute (delta_fn value)/dt over consecutive samples, in units/second.
  # 0.0 for <2 samples (no rate definable) or when timestamps don't advance.
  defp peak_rate(window, key, delta_fn) do
    window
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.reduce(0.0, fn [a, b], peak ->
      va = a[key]
      vb = b[key]
      dt = ((b[:t_ms] || 0) - (a[:t_ms] || 0)) / 1000.0

      if is_number(va) and is_number(vb) and dt > 0.0 do
        max(peak, abs(delta_fn.(va + 0.0, vb + 0.0)) / dt)
      else
        peak
      end
    end)
  end

  # Smallest signed angular difference b-a, wrapped to (-180, 180].
  defp wrapped_delta(a, b) do
    d = :math.fmod(b - a + 180.0, 360.0)
    d = if d < 0.0, do: d + 360.0, else: d
    d - 180.0
  end

  # Fold a wind angle to absolute [0,180]; nil/non-number passes through as nil.
  defp fold_abs(a) when is_number(a) do
    w = :math.fmod(a + 0.0, 360.0)
    w = if w < 0.0, do: w + 360.0, else: w
    if w > 180.0, do: 360.0 - w, else: w
  end

  defp fold_abs(_), do: nil
end
