defmodule RacingOrg.Tracker.Pro.Polar.Observer.Bins do
  @moduledoc """
  Pure (TWS, TWA) binning for the observational ("sailed") polar plane.

  The sailed polar partitions the wind operating envelope into a grid of cells,
  each keyed by `{tws_idx, twa_idx}`, and accumulates a streaming boat-speed
  percentile per cell. This module is the **coordinate system only** — mapping a
  live `(tws, twa)` sample to its canonical cell key, and reporting the
  representative wind values (the cell *center*) for a key. It holds no per-cell
  state and allocates nothing beyond the small tuples it returns.

  ## Units (explicit and consistent with the rest of the codebase)

    * **TWS is metres/second.** Every speed in this project is SI (`tws_mps`,
      `boat_speed_mps`, …; see `RacingOrg.Tracker.Pro.Polar`). The TWS bin
      *width* is therefore stored and applied in **m/s**. The DEFAULT width is
      `1 knot = 0.514444 m/s`, because sailors reason about wind in knots and a
      1-knot resolution is the conventional polar granularity — but the unit on
      the wire is always m/s, so callers feed m/s and never convert.
    * **TWA is degrees**, folded to absolute `[0, 180]` (see below). The default
      width is `5°`, the usual sailed-polar angular resolution.

  ## TWA folding (port/starboard merge)

  A boat's polar is symmetric about the wind axis, so port and starboard are the
  same operating point. `fold_twa/1` maps any heading-relative wind angle into
  `[0, 180]`: wrap into `[0, 360)`, then reflect `(180, 360)` back down. So
  `200° → 160°`, `-30° → 30°`, `270° → 90°`, `540° → 180°`.

  ## Index / center convention

  A value `v` with bin width `w` lands in bin `idx = floor(v / w)`. The lower
  edge is **inclusive** (`v = k·w` lands in bin `k`), matching `floor`. The value
  REPORTED for a cell (its `center/2`) is the **bin midpoint** `(idx + 0.5)·w` —
  the natural representative of the half-open interval `[idx·w, (idx+1)·w)`.

  A closed TOP edge clamps into the last bin rather than spawning an
  out-of-range singleton: TWA `180°` would be `floor(180/5) = 36`, so it is
  folded into bin `35` (the `[175, 180]` interval), and TWS exactly at the
  ceiling likewise shares the final TWS bin.

  ## Operating domain (fail-closed)

  The cell key space must be **finite**: every key is a persisted map entry that
  is written to flash and synced upstream, so a single garbage sensor reading
  that mints an arbitrary index costs real storage and bandwidth forever. Both
  axes are therefore bounded, and a sample outside the domain is REJECTED —
  never clamped into the nearest valid bin, because clamping folds a broken
  reading into a legitimate learned cell and silently poisons it.

    * **TWS** must be a finite number in `[0, :max_tws_mps]`. The default
      ceiling is `100 knots` (51.4444 m/s). Hurricane force begins at 64 kn and
      no boat is sailed anywhere near it, so 100 kn cannot exclude a real
      operating point while still bounding the axis at 100 bins. Negative wind
      speed is physically impossible, and a NaN/±Inf/non-number reading is a
      broken feed; all are rejected.
    * **TWA** must be a finite number in `[-360, 360]` degrees before folding.
      Wind angles on the wire are always expressed within a single turn, so a
      value beyond that is garbage — and wrapping it would ALIAS it onto a
      perfectly valid angle bin and poison that cell.

  With the defaults the whole plane is `100 × 36 = 3600` cells (`max_key/1`).
  `fetch_cell/3` returns `{:error, :tws_out_of_domain | :twa_out_of_domain}` for
  callers that must not crash (the `Observer` tallies the reason); `cell/3`
  raises for callers that have already validated their input. `valid_key?/2`
  screens keys that arrive from OUTSIDE this module — notably a persisted file
  written before the domain was enforced, which can still carry unbounded keys.

  This is the SECONDARY (observed) plane; it is independent of the reference
  polar's irregular TWS rows / TWA cells in `RacingOrg.Tracker.Pro.Polar`.
  """

  # 1 knot in metres/second — the default TWS bin width.
  @knot_mps 0.514444
  @default_twa_width_deg 5.0
  # 100 knots: far above any sailed wind (hurricane force starts at 64 kn) yet
  # finite, so the TWS axis — and therefore the cell key space — is bounded.
  @default_max_tws_mps 100.0 * @knot_mps
  # A wind angle is always reported within one turn either way; beyond that the
  # reading is garbage rather than an unwrapped angle.
  @max_abs_twa_deg 360.0

  @enforce_keys [:twa_width_deg, :tws_width_mps, :max_tws_mps]
  defstruct twa_width_deg: @default_twa_width_deg,
            tws_width_mps: @knot_mps,
            max_tws_mps: @default_max_tws_mps

  @type t :: %__MODULE__{twa_width_deg: float(), tws_width_mps: float(), max_tws_mps: float()}
  @type key :: {non_neg_integer(), non_neg_integer()}
  @type domain_error :: :tws_out_of_domain | :twa_out_of_domain

  @doc """
  Build a binning config.

  Options:

    * `:twa_width_deg` — TWA bin width in degrees (default `5.0`).
    * `:tws_width_mps` — TWS bin width in **m/s** (default `0.514444`, i.e.
      1 knot).
    * `:max_tws_mps` — inclusive TWS ceiling in **m/s** (default `51.4444`, i.e.
      100 knots). Samples above it are rejected, not clamped.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    twa = Keyword.get(opts, :twa_width_deg, @default_twa_width_deg)
    tws = Keyword.get(opts, :tws_width_mps, @knot_mps)
    max_tws = Keyword.get(opts, :max_tws_mps, @default_max_tws_mps)

    unless positive_finite?(twa), do: raise(ArgumentError, "twa_width_deg must be a finite number > 0")
    unless positive_finite?(tws), do: raise(ArgumentError, "tws_width_mps must be a finite number > 0")
    unless positive_finite?(max_tws), do: raise(ArgumentError, "max_tws_mps must be a finite number > 0")

    %__MODULE__{twa_width_deg: twa + 0.0, tws_width_mps: tws + 0.0, max_tws_mps: max_tws + 0.0}
  end

  @doc "1 knot expressed in m/s (the default TWS bin width)."
  @spec knot_mps() :: float()
  def knot_mps, do: @knot_mps

  @doc "The DEFAULT inclusive TWS ceiling in m/s (100 knots). See the module doc."
  @spec max_tws_mps() :: float()
  def max_tws_mps, do: @default_max_tws_mps

  @doc """
  Fold an arbitrary wind angle (degrees) into absolute `[0, 180]`, merging port
  and starboard.
  """
  @spec fold_twa(number()) :: float()
  def fold_twa(twa) when is_number(twa) do
    # wrap into [0, 360), then reflect the (180, 360) half back down.
    w = :math.fmod(twa + 0.0, 360.0)
    w = if w < 0.0, do: w + 360.0, else: w
    if w > 180.0, do: 360.0 - w, else: w
  end

  @doc """
  Canonical cell key `{tws_idx, twa_idx}` for an IN-DOMAIN `(tws_mps, twa_deg)`
  sample, or `{:error, reason}` when the sample is outside the operating domain
  (see the module doc). TWA is folded to `[0, 180]` after the domain check; both
  closed top edges clamp into the last bin.

  TWS is checked before TWA, so the reason is stable for a doubly-bad sample.
  """
  @spec fetch_cell(t(), term(), term()) :: {:ok, key()} | {:error, domain_error()}
  def fetch_cell(%__MODULE__{} = b, tws_mps, twa_deg) do
    cond do
      not in_tws_domain?(b, tws_mps) -> {:error, :tws_out_of_domain}
      not in_twa_domain?(twa_deg) -> {:error, :twa_out_of_domain}
      true -> {:ok, {tws_index(b, tws_mps), twa_index(fold_twa(twa_deg), b.twa_width_deg)}}
    end
  end

  @doc """
  `true` when `(tws_mps, twa_deg)` is inside the operating domain and therefore
  maps to a cell.
  """
  @spec in_domain?(t(), term(), term()) :: boolean()
  def in_domain?(%__MODULE__{} = b, tws_mps, twa_deg),
    do: in_tws_domain?(b, tws_mps) and in_twa_domain?(twa_deg)

  @doc """
  Canonical cell key for a sample, RAISING `ArgumentError` when the sample is
  out of domain. For callers that cannot crash — anything fed by live sensors —
  use `fetch_cell/3` instead.
  """
  @spec cell(t(), term(), term()) :: key()
  def cell(%__MODULE__{} = b, tws_mps, twa_deg) do
    case fetch_cell(b, tws_mps, twa_deg) do
      {:ok, key} ->
        key

      {:error, reason} ->
        raise ArgumentError,
              "#{reason}: (tws_mps: #{inspect(tws_mps)}, twa_deg: #{inspect(twa_deg)}) is outside " <>
                "the sailed-polar operating domain (tws in [0, #{b.max_tws_mps}] m/s, " <>
                "twa in [-#{@max_abs_twa_deg}, #{@max_abs_twa_deg}] deg)"
    end
  end

  @doc """
  The largest key the domain can produce, `{max_tws_idx, max_twa_idx}` — the
  inclusive upper corner of the bounded cell space.
  """
  @spec max_key(t()) :: key()
  def max_key(%__MODULE__{} = b), do: {max_tws_index(b), max_twa_index(b.twa_width_deg)}

  @doc """
  `true` when `key` is a well-formed key inside the bounded cell space.

  Used to screen keys that arrive from OUTSIDE this module — chiefly a persisted
  sailed polar written before the domain was enforced, which can carry unbounded
  junk keys minted from a bad sensor reading.
  """
  @spec valid_key?(t(), term()) :: boolean()
  def valid_key?(%__MODULE__{} = b, {tws_idx, twa_idx})
      when is_integer(tws_idx) and is_integer(twa_idx) do
    {max_tws, max_twa} = max_key(b)
    tws_idx >= 0 and tws_idx <= max_tws and twa_idx >= 0 and twa_idx <= max_twa
  end

  def valid_key?(%__MODULE__{}, _other), do: false

  @doc """
  Representative wind values `{tws_mps, twa_deg}` for a cell — the bin midpoint
  `(idx + 0.5) · width`. This is the value reported for the cell downstream.
  """
  @spec center(t(), key()) :: {float(), float()}
  def center(%__MODULE__{tws_width_mps: tw, twa_width_deg: aw}, {tws_idx, twa_idx})
      when is_integer(tws_idx) and is_integer(twa_idx) do
    {(tws_idx + 0.5) * tw, (twa_idx + 0.5) * aw}
  end

  @doc """
  Enumerate the populated cells of a map keyed by cell key, pairing each with its
  center and its stored value: `[{key, {tws_c, twa_c}, value}]`.

  Pure projection over the caller-owned map; no ordering is imposed.
  """
  @spec populated(t(), %{optional(key()) => value}) :: [{key(), {float(), float()}, value}]
        when value: term()
  def populated(%__MODULE__{} = b, cells) when is_map(cells) do
    Enum.map(cells, fn {key, value} -> {key, center(b, key), value} end)
  end

  # =====================================================================
  # Internal
  # =====================================================================

  # Both axes are validated BEFORE any arithmetic: a huge value would otherwise
  # overflow `v / width` to +Inf and raise out of `trunc/1`, and a merely large
  # one would mint an unbounded index.
  defp in_tws_domain?(%__MODULE__{max_tws_mps: max_tws}, tws_mps),
    do: finite_number?(tws_mps) and tws_mps >= 0.0 and tws_mps <= max_tws

  defp in_twa_domain?(twa_deg),
    do: finite_number?(twa_deg) and twa_deg >= -@max_abs_twa_deg and twa_deg <= @max_abs_twa_deg

  # TWS is already known in-domain. The closed top edge (tws == max_tws_mps)
  # clamps into the last bin rather than spawning an out-of-range singleton,
  # mirroring the TWA 180 clamp.
  defp tws_index(%__MODULE__{tws_width_mps: width} = b, tws_mps),
    do: min(floor_div(tws_mps, width), max_tws_index(b))

  # TWA is already folded to [0, 180]. floor(180/width) is the out-of-range top
  # edge; clamp it down by one so the closed top of the domain shares the last
  # bin instead of spawning an empty singleton.
  defp twa_index(twa, width), do: min(floor_div(twa, width), max_twa_index(width))

  defp max_tws_index(%__MODULE__{max_tws_mps: max_tws, tws_width_mps: width}),
    do: max(trunc(:math.ceil(max_tws / width)) - 1, 0)

  defp max_twa_index(width), do: max(trunc(:math.ceil(180.0 / width)) - 1, 0)

  defp floor_div(v, width), do: trunc(:math.floor(v / width))

  defp positive_finite?(v), do: finite_number?(v) and v > 0.0

  # Largest finite IEEE-754 double; anything strictly beyond is ±Inf, and NaN is
  # the only value with `v != v`. Mirrors `Polar.Lookup` / `Observer.PSquare`.
  @max_finite 1.7976931348623157e308

  defp finite_number?(v) when is_float(v), do: v == v and v <= @max_finite and v >= -@max_finite
  defp finite_number?(v) when is_integer(v), do: true
  defp finite_number?(_), do: false
end
