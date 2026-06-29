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

  Domain clamps:

    * TWS `≤ 0` clamps to bin `0` (no negative wind).
    * The TWA top edge `180°` clamps into the last bin (`floor(180/5) = 36`
      would be an out-of-range singleton; it is folded into bin `35`, the
      `[175, 180]` interval) so the closed top of the domain never spawns an
      empty bin.

  This is the SECONDARY (observed) plane; it is independent of the reference
  polar's irregular TWS rows / TWA cells in `RacingOrg.Tracker.Pro.Polar`.
  """

  # 1 knot in metres/second — the default TWS bin width.
  @knot_mps 0.514444
  @default_twa_width_deg 5.0

  @enforce_keys [:twa_width_deg, :tws_width_mps]
  defstruct twa_width_deg: @default_twa_width_deg, tws_width_mps: @knot_mps

  @type t :: %__MODULE__{twa_width_deg: float(), tws_width_mps: float()}
  @type key :: {non_neg_integer(), non_neg_integer()}

  @doc """
  Build a binning config.

  Options:

    * `:twa_width_deg` — TWA bin width in degrees (default `5.0`).
    * `:tws_width_mps` — TWS bin width in **m/s** (default `0.514444`, i.e.
      1 knot).
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    twa = Keyword.get(opts, :twa_width_deg, @default_twa_width_deg)
    tws = Keyword.get(opts, :tws_width_mps, @knot_mps)

    unless is_number(twa) and twa > 0.0, do: raise(ArgumentError, "twa_width_deg must be > 0")
    unless is_number(tws) and tws > 0.0, do: raise(ArgumentError, "tws_width_mps must be > 0")

    %__MODULE__{twa_width_deg: twa + 0.0, tws_width_mps: tws + 0.0}
  end

  @doc "1 knot expressed in m/s (the default TWS bin width)."
  @spec knot_mps() :: float()
  def knot_mps, do: @knot_mps

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
  Canonical cell key `{tws_idx, twa_idx}` for a `(tws_mps, twa_deg)` sample.

  TWA is folded to `[0, 180]` first. TWS `≤ 0` clamps to bin `0`; the TWA top
  edge clamps into the last bin (see the module doc).
  """
  @spec cell(t(), number(), number()) :: key()
  def cell(%__MODULE__{tws_width_mps: tw, twa_width_deg: aw}, tws_mps, twa_deg)
      when is_number(tws_mps) and is_number(twa_deg) do
    twa = fold_twa(twa_deg)
    {tws_index(tws_mps, tw), twa_index(twa, aw)}
  end

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

  defp tws_index(tws_mps, _width) when tws_mps <= 0.0, do: 0
  defp tws_index(tws_mps, width), do: floor_div(tws_mps, width)

  # TWA is already folded to [0, 180]. floor(180/width) is the out-of-range top
  # edge; clamp it down by one so the closed top of the domain shares the last
  # bin instead of spawning an empty singleton.
  defp twa_index(twa, width) do
    max_idx = trunc(:math.ceil(180.0 / width)) - 1
    min(floor_div(twa, width), max_idx)
  end

  defp floor_div(v, width), do: trunc(:math.floor(v / width))
end
