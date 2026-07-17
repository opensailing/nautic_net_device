defmodule RacingOrg.Tracker.Pro.WindShift.Cycle do
  @moduledoc """
  Structural Kalman filter for TWD: local linear trend + stochastic (Harvey)
  cycle, hand-rolled 4×4.

  The wind-shift decomposition mirrors the research phenomenology: a slowly
  moving LEVEL (the day's reference direction), a TREND (sea-breeze ramps run
  5–15°/h), and a stochastic CYCLE (boundary-layer convective-roll oscillations,
  3–20 min period, ±5–20° amplitude, present when TWS ≳ 8 kn with instability).

  ## Model

  State `x = [μ, β, ψ, ψ*]` — level (deg, UNWRAPPED frame), slope (deg/MIN),
  cycle, and cycle quadrature. Observation `y = μ + ψ + ε`, `ε ~ (0, σ_ε²)`,
  where `y` is the caller-unwrapped TWD in degrees (the caller owns the wrap; the
  level is reported in the same unwrapped frame).

  Transition over a step of `dt` seconds (`ρ` and `λ` are PER-SECOND quantities,
  `ρ_dt = ρ^dt`, `λ_dt = ω·dt` with `ω = 2π/period`, so the filter is
  rate-independent):

      μ'  = μ + β·(dt/60)
      β'  = β
      ψ'  = ρ_dt·( cos λ_dt · ψ + sin λ_dt · ψ*) + κ
      ψ*' = ρ_dt·(−sin λ_dt · ψ + cos λ_dt · ψ*) + κ*

  The phase `θ = atan2(ψ*, ψ)` DECREASES at ω rad/s under this rotation and the
  cycle's contribution to the observation is `A·cos θ` with `A = √(ψ² + ψ*²)`.

  ## Process noise (fixed, documented — adaptive ML is out of scope)

  Diagonal `Q(dt) = diag(q_level·dt, q_slope·dt, q_c, q_c)` with
  `q_c = cycle_var·(1 − ρ_dt²)` — i.e. `:cycle_var` is the STATIONARY cycle
  variance (deg²), which makes the cycle noise rate-independent too. Innovations
  are monitored as a time-constant EWMA of the squared innovation
  (`snapshot/1 :innovation_var`) so the Wave-2 observer can sanity-check the
  fixed variances; the filter itself does not retune them online.

  The defaults are tuned against the scripted acceptance scenarios:

    * `q_level` 3.0e-4 deg²/s — a stiff level; slope and level are only
      separable when the level cannot wander freely (larger values push the
      trend standard error past any 5–15°/h sea-breeze signal);
    * `q_slope` 3.0e-8 (deg/min)²/s — the trend moves over tens of minutes;
    * `ρ` 0.9995/s (half-life ≈ 23 min) — convective-roll oscillations persist
      for many periods; per-second damping much heavier than this (e.g. the
      textbook per-step 0.97, half-life 23 s) makes the quadrature state
      unobservable in practice, so the filter can neither carry amplitude
      through zero crossings nor forecast the cycle. 0.97 remains available via
      `:rho_per_s`;
    * `cycle_var` 80 deg² — stationary cycle variance for a ±13° oscillation,
      the middle of the ±5–20° research band.

  ## Period adaptation

  `λ` is held FIXED inside the filter; the caller re-anchors it from the
  autocorrelation estimator (`RacingOrg.Tracker.Pro.WindShift.Period`) via
  `retune/2`.

  ## Forecast

  `forecast/2` propagates deterministically over horizon `h` seconds:

      ŷ(h)  = μ + β·(h/60) + ρ^h·(cos(ωh)·ψ + sin(ωh)·ψ*)
      var(h) = aᵀ P a + q_level·h + q_slope·h³/10800 + cycle_var·(1 − ρ^{2h})
      a      = [1, h/60, ρ^h·cos(ωh), ρ^h·sin(ωh)]
      ci_deg = 1.96·√var(h)

  i.e. filtered-state uncertainty pushed through the forecast map, plus the
  accumulated level noise (`q_level·h`), the slope noise integrated twice into
  the level (`∫₀ʰ q_slope·((h−u)/60)² du = q_slope·h³/10800`), and the cycle
  noise accumulated toward its stationary variance (`cycle_var·(1 − ρ^{2h})`).
  The CI covers the predicted TRUE direction (measurement noise excluded) and
  grows monotonically with the horizon.

  Pure data structure + functions: no processes, no IO.
  """

  @two_pi 2.0 * :math.pi()

  defstruct omega: @two_pi / 480.0,
            rho_per_s: 0.9995,
            obs_var: 2.25,
            q_level_per_s: 3.0e-4,
            q_slope_per_s: 3.0e-8,
            cycle_var: 80.0,
            innovation_tau_s: 300.0,
            x: nil,
            p: nil,
            innovation_var: nil

  @type t :: %__MODULE__{}

  @typedoc "Point-in-time view of the filter."
  @type snapshot :: %{
          level_deg: float() | nil,
          trend_deg_per_hr: float() | nil,
          trend_se_deg_per_hr: float() | nil,
          amplitude_deg: float() | nil,
          phase_rad: float() | nil,
          period_s: float(),
          innovation_var: float() | nil
        }

  @p0 [
    [400.0, 0.0, 0.0, 0.0],
    [0.0, 1.0, 0.0, 0.0],
    [0.0, 0.0, 100.0, 0.0],
    [0.0, 0.0, 0.0, 100.0]
  ]

  @doc """
  Build a fresh filter.

  Options: `:period_s` (default 480), `:rho_per_s` (0.9995), `:obs_var`
  (2.25 deg²), `:q_level_per_s` (3.0e-4 deg²/s), `:q_slope_per_s`
  (3.0e-8 (deg/min)²/s), `:cycle_var` (80 deg²), `:innovation_tau_s` (300).
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      omega: @two_pi / (Keyword.get(opts, :period_s, 480.0) / 1),
      rho_per_s: Keyword.get(opts, :rho_per_s, 0.9995) / 1,
      obs_var: Keyword.get(opts, :obs_var, 2.25) / 1,
      q_level_per_s: Keyword.get(opts, :q_level_per_s, 3.0e-4) / 1,
      q_slope_per_s: Keyword.get(opts, :q_slope_per_s, 3.0e-8) / 1,
      cycle_var: Keyword.get(opts, :cycle_var, 80.0) / 1,
      innovation_tau_s: Keyword.get(opts, :innovation_tau_s, 300.0) / 1
    }
  end

  @doc """
  Advance the filter by `dt_s` seconds and fold in the observation
  `y_unwrapped_deg` (caller-unwrapped TWD degrees). The first call initializes
  the level on the observation (`dt_s` ignored).
  """
  @spec step(t(), number(), number()) :: t()
  def step(%__MODULE__{x: nil} = cycle, y_unwrapped_deg, _dt_s) do
    %{cycle | x: [y_unwrapped_deg / 1, 0.0, 0.0, 0.0], p: @p0, innovation_var: cycle.obs_var}
  end

  def step(%__MODULE__{} = cycle, y_unwrapped_deg, dt_s) do
    dt = max(dt_s / 1, 1.0e-3)
    f = transition(cycle, dt)
    q = process_noise(cycle, dt)

    # Predict.
    x = mat_vec(f, cycle.x)
    p = mat_add(mat_mul(mat_mul(f, cycle.p), transpose(f)), q)

    # Update with H = [1, 0, 1, 0].
    [x0, _x1, x2, _x3] = x
    innovation = y_unwrapped_deg - (x0 + x2)

    hp = for j <- 0..3, do: at(p, 0, j) + at(p, 2, j)
    s = Enum.at(hp, 0) + Enum.at(hp, 2) + cycle.obs_var
    k = for i <- 0..3, do: (at(p, i, 0) + at(p, i, 2)) / s

    x = Enum.zip_with(x, k, fn xi, ki -> xi + ki * innovation end)
    p = symmetrize(mat_sub(p, outer(k, hp)))

    alpha = 1.0 - :math.exp(-dt / cycle.innovation_tau_s)
    innovation_var = cycle.innovation_var + alpha * (innovation * innovation - cycle.innovation_var)

    %{cycle | x: x, p: p, innovation_var: innovation_var}
  end

  @doc """
  Re-anchor the cycle frequency to a caller-estimated period (from the
  autocorrelation estimator). States and covariance carry over unchanged — only
  the rotation rate moves.
  """
  @spec retune(t(), number()) :: t()
  def retune(%__MODULE__{} = cycle, period_s) when period_s > 0 do
    %{cycle | omega: @two_pi / period_s}
  end

  @doc """
  Current view. `level_deg` is in the caller's unwrapped frame; `phase_rad` is
  `atan2(ψ*, ψ)` (decreases at 2π/period per second; the cycle's observation
  contribution is `amplitude·cos(phase)`).
  """
  @spec snapshot(t()) :: snapshot()
  def snapshot(%__MODULE__{x: nil} = cycle) do
    %{
      level_deg: nil,
      trend_deg_per_hr: nil,
      trend_se_deg_per_hr: nil,
      amplitude_deg: nil,
      phase_rad: nil,
      period_s: @two_pi / cycle.omega,
      innovation_var: nil
    }
  end

  def snapshot(%__MODULE__{x: [mu, beta, psi, psi_star]} = cycle) do
    %{
      level_deg: mu,
      trend_deg_per_hr: beta * 60.0,
      trend_se_deg_per_hr: :math.sqrt(max(at(cycle.p, 1, 1), 0.0)) * 60.0,
      amplitude_deg: :math.sqrt(psi * psi + psi_star * psi_star),
      phase_rad: :math.atan2(psi_star, psi),
      period_s: @two_pi / cycle.omega,
      innovation_var: cycle.innovation_var
    }
  end

  @doc """
  Deterministic forecast `horizon_s` seconds ahead (see the moduledoc for the
  mean/variance formulas). Returns `%{twd_deg:, ci_deg:}` in the unwrapped
  frame, or `nil` before the first observation.
  """
  @spec forecast(t(), number()) :: %{twd_deg: float(), ci_deg: float()} | nil
  def forecast(%__MODULE__{x: nil}, _horizon_s), do: nil

  def forecast(%__MODULE__{x: [mu, beta, psi, psi_star]} = cycle, horizon_s) do
    h = horizon_s / 1
    rho_h = :math.pow(cycle.rho_per_s, h)
    lam = cycle.omega * h
    a = [1.0, h / 60.0, rho_h * :math.cos(lam), rho_h * :math.sin(lam)]

    twd = mu + beta * (h / 60.0) + rho_h * (:math.cos(lam) * psi + :math.sin(lam) * psi_star)

    state_var = quadratic_form(a, cycle.p)

    accumulated =
      cycle.q_level_per_s * h +
        cycle.q_slope_per_s * h * h * h / 10_800.0 +
        cycle.cycle_var * (1.0 - rho_h * rho_h)

    %{twd_deg: twd, ci_deg: 1.96 * :math.sqrt(max(state_var + accumulated, 0.0))}
  end

  @doc """
  Seconds until the cycle phase next reaches `target_phase_rad` — the
  time-to-next-header primitive (tack logic lives in the classifier/observer).
  The phase decreases at 2π/period per second, so the answer is
  `((phase − target) mod 2π) / ω ∈ [0, period)`. Returns `nil` before the first
  observation.
  """
  @spec time_to_phase(t(), number()) :: float() | nil
  def time_to_phase(%__MODULE__{x: nil}, _target_phase_rad), do: nil

  def time_to_phase(%__MODULE__{x: [_, _, psi, psi_star]} = cycle, target_phase_rad) do
    time_from_phase(:math.atan2(psi_star, psi), @two_pi / cycle.omega, target_phase_rad)
  end

  @doc """
  Pure helper behind `time_to_phase/2`, usable directly on snapshot values:
  seconds from `phase_rad` until the phase (which decreases at `2π/period_s` per
  second) next reaches `target_phase_rad`.
  """
  @spec time_from_phase(number(), number(), number()) :: float()
  def time_from_phase(phase_rad, period_s, target_phase_rad) do
    delta = :math.fmod(phase_rad - target_phase_rad, @two_pi)
    delta = if delta < 0.0, do: delta + @two_pi, else: delta
    delta * period_s / @two_pi
  end

  # --- model matrices ----------------------------------------------------------

  defp transition(cycle, dt) do
    rho = :math.pow(cycle.rho_per_s, dt)
    lam = cycle.omega * dt
    c = :math.cos(lam)
    s = :math.sin(lam)

    [
      [1.0, dt / 60.0, 0.0, 0.0],
      [0.0, 1.0, 0.0, 0.0],
      [0.0, 0.0, rho * c, rho * s],
      [0.0, 0.0, -rho * s, rho * c]
    ]
  end

  defp process_noise(cycle, dt) do
    rho = :math.pow(cycle.rho_per_s, dt)
    q_cycle = cycle.cycle_var * (1.0 - rho * rho)

    [
      [cycle.q_level_per_s * dt, 0.0, 0.0, 0.0],
      [0.0, cycle.q_slope_per_s * dt, 0.0, 0.0],
      [0.0, 0.0, q_cycle, 0.0],
      [0.0, 0.0, 0.0, q_cycle]
    ]
  end

  # --- 4x4 matrix helpers (lists of rows) ---------------------------------------

  defp at(m, i, j), do: m |> Enum.at(i) |> Enum.at(j)

  defp mat_vec(m, v), do: Enum.map(m, fn row -> row |> Enum.zip_with(v, &*/2) |> Enum.sum() end)

  defp transpose(m), do: Enum.zip_with(m, & &1)

  defp mat_mul(a, b) do
    bt = transpose(b)
    Enum.map(a, fn row -> Enum.map(bt, fn col -> row |> Enum.zip_with(col, &*/2) |> Enum.sum() end) end)
  end

  defp mat_add(a, b), do: Enum.zip_with(a, b, fn ra, rb -> Enum.zip_with(ra, rb, &+/2) end)

  defp mat_sub(a, b), do: Enum.zip_with(a, b, fn ra, rb -> Enum.zip_with(ra, rb, &-/2) end)

  defp outer(u, v), do: Enum.map(u, fn ui -> Enum.map(v, &(ui * &1)) end)

  defp symmetrize(m) do
    mt = transpose(m)
    Enum.zip_with(m, mt, fn ra, rb -> Enum.zip_with(ra, rb, fn a, b -> 0.5 * (a + b) end) end)
  end

  defp quadratic_form(a, p), do: a |> Enum.zip_with(mat_vec(p, a), &*/2) |> Enum.sum()
end
