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

  Flat-water vector triangle plus an OPTIONAL heel correction. The ESSENTIAL inputs
  are `apparent_wind_speed` (AWS), `apparent_wind_angle` (AWA), `boat_speed` (STW);
  `heel`, `pitch`, and `heading` are all optional refinements.

    * The masthead measures AWA in the HEELED mast frame, where the athwartships
      component of the horizontal wind appears COMPRESSED by `cos(heel)` (a heeled
      vane reads a SMALLER athwartships component than the true horizontal one).
      The Gentry / Pedrick–McCurdy recovery therefore DIVIDES the measured
      athwartships term by `cos(heel)` to restore the horizontal components:
      `ax = AWS·cos(AWA)`, `ay = AWS·sin(AWA) / max(cos(heel), 0.5)`. The
      `max(cos(heel), 0.5)` clamp bounds the correction at extreme heel (≥ 60°) so
      a bad heel reading can never blow the wind vector up — the athwartships
      component is at most doubled. `heel` is a REFINEMENT and DEFAULTS to `0.0`
      when absent (no athwartships correction) — a boat with no heel sensor still
      computes true wind, and the flat-water output (`heel = 0`) is identical
      whether heel is published as `0.0` or absent.
      (`pitch` is a catalog-available input reserved for a later, fuller correction;
      it is NOT required and never participates today, so its absence never makes the
      calc invalid. Deep upwash / mast-twist corrections are explicitly DEFERRED to a
      later phase.)
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

  Each resolves the true-wind ANGLE through the shared `resolve_twa/1` (the same
  resolution `vmg` uses): it prefers the live `true_wind_angle` signal and otherwise
  derives it from `true_wind_direction − heading`. On a real boat the network
  true-wind PGN publishes direction + speed but no angle, so the derived path is what
  makes these calcs work in production; an on-device `:true_wind` calc whose outputs
  are fed back as signals supplies `true_wind_angle` directly. TWS always comes from
  the `true_wind_speed` signal.

    * **`polar_performance`** (percent): `100 · boat_speed / target` where `target =
      Lookup.boat_speed(twa, tws)` at the resolved TWA + `true_wind_speed`.
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

  ## Wally — shift-phase modulation of `target_boat_speed` / `target_twa`

  When the wind OSCILLATES, VMG should be maximized along the AVERAGE wind, not
  the current wind (the Ockam/McCurdy doctrine): on the LIFTED tack sail lower
  and faster than the polar optimum ("foot the lift"); on the HEADED tack sail
  higher and slower ("pinch the header") — by roughly HALF the shift. The
  doctrine, the delta rule (`clamp(lift/2, ±6°)`), and the activation gates
  (oscillating regime code 2, `shift_confidence ≥ 50`, `|lift| ≥ 2°` deadband,
  upwind `|twa| < 90°` — downwind Wally is a later refinement) live in
  `RacingOrg.Tracker.Pro.WindShift.Wally`.

  The two target calcs read four OPTIONAL signals — `wally_mode` (0 off /
  1 shadow / 2 on, the `WindShift.Config` policy published per tick by the
  WindShift Observer), `wind_lift_deg` (tack-resolved, positive = lifted),
  `wind_regime`, `shift_confidence`:

    * **mode 2 (on) + gates open** — the PRIMARY outputs become the modulated
      targets: `target_twa = leg_twa + delta` (the signed delta WIDENS the
      angle on a lift, NARROWS it on a header) and `target_boat_speed =
      Lookup.boat_speed(leg_twa + delta, tws)` — the honest polar speed AT the
      modulated angle (faster than the optimum bsp when footing on the polar's
      rising side, slower when pinching), never a fabricated number.
      `wally_delta_deg` and `wally_active => 1.0` ride along as extra outputs.
    * **mode 1 (shadow) + gates open** — the primaries are UNTOUCHED
      (bit-identical to mode off); `wally_target_twa` /
      `wally_target_boat_speed` / `wally_delta_deg` / `wally_active => 1.0`
      ride along for display and evaluation.
    * **mode 0 / any gate closed / signals missing** — byte-identical outputs
      to a build without Wally (no extra keys). A degenerate polar speed at the
      modulated angle (the no-go epsilon) also deactivates rather than emitting
      a useless target.

  Because these calcs are PURE and re-evaluated per tick, reversion when any
  gate fails (confidence drop, regime change, mode change) is immediate and
  glitch-free at the source; the per-def output damping in
  `RacingOrg.Tracker.Pro.Compute.Broadcaster` then smooths the step for the
  NMEA bus consumers. `vmg_performance` deliberately keeps measuring against
  the LEG OPTIMUM VMG — sailing Wally targets reads slightly below 100% on the
  current wind by design (the gain is realized against the average wind).

  ## Next-leg predicted apparent wind (B&G "Next Leg AWA/AWS")

  Predicts the apparent wind you'd experience on the FOLLOWING leg of the course
  (from the active mark to the next mark in `sequence` order). The leg geometry
  enters as the `next_leg_bearing` signal (deg, geographic 0–360) — injected by
  `RacingOrg.Tracker.Pro.Nav.Broadcaster` the same way `bearing_to_mark` is, refreshed
  only on assignment / active-mark change (off the compute hot path). When there is no
  next leg (active mark is the finish) the signal is ABSENT, so these are INVALID.

  Angle convention: TWA/AWA are measured FROM THE BOW, `0` = head to wind, folded into
  `[0, 180]` (no port/starboard sign — the leg geometry already fixes the side).

    * **`next_leg_twa`** (deg, 0–180): `|wrap180(true_wind_direction − next_leg_bearing)|`.
    * **`next_leg_aws`** (m/s) / **`next_leg_awa`** (deg, 0–180): the apparent-wind
      triangle with `TWS = true_wind_speed`, `TWA = next_leg_twa`, and predicted boat
      speed `BSP = Lookup.boat_speed(next_leg_twa, TWS)` (the polar speed on that leg):

          AWS = √(TWS² + BSP² + 2·TWS·BSP·cos(TWA))
          AWA = atan2(TWS·sin(TWA), BSP + TWS·cos(TWA))   → degrees

      INVALID when there is no next leg, no polar, or `BSP` is degenerate (the next-leg
      TWA lands in the no-go zone → the polar interpolates to ~0; the prediction is
      meaningless), rather than a NaN or a divide-by-zero.
  """

  alias RacingOrg.Tracker.Pro.Polar.Lookup
  alias RacingOrg.Tracker.Pro.WindShift.Wally

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
  def compute(:next_leg_twa, signals, _ctx), do: next_leg_twa(signals)
  def compute(:next_leg_aws, signals, ctx), do: next_leg_apparent(signals, ctx, "next_leg_aws")
  def compute(:next_leg_awa, signals, ctx), do: next_leg_apparent(signals, ctx, "next_leg_awa")
  def compute(_unknown, _signals, _ctx), do: :invalid

  # --- true_wind ---

  defp true_wind(signals) do
    # ESSENTIAL inputs only: apparent wind + STW. `heel` is an optional refinement
    # (default 0.0 → no athwartships correction); `pitch` is reserved for a future
    # correction and is NOT required; `heading` is optional (adds the direction
    # output). None of heel/pitch/heading may make the calc invalid by their absence.
    with {:ok, aws} <- fetch(signals, "apparent_wind_speed"),
         {:ok, awa_deg} <- fetch(signals, "apparent_wind_angle"),
         {:ok, stw} <- fetch(signals, "boat_speed") do
      awa = awa_deg * @rad_per_deg
      heel = fetch_or(signals, "heel", 0.0) * @rad_per_deg

      # Horizontal apparent-wind components (boat frame). The heeled vane measures a
      # COMPRESSED athwartships component, so the recovery DIVIDES by cos(heel)
      # (Gentry / Pedrick–McCurdy) — only when heel is present (else cos(0) = 1, a
      # no-op). The max(cos, 0.5) clamp bounds the correction at extreme heel
      # (>= 60 deg): a bad heel reading can at most DOUBLE the athwartships
      # component, never blow the wind vector up.
      ax = aws * :math.cos(awa)
      ay = aws * :math.sin(awa) / max(:math.cos(heel), 0.5)

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

  # Reported as a NON-NEGATIVE magnitude (progress along the wind axis); see the
  # module doc on the sign convention. TWA is resolved via the shared `resolve_twa/1`
  # helper (live signal, else derived from direction − heading).
  defp vmg(signals) do
    with {:ok, stw} <- fetch(signals, "boat_speed"),
         {:ok, twa_deg} <- resolve_twa(signals) do
      finite_map(%{"vmg" => abs(stw * :math.cos(twa_deg * @rad_per_deg))})
    else
      :error -> :invalid
    end
  end

  # The single source of truth for the true-wind ANGLE every TWA-driven calc uses
  # (`vmg` and the polar/leg-optimum calcs). Prefer the live `true_wind_angle`
  # signal — the canonical source when a device/feedback publishes it; otherwise
  # derive it from `true_wind_direction − heading` (the common instrumented-boat
  # case, where the network true-wind PGN gives direction + speed but no angle).
  # Returns `{:ok, twa_deg}` (a signed angle off the bow) or `:error`.
  defp resolve_twa(signals) do
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
         {:ok, twa} <- resolve_twa(signals),
         {:ok, tws} <- fetch(signals, "true_wind_speed"),
         {:ok, target} <- Lookup.boat_speed(lookup, twa, tws) |> ok_or_error(),
         true <- target > @target_eps do
      finite_map(%{"polar_performance" => 100.0 * stw / target})
    else
      _ -> :invalid
    end
  end

  # The VMG-optimal target boat speed for the current leg (beat when twa < 90, else
  # run), Wally-modulated when the mode + gates allow (see with_wally/5).
  defp target_boat_speed(signals, ctx) do
    case leg_optimum(signals, ctx) do
      {:ok, leg} -> finite_map(with_wally(%{"target_boat_speed" => leg.bsp}, :bsp, signals, ctx, leg))
      :error -> :invalid
    end
  end

  # The matching optimum TWA for the current leg, Wally-modulated when the mode +
  # gates allow (see with_wally/5).
  defp target_twa(signals, ctx) do
    case leg_optimum(signals, ctx) do
      {:ok, leg} -> finite_map(with_wally(%{"target_twa" => leg.twa}, :twa, signals, ctx, leg))
      :error -> :invalid
    end
  end

  # 100 * actual_vmg / optimum_vmg for the current leg. actual_vmg is the magnitude
  # boat_speed * |cos(twa)|; optimum_vmg is the leg's optimum VMG. INVALID when the
  # optimum VMG is ~0.
  defp vmg_performance(signals, ctx) do
    with {:ok, leg} <- leg_optimum(signals, ctx),
         {:ok, stw} <- fetch(signals, "boat_speed"),
         {:ok, twa} <- resolve_twa(signals),
         true <- leg.vmg > @target_eps do
      actual_vmg = abs(stw * :math.cos(twa * @rad_per_deg))
      finite_map(%{"vmg_performance" => 100.0 * actual_vmg / leg.vmg})
    else
      _ -> :invalid
    end
  end

  # --- Wally (shift-phase target modulation; see the module doc + WindShift.Wally) ---

  # Overlay the Wally modulation onto a target calc's base outputs. `primary` is
  # which primary this calc owns (:twa | :bsp); `leg` is the base leg optimum.
  #
  #   * inactive (mode off / a gate closed / signals missing / degenerate polar
  #     speed at the modulated angle) -> the base outputs, BYTE-IDENTICAL to a
  #     build without Wally (no extra keys). Because this is re-decided on every
  #     evaluation from the live signals, reversion when a gate fails is
  #     immediate and glitch-free.
  #   * mode 2 (on) -> the PRIMARY becomes the modulated value; `wally_delta_deg`
  #     + `wally_active => 1.0` ride along.
  #   * mode 1 (shadow) -> the primary stays the base value; the modulated pair
  #     rides along as `wally_target_twa` / `wally_target_boat_speed` (both, from
  #     either calc, so one def suffices for display) plus `wally_delta_deg` +
  #     `wally_active => 1.0`.
  defp with_wally(base_outputs, primary, signals, ctx, leg) do
    case wally_modulation(signals, ctx, leg) do
      :inactive ->
        base_outputs

      {mode, mod} ->
        primary_outputs =
          case {mode, primary} do
            {:on, :twa} -> %{"target_twa" => mod.twa}
            {:on, :bsp} -> %{"target_boat_speed" => mod.bsp}
            {:shadow, _} -> base_outputs
          end

        shadow_extras =
          case mode do
            :on -> %{}
            :shadow -> %{"wally_target_twa" => mod.twa, "wally_target_boat_speed" => mod.bsp}
          end

        primary_outputs
        |> Map.merge(shadow_extras)
        |> Map.merge(%{"wally_delta_deg" => mod.delta, "wally_active" => 1.0})
    end
  end

  # Decide + compute the Wally modulation from the OPTIONAL wind-shift signals
  # (`wally_mode`, `wind_lift_deg`, `wind_regime`, `shift_confidence` — published
  # per tick by the WindShift Observer) and the polar. Returns
  # `{:on | :shadow, %{twa:, bsp:, delta:}}` or `:inactive`.
  #
  # The lift is tack-resolved (positive = lifted), so the signed half-shift delta
  # applies directly to the |TWA| leg optimum: widen on a lift (FOOT — the polar
  # speed at the footed angle is honestly FASTER on the rising side), narrow on a
  # header (PINCH — honestly slower). The speed target is always the polar
  # surface AT the modulated angle, never a fabricated number; a degenerate polar
  # speed there (~0, the no-go zone) deactivates the modulation instead of
  # emitting a useless target.
  defp wally_modulation(signals, ctx, leg) do
    with {:ok, mode} when mode == 1.0 or mode == 2.0 <- fetch(signals, "wally_mode"),
         {:ok, lift} <- fetch(signals, "wind_lift_deg"),
         {:ok, regime} <- fetch(signals, "wind_regime"),
         {:ok, confidence} <- fetch(signals, "shift_confidence"),
         {:ok, twa} <- resolve_twa(signals),
         true <-
           Wally.active?(%{wind_lift_deg: lift, wind_regime: regime, shift_confidence: confidence, twa_deg: twa}),
         {:ok, lookup} <- polar_lookup(ctx),
         {:ok, tws} <- fetch(signals, "true_wind_speed"),
         delta = Wally.delta_deg(lift),
         modulated_twa = leg.twa + delta,
         {:ok, bsp} <- Lookup.boat_speed(lookup, modulated_twa, tws) |> ok_or_error(),
         true <- bsp > @target_eps do
      {if(mode == 2.0, do: :on, else: :shadow), %{twa: modulated_twa, bsp: bsp, delta: delta}}
    else
      _ -> :inactive
    end
  end

  # Resolve the current-leg optimum (beat for twa < 90, run otherwise) from the polar
  # at the live TWS. Returns {:ok, %{twa, bsp, vmg}} or :error.
  defp leg_optimum(signals, ctx) do
    with {:ok, lookup} <- polar_lookup(ctx),
         {:ok, twa} <- resolve_twa(signals),
         {:ok, tws} <- fetch(signals, "true_wind_speed"),
         {:ok, %{beat: beat, run: run}} <- Lookup.optimum(lookup, tws) |> ok_or_error() do
      {:ok, if(abs(twa) < @beat_run_boundary_deg, do: beat, else: run)}
    else
      _ -> :error
    end
  end

  # --- next-leg predicted apparent wind (B&G "Next Leg AWA/AWS") ---

  # The TWA you'd sail on the NEXT leg: fold of (true_wind_direction − next_leg_bearing)
  # into [0, 180] (absolute, no port/starboard sign — the leg geometry fixes the side).
  # `next_leg_bearing` is injected by Nav.Broadcaster (deg, geographic 0–360) and is
  # ABSENT when there is no next leg, so this is INVALID then (not garbage).
  defp next_leg_twa(signals) do
    with {:ok, twd} <- fetch(signals, "true_wind_direction"),
         {:ok, brg} <- fetch(signals, "next_leg_bearing") do
      finite_map(%{"next_leg_twa" => abs(wrap180(twd - brg))})
    else
      :error -> :invalid
    end
  end

  # Predicted apparent wind on the next leg via the standard apparent-wind triangle,
  # with TWS = current true_wind_speed, TWA = next_leg_twa, and BSP = the polar boat
  # speed you'd make on that leg (`Lookup.boat_speed(next_leg_twa, tws)`):
  #
  #   AWS = sqrt(TWS² + BSP² + 2·TWS·BSP·cos(TWA))
  #   AWA = atan2(TWS·sin(TWA), BSP + TWS·cos(TWA))   (deg, 0–180, from the bow)
  #
  # INVALID when there is no next leg (no next_leg_bearing), no polar, or BSP is
  # degenerate (the no-go zone — Lookup interpolates to ~0; the prediction is
  # meaningless), rather than emitting a NaN or a divide-by-zero.
  defp next_leg_apparent(signals, ctx, output_name) do
    with {:ok, lookup} <- polar_lookup(ctx),
         {:ok, %{"next_leg_twa" => twa_deg}} <- next_leg_twa(signals),
         {:ok, tws} <- fetch(signals, "true_wind_speed"),
         {:ok, bsp} <- Lookup.boat_speed(lookup, twa_deg, tws) |> ok_or_error(),
         true <- bsp > @target_eps do
      twa = twa_deg * @rad_per_deg
      value = next_leg_output(output_name, tws, bsp, twa)
      finite_map(%{output_name => value})
    else
      _ -> :invalid
    end
  end

  defp next_leg_output("next_leg_aws", tws, bsp, twa) do
    :math.sqrt(tws * tws + bsp * bsp + 2.0 * tws * bsp * :math.cos(twa))
  end

  defp next_leg_output("next_leg_awa", tws, bsp, twa) do
    :math.atan2(tws * :math.sin(twa), bsp + tws * :math.cos(twa)) * @deg_per_rad
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

  # Like `fetch/2` for OPTIONAL refinement signals: the value when present + numeric,
  # else `default`. A non-numeric value also falls back to the default.
  defp fetch_or(signals, name, default) do
    case fetch(signals, name) do
      {:ok, v} -> v
      :error -> default
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
