defmodule RacingOrg.Tracker.Pro.Compute.Library do
  @moduledoc """
  The shipped NATIVE sailing calcs (`true_wind`, `vmg`, `vmc`, and the polar-aware
  `polar_performance` / `target_boat_speed` / `target_twa` / `vmg_performance`)
  evaluated over the current raw signals. Unlike `RacingOrg.Tracker.Pro.Compute.Expr`
  (a generic stack machine over a server-compiled token list), these are hand-written
  formulas — the real sailing math — selected by the def's `library_key`.

  `compute/2` takes the library key (an atom) and a `signals` map (canonical name =>
  value in CATALOG UNITS: speeds m/s, angles DEGREES) and returns either
  `{:ok, %{output_name => value}}` (a calc may yield SEVERAL named outputs — e.g.
  `true_wind` yields speed/angle/direction — so Phase 8 can map the def's
  `output_field` onto the right one) or `:invalid` when a required input is missing.

  `compute/3` additionally takes a CONTEXT map carrying device state the calc needs
  but that is NOT a telemetry signal — currently `%{polar_lookup: Lookup.t() | nil}`,
  the precompiled polar interpolant. The wind/VMG/VMC calcs ignore the context, so
  `compute/2` is just `compute/3` with an empty context. The polar interpolant is
  built ONCE per polar version (off the hot path) and threaded in here per tick as a
  cheap reference — the per-tick cost is only fast O(log n) lookups, never a rebuild.

  ## Conventions / coordinate frame

  Boat frame: **x = forward (bow), y = starboard**. Wind angles are "wind FROM"
  bearings off the bow, positive to starboard (the NMEA masthead convention).
  Internally we work in radians and convert results back to degrees.

  ## true_wind  (`true_wind`)

  Flat-water vector triangle plus a heel correction. Inputs:
  `apparent_wind_speed` (AWS), `apparent_wind_angle` (AWA), `boat_speed` (STW),
  `heel`, `pitch` (`heading` optional, only needed for the direction output).

    * The masthead measures AWA in the HEELED mast frame; projecting the apparent
      vector onto the horizontal scales the athwartships component by `cos(heel)`
      (a heeled masthead reads a larger athwartships angle than the true horizontal
      one). So the horizontal apparent-wind components are
      `ax = AWS·cos(AWA)`, `ay = AWS·sin(AWA)·cos(heel)`.
      (`pitch` is accepted/required by the catalog and reserved for a later, fuller
      correction; the in-scope correction here is the heel term. Deep upwash /
      mast-twist corrections are explicitly DEFERRED to a later phase.)
    * Subtract the boat's through-water velocity `(STW, 0)` to get the true-wind
      vector `(tx, ty) = (ax − STW, ay)`.
    * `true_wind_speed = hypot(tx, ty)`,
      `true_wind_angle  = atan2(ty, tx)` (degrees, wrapped to (−180, 180]).
    * `true_wind_direction = wrap360(heading + true_wind_angle)` when `heading` is
      present (compass bearing the true wind blows FROM).

  ## vmg  (`vmg`)

  Velocity made good toward/along the wind axis: `vmg = boat_speed · |cos(TWA)|`.
  The TWA is taken from the live `true_wind_angle` signal when present (the polar
  pipeline's source), else derived as `wrap(true_wind_direction − heading)`.

  **Sign convention:** `vmg` is reported NON-NEGATIVE — it is the magnitude of the
  boat's progress ALONG the wind axis: progress *to windward* for `|TWA| < 90°` and
  *to leeward* for `|TWA| > 90°`. (Leg type — beat vs run — is carried separately by
  `target_twa`; folding the sign in here would make the percentage comparison in
  `vmg_performance` ill-defined, since the optimum VMG is itself a magnitude.)
  Inputs: `boat_speed` + either `true_wind_angle` OR (`true_wind_direction` +
  `heading`).

  ## vmc  (`vmc`)

  Velocity made good toward the active mark: `vmc = sog · cos(bearing_to_mark − cog)`.
  Inputs: `sog`, `cog`, `bearing_to_mark`. The bearing to the active mark is NOT yet
  produced on-device, so until a `bearing_to_mark` signal source exists, `vmc` is
  honestly `:invalid` (we do not fabricate a bearing).

  ## Polar-aware calcs (need `context.polar_lookup`)

  All four are INVALID when no polar is loaded (`polar_lookup` is `nil`/absent) or a
  required signal is missing — never a divide-by-zero or a fabricated number.

    * **`polar_performance`** (percent): `100 · boat_speed / target` where `target =
      Lookup.boat_speed(twa, tws)` at the live `true_wind_angle`/`true_wind_speed`.
      When `target` is ~0 (the no-go zone) the ratio is undefined, so the value is
      INVALID rather than a blow-up.
    * **`target_boat_speed`** (m/s): the VMG-optimal target speed for the current leg
      — `Lookup.optimum(tws).beat.bsp` when `true_wind_angle < 90°` (upwind), else
      `.run.bsp` (downwind).
    * **`target_twa`** (deg): the matching optimum angle — `.beat.twa` / `.run.twa`
      with the same beat/run choice as `target_boat_speed`.
    * **`vmg_performance`** (percent): `100 · actual_vmg / optimum_vmg` for the
      current leg, where `actual_vmg = boat_speed · |cos(twa)|` and `optimum_vmg` is
      `.beat.vmg` / `.run.vmg`. INVALID when the optimum VMG is ~0.
  """

  alias RacingOrg.Tracker.Pro.Polar.Lookup

  @type signals :: %{optional(String.t()) => number()}
  @type outputs :: %{optional(String.t()) => number()}
  @type context :: %{optional(:polar_lookup) => Lookup.t() | nil}

  @deg_per_rad 180.0 / :math.pi()
  @rad_per_deg :math.pi() / 180.0

  # A polar target/optimum speed at or below this (m/s) is treated as "no usable
  # target" (the no-go zone, or a degenerate polar) — performance is then INVALID
  # rather than a divide-by-(near-)zero.
  @target_eps 1.0e-3

  # The TWA boundary (degrees) between the upwind (beat) and downwind (run) leg.
  @beat_run_boundary_deg 90.0

  @doc """
  Evaluate one native library calc over `signals`. Returns `{:ok, named_outputs}` or
  `:invalid` (missing input or a non-finite result). Equivalent to `compute/3` with
  an empty context (no polar) — so the polar-aware calcs are INVALID here.
  """
  @spec compute(atom(), signals()) :: {:ok, outputs()} | :invalid
  def compute(key, signals), do: compute(key, signals, %{})

  @doc """
  Evaluate one native library calc over `signals` with a CONTEXT (device state that
  is not a signal — currently `%{polar_lookup: Lookup.t() | nil}`).
  """
  @spec compute(atom(), signals(), context()) :: {:ok, outputs()} | :invalid
  def compute(:true_wind, signals, _ctx), do: true_wind(signals)
  def compute(:vmg, signals, _ctx), do: vmg(signals)
  def compute(:vmc, signals, _ctx), do: vmc(signals)
  def compute(:polar_performance, signals, ctx), do: polar_performance(signals, ctx)
  def compute(:target_boat_speed, signals, ctx), do: target_boat_speed(signals, ctx)
  def compute(:target_twa, signals, ctx), do: target_twa(signals, ctx)
  def compute(:vmg_performance, signals, ctx), do: vmg_performance(signals, ctx)
  def compute(_unknown, _signals, _ctx), do: :invalid

  # --- true_wind ---

  defp true_wind(signals) do
    with {:ok, aws} <- fetch(signals, "apparent_wind_speed"),
         {:ok, awa_deg} <- fetch(signals, "apparent_wind_angle"),
         {:ok, stw} <- fetch(signals, "boat_speed"),
         {:ok, heel_deg} <- fetch(signals, "heel"),
         {:ok, _pitch_deg} <- fetch(signals, "pitch") do
      awa = awa_deg * @rad_per_deg
      heel = heel_deg * @rad_per_deg

      # Horizontal apparent-wind components (boat frame), heel-corrected athwartships.
      ax = aws * :math.cos(awa)
      ay = aws * :math.sin(awa) * :math.cos(heel)

      # Subtract the boat's through-water velocity (bow-ward) to get true wind.
      tx = ax - stw
      ty = ay

      tws = :math.sqrt(tx * tx + ty * ty)
      twa_deg = :math.atan2(ty, tx) * @deg_per_rad

      base = %{"true_wind_speed" => tws, "true_wind_angle" => twa_deg}

      outputs =
        case fetch(signals, "heading") do
          {:ok, heading_deg} -> Map.put(base, "true_wind_direction", wrap360(heading_deg + twa_deg))
          :error -> base
        end

      finite_map(outputs)
    else
      :error -> :invalid
    end
  end

  # --- vmg ---

  # Prefer the live true_wind_angle (the polar pipeline's TWA source); otherwise
  # derive TWA from true_wind_direction − heading. Reported as a NON-NEGATIVE
  # magnitude (progress along the wind axis); see the module doc on the sign
  # convention.
  defp vmg(signals) do
    with {:ok, stw} <- fetch(signals, "boat_speed"),
         {:ok, twa_deg} <- twa_for_vmg(signals) do
      finite_map(%{"vmg" => abs(stw * :math.cos(twa_deg * @rad_per_deg))})
    else
      :error -> :invalid
    end
  end

  defp twa_for_vmg(signals) do
    case fetch(signals, "true_wind_angle") do
      {:ok, twa_deg} ->
        {:ok, twa_deg}

      :error ->
        with {:ok, twd_deg} <- fetch(signals, "true_wind_direction"),
             {:ok, heading_deg} <- fetch(signals, "heading") do
          {:ok, wrap180(twd_deg - heading_deg)}
        end
    end
  end

  # --- vmc ---

  defp vmc(signals) do
    with {:ok, sog} <- fetch(signals, "sog"),
         {:ok, cog_deg} <- fetch(signals, "cog"),
         {:ok, brg_deg} <- fetch(signals, "bearing_to_mark") do
      diff = wrap180(brg_deg - cog_deg) * @rad_per_deg
      finite_map(%{"vmc" => sog * :math.cos(diff)})
    else
      :error -> :invalid
    end
  end

  # --- polar-aware calcs (need context.polar_lookup) ---

  # 100 * boat_speed / Lookup.boat_speed(twa, tws). INVALID when the polar target is
  # ~0 (no-go zone) or no polar is loaded.
  defp polar_performance(signals, ctx) do
    with {:ok, lookup} <- polar_lookup(ctx),
         {:ok, stw} <- fetch(signals, "boat_speed"),
         {:ok, twa} <- fetch(signals, "true_wind_angle"),
         {:ok, tws} <- fetch(signals, "true_wind_speed"),
         {:ok, target} <- Lookup.boat_speed(lookup, twa, tws) |> ok_or_error(),
         true <- target > @target_eps do
      finite_map(%{"polar_performance" => 100.0 * stw / target})
    else
      _ -> :invalid
    end
  end

  # The VMG-optimal target boat speed for the current leg (beat when twa < 90, else
  # run).
  defp target_boat_speed(signals, ctx) do
    case leg_optimum(signals, ctx) do
      {:ok, leg} -> finite_map(%{"target_boat_speed" => leg.bsp})
      :error -> :invalid
    end
  end

  # The matching optimum TWA for the current leg.
  defp target_twa(signals, ctx) do
    case leg_optimum(signals, ctx) do
      {:ok, leg} -> finite_map(%{"target_twa" => leg.twa})
      :error -> :invalid
    end
  end

  # 100 * actual_vmg / optimum_vmg for the current leg. actual_vmg is the magnitude
  # boat_speed * |cos(twa)|; optimum_vmg is the leg's optimum VMG. INVALID when the
  # optimum VMG is ~0.
  defp vmg_performance(signals, ctx) do
    with {:ok, leg} <- leg_optimum(signals, ctx),
         {:ok, stw} <- fetch(signals, "boat_speed"),
         {:ok, twa} <- fetch(signals, "true_wind_angle"),
         true <- leg.vmg > @target_eps do
      actual_vmg = abs(stw * :math.cos(twa * @rad_per_deg))
      finite_map(%{"vmg_performance" => 100.0 * actual_vmg / leg.vmg})
    else
      _ -> :invalid
    end
  end

  # Resolve the current-leg optimum (beat for twa < 90, run otherwise) from the polar
  # at the live TWS. Returns {:ok, %{twa, bsp, vmg}} or :error.
  defp leg_optimum(signals, ctx) do
    with {:ok, lookup} <- polar_lookup(ctx),
         {:ok, twa} <- fetch(signals, "true_wind_angle"),
         {:ok, tws} <- fetch(signals, "true_wind_speed"),
         {:ok, %{beat: beat, run: run}} <- Lookup.optimum(lookup, tws) |> ok_or_error() do
      {:ok, if(abs(twa) < @beat_run_boundary_deg, do: beat, else: run)}
    else
      _ -> :error
    end
  end

  defp polar_lookup(%{polar_lookup: %Lookup{} = lookup}), do: {:ok, lookup}
  defp polar_lookup(_), do: :error

  # Normalize a Lookup result: {:ok, v} stays, :error stays, but a bare {:ok, ...}
  # map (optimum/2) also passes through. Keeps the `with` chains uniform.
  defp ok_or_error({:ok, _} = ok), do: ok
  defp ok_or_error(:error), do: :error

  # --- helpers ---

  defp fetch(signals, name) do
    case Map.fetch(signals, name) do
      {:ok, v} when is_number(v) -> {:ok, v / 1}
      _ -> :error
    end
  end

  # Wrap an angle (degrees) into [0, 360).
  defp wrap360(deg) do
    r = :math.fmod(deg, 360.0)
    if r < 0.0, do: r + 360.0, else: r
  end

  # Wrap an angle (degrees) into (-180, 180].
  defp wrap180(deg) do
    w = wrap360(deg)
    if w > 180.0, do: w - 360.0, else: w
  end

  # Ensure every output is a finite float; otherwise the whole calc is invalid. On
  # BEAM a float cannot be ±Inf (arithmetic overflow raises), so the only non-finite
  # case to guard is NaN, which fails `v == v`.
  defp finite_map(map) do
    if Enum.all?(map, fn {_k, v} -> is_float(v) and v == v end) do
      {:ok, map}
    else
      :invalid
    end
  end
end
