defmodule RacingOrg.Tracker.Pro.Polar.Lookup do
  @moduledoc """
  Precomputed, fast-to-evaluate interpolant over a `RacingOrg.Tracker.Pro.Polar`.

  The polar is a sparse grid of boat speed sampled at a handful of true wind
  angles (TWA) for a handful of true wind speeds (TWS). On the live compute hot
  path the device needs a *continuous* surface `boat_speed(twa, tws)` evaluated
  on every wind tick, so we precompute a separable, **monotone piecewise-cubic
  Hermite interpolant** (PCHIP, Fritsch–Carlson tangents) ONCE in `build/1` and
  then evaluate it in ~O(log n) bracket + O(1) cubic.

  ## Why PCHIP / Fritsch–Carlson

  Boat-speed polars are shape-sensitive: a wiggle that overshoots between two
  samples invents a speed the boat cannot make, and a kinked derivative makes the
  downstream VMG/target math jitter. PCHIP is chosen because it is

    * **shape-preserving** — it never overshoots, so the surface never produces
      a negative or unphysically-fast speed between nodes; and
    * **C1 continuous** — the tangent is continuous across node boundaries, so a
      VMG search riding the surface sees no derivative jumps.

  Natural cubic / Catmull-Rom splines overshoot, and plain bilinear has a kinked
  derivative — both are rejected here on purpose.

  ## Separability

  The surface is built separably: within each TWS row we interpolate boat speed
  along TWA (a 1-D PCHIP curve), and across TWS we PCHIP-interpolate the *per-TWS
  results* of those curves. Both dimensions use the same Fritsch–Carlson tangent
  rule.

  ## Curve preprocessing (per TWS row)

    1. Take the row's cells, insert an explicit `(0°, 0.0)` anchor, and insert
       the per-TWS beat/run optima as TWA nodes (boat speed recovered from VMG:
       upwind `bsp = beat_vmg / cos(beat_twa)`, downwind
       `bsp = run_vmg / |cos(run_twa)|`), so each curve passes through the true
       optima.
    2. Sort by TWA, drop/merge near-duplicate angles (keeping the optimum value).
    3. Compute Fritsch–Carlson tangents (secant `Δ`, harmonic-mean slope with
       weights `2hₖ+hₖ₋₁` / `hₖ+2hₖ₋₁`, zeroed at sign changes and at the (0,0)
       minimum), clamping the end tangents to 0 at 0° and 180° (the polar is even
       about the wind axis).

  ## TWS handling

  TWS rows are sorted ascending. A query evaluates the TWA curve on the two
  bracketing TWS rows and PCHIP-interpolates across TWS. `tws ≤ 0` clamps to 0.0;
  *above* the top TWS breakpoint the surface holds the top row (no extrapolation)
  and `boat_speed_with_meta/3` flags `extrapolated: true`.

  ## Compiled representation (`t`)

  The compiled `t` is allocation-light and self-contained so the hot path never
  rebuilds and never touches the source `%Polar{}`:

    * `tws` — a tuple of TWS breakpoints (ascending).
    * `curves` — a tuple of compiled TWA curves, one per TWS breakpoint. Each
      curve is `{xs, ys, ms}` where `xs`/`ys`/`ms` are tuples of TWA nodes, node
      speeds, and the per-node Fritsch–Carlson tangents.
    * `optima` — a map holding the per-TWS optima (each a tuple `{tws, beat_twa,
      beat_bsp, beat_vmg, run_twa, run_bsp, run_vmg}`) plus their precomputed
      across-TWS tangents, or `:derive` when the source carried no optima (then
      the optimum is found from the surface).

  The TWA tangents are precomputed (the TWA nodes are fixed per curve). The
  across-TWS tangents for `boat_speed/3`, by contrast, depend on the query TWA
  (they are the Fritsch–Carlson tangents of *that TWA's* per-TWS speed series),
  so they are computed at evaluation time from the (at most four) bracketing
  curve evaluations — still O(1).

  Tuples (not maps/lists) are used throughout the hot path: bracket search is
  `elem/2` indexing, segment evaluation is four FLOPs of the Hermite basis, and
  nothing is allocated per evaluation beyond the returned float.
  """

  alias RacingOrg.Tracker.Pro.Polar

  @enforce_keys [:tws, :curves]
  defstruct tws: {}, curves: {}, optima: :derive, top_tws: 0.0

  @type curve :: {xs :: tuple(), ys :: tuple(), ms :: tuple()}
  @type t :: %__MODULE__{
          tws: tuple(),
          curves: tuple(),
          optima: map() | :derive,
          top_tws: float()
        }

  # Angles within this many degrees are treated as the same TWA node.
  @twa_merge_eps 1.0e-6
  # cos near zero (beam) — guard the VMG -> bsp recovery against blow-up.
  @cos_eps 1.0e-3
  @deg_to_rad :math.pi() / 180.0

  # =====================================================================
  # build/1
  # =====================================================================

  @doc """
  Precompute the interpolant from a `%Polar{}`.

  Returns `{:ok, t}`, or `{:error, reason}` when there is no usable grid (empty
  rows, or every row reduces to fewer than two finite TWA nodes).
  """
  @spec build(Polar.t()) :: {:ok, t()} | {:error, term()}
  def build(%Polar{rows: rows, optima: optima}) do
    optima_by_tws = index_optima(optima)

    compiled =
      rows
      |> Enum.map(&compile_row(&1, optima_by_tws))
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(&elem(&1, 0))
      |> dedup_tws()

    case compiled do
      [] ->
        {:error, :no_usable_rows}

      list ->
        tws = list |> Enum.map(&elem(&1, 0)) |> List.to_tuple()
        curves = list |> Enum.map(&elem(&1, 1)) |> List.to_tuple()

        {:ok,
         %__MODULE__{
           tws: tws,
           curves: curves,
           optima: compile_optima(optima),
           top_tws: elem(tws, tuple_size(tws) - 1)
         }}
    end
  end

  def build(_), do: {:error, :not_a_polar}

  # =====================================================================
  # boat_speed/3 (+ meta)
  # =====================================================================

  @doc """
  The raw interpolated surface speed (m/s) at `twa_deg` / `tws_mps`.

  Returns `:error` for a non-finite query. See the module doc for TWA folding
  and TWS clamping behaviour.
  """
  @spec boat_speed(t(), number(), number()) :: {:ok, float()} | :error
  def boat_speed(%__MODULE__{} = t, twa_deg, tws_mps) do
    case eval(t, twa_deg, tws_mps) do
      {value, _extrapolated} -> {:ok, value}
      :error -> :error
    end
  end

  def boat_speed(_, _, _), do: :error

  @doc """
  Like `boat_speed/3`, but also reports whether the TWS was clamped above the top
  breakpoint (`%{extrapolated: true}` = held-last, low confidence).
  """
  @spec boat_speed_with_meta(t(), number(), number()) ::
          {:ok, float(), %{extrapolated: boolean()}} | :error
  def boat_speed_with_meta(%__MODULE__{} = t, twa_deg, tws_mps) do
    case eval(t, twa_deg, tws_mps) do
      {value, extrapolated} -> {:ok, value, %{extrapolated: extrapolated}}
      :error -> :error
    end
  end

  def boat_speed_with_meta(_, _, _), do: :error

  # =====================================================================
  # optimum/2
  # =====================================================================

  @doc """
  The VMG-optimal beat and run for `tws_mps`.

  When the source polar carried per-TWS optima they are PCHIP-interpolated across
  TWS (and were honored as exact surface nodes). When it carried none, the
  optimum is derived from the surface by maximizing `|bsp·cos(twa)|` over the
  upwind and downwind half (the VMG-tangent fallback).
  """
  @spec optimum(t(), number()) ::
          {:ok,
           %{
             beat: %{twa: float(), bsp: float(), vmg: float()},
             run: %{twa: float(), bsp: float(), vmg: float()}
           }}
          | :error
  def optimum(%__MODULE__{optima: :derive} = t, tws_mps) when is_number(tws_mps) do
    if finite?(tws_mps) do
      tws = max(tws_mps + 0.0, 0.0)
      {:ok, %{beat: derive_optimum(t, tws, :beat), run: derive_optimum(t, tws, :run)}}
    else
      :error
    end
  end

  def optimum(%__MODULE__{optima: optima} = t, tws_mps)
      when is_map(optima) and is_number(tws_mps) do
    if finite?(tws_mps) do
      tws = clamp_tws(t, tws_mps)
      {:ok, interp_optima(t, optima, tws)}
    else
      :error
    end
  end

  def optimum(_, _), do: :error

  # =====================================================================
  # Internal — evaluation (hot path)
  # =====================================================================

  defp eval(%__MODULE__{} = t, twa_deg, tws_mps) do
    cond do
      not finite?(twa_deg) or not finite?(tws_mps) ->
        :error

      true ->
        twa = fold_twa(twa_deg + 0.0)
        eval_folded(t, twa, tws_mps + 0.0)
    end
  end

  # tws <= 0 -> 0.0 everywhere; above top -> hold-last + extrapolated flag.
  # Between 0 and the lowest breakpoint, ramp the lowest row linearly from the
  # implicit (0 m/s TWS -> 0 boat speed) anchor: monotone, never negative, and
  # continuous at both ends (no overshoot from extrapolating below the grid).
  #
  # The final `nonneg/1` clips only the tiny sub-zero numerical overshoot the
  # cubic can produce right at the (0,0) corner — the surface is physical.
  defp eval_folded(%__MODULE__{tws: tws, curves: curves, top_tws: top}, twa, tws_q) do
    n = tuple_size(tws)
    bot = elem(tws, 0)

    {value, extrapolated} =
      cond do
        tws_q <= 0.0 ->
          {0.0, false}

        n == 1 ->
          # Single TWS row: use it for ALL tws > 0 (no TWS interpolation).
          {eval_curve(elem(curves, 0), twa), tws_q > top}

        tws_q < bot ->
          {eval_curve(elem(curves, 0), twa) * (tws_q / bot), false}

        tws_q >= top ->
          {eval_curve(elem(curves, n - 1), twa), tws_q > top}

        true ->
          {interp_across_tws(tws, curves, twa, tws_q, n), false}
      end

    {nonneg(value), extrapolated}
  end

  # PCHIP across the TWS dimension. The across-TWS curve is the per-TWS series of
  # this TWA's boat speed, so its Fritsch–Carlson tangents depend on TWA and are
  # computed here from the bracketing rows (plus one neighbour on each side, when
  # present). This is O(1): at most four curve evaluations.
  defp interp_across_tws(tws, curves, twa, tws_q, n) do
    {i, j, w} = bracket(tws, tws_q, n)

    xi = elem(tws, i)
    xj = elem(tws, j)
    h = xj - xi
    yi = eval_curve(elem(curves, i), twa)
    yj = eval_curve(elem(curves, j), twa)
    d = (yj - yi) / h

    # left neighbour secant (i-1 -> i), if any
    mi =
      if i == 0 do
        end_secant(d)
      else
        xim = elem(tws, i - 1)
        yim = eval_curve(elem(curves, i - 1), twa)
        fc_interior_tangent(xi - xim, h, (yi - yim) / (xi - xim), d)
      end

    # right neighbour secant (j -> j+1), if any
    mj =
      if j == n - 1 do
        end_secant(d)
      else
        xjp = elem(tws, j + 1)
        yjp = eval_curve(elem(curves, j + 1), twa)
        fc_interior_tangent(h, xjp - xj, d, (yjp - yj) / (xjp - xj))
      end

    hermite(yi, yj, mi, mj, h, w)
  end

  # End tangent for the across-TWS curve: a monotone one-sided estimate that
  # never overshoots past the single adjoining secant (Fritsch–Carlson clamp).
  defp end_secant(d) when d == 0.0, do: 0.0
  defp end_secant(d), do: d

  defp nonneg(v) when v < 0.0, do: 0.0
  defp nonneg(v), do: v

  # Evaluate a single compiled TWA curve {xs, ys, ms} at folded twa in [0,180].
  defp eval_curve({xs, ys, ms}, twa) do
    n = tuple_size(xs)
    x0 = elem(xs, 0)
    xn = elem(xs, n - 1)

    cond do
      twa <= x0 -> elem(ys, 0)
      twa >= xn -> elem(ys, n - 1)
      true -> eval_curve_segment(xs, ys, ms, twa, n)
    end
  end

  defp eval_curve_segment(xs, ys, ms, twa, n) do
    {i, j, w} = bracket(xs, twa, n)
    h = elem(xs, j) - elem(xs, i)
    hermite(elem(ys, i), elem(ys, j), elem(ms, i), elem(ms, j), h, w)
  end

  # Cubic Hermite on one segment. `w` is the normalized position (x-x_i)/h in
  # [0,1]; tangents m0/m1 are expressed per-unit-x and scaled by h.
  defp hermite(y0, y1, m0, m1, h, w) do
    w2 = w * w
    w3 = w2 * w
    h00 = 2.0 * w3 - 3.0 * w2 + 1.0
    h10 = w3 - 2.0 * w2 + w
    h01 = -2.0 * w3 + 3.0 * w2
    h11 = w3 - w2
    h00 * y0 + h10 * h * m0 + h01 * y1 + h11 * h * m1
  end

  # Binary search: greatest i with xs[i] <= x (x strictly inside the range).
  # Returns {i, i+1, w} with w = (x - xs[i]) / (xs[i+1] - xs[i]).
  defp bracket(xs, x, n) do
    i = bsearch(xs, x, 0, n - 1)
    xi = elem(xs, i)
    xj = elem(xs, i + 1)
    {i, i + 1, (x - xi) / (xj - xi)}
  end

  defp bsearch(_xs, _x, lo, hi) when hi - lo <= 1, do: lo

  defp bsearch(xs, x, lo, hi) do
    mid = div(lo + hi, 2)

    if elem(xs, mid) <= x do
      bsearch(xs, x, mid, hi)
    else
      bsearch(xs, x, lo, mid)
    end
  end

  # =====================================================================
  # Internal — TWA / TWS folding
  # =====================================================================

  defp fold_twa(twa) when twa < 0.0, do: 0.0
  defp fold_twa(twa) when twa > 180.0, do: fold_twa(360.0 - twa)
  defp fold_twa(twa) when twa > 360.0, do: fold_twa(twa - 360.0)
  defp fold_twa(twa), do: twa

  defp clamp_tws(%__MODULE__{top_tws: top}, tws) do
    tws = max(tws + 0.0, 0.0)
    min(tws, top)
  end

  # =====================================================================
  # Internal — row compilation (build-time)
  # =====================================================================

  defp compile_row(%{tws_mps: tws, cells: cells}, optima_by_tws) when is_number(tws) do
    if finite?(tws) do
      opt = Map.get(optima_by_tws, tws)

      nodes =
        cells
        |> Enum.flat_map(&cell_node/1)
        |> add_anchor()
        |> add_optimum_nodes(opt)
        |> Enum.sort_by(&elem(&1, 0))
        |> merge_dups()

      case build_curve(nodes) do
        nil -> nil
        curve -> {tws + 0.0, curve}
      end
    else
      nil
    end
  end

  defp compile_row(_, _), do: nil

  defp cell_node(%{twa_deg: twa, boat_speed_mps: bsp})
       when is_number(twa) and is_number(bsp) do
    if finite?(twa) and finite?(bsp) and bsp >= 0.0 do
      [{fold_twa(twa + 0.0), bsp + 0.0, :grid}]
    else
      []
    end
  end

  defp cell_node(_), do: []

  defp add_anchor(nodes), do: [{0.0, 0.0, :anchor} | nodes]

  defp add_optimum_nodes(nodes, nil), do: nodes

  defp add_optimum_nodes(nodes, %{beat_twa: btwa, beat_vmg: bvmg, run_twa: rtwa, run_vmg: rvmg}) do
    nodes
    |> maybe_optimum_node(btwa, bvmg)
    |> maybe_optimum_node(rtwa, rvmg)
  end

  defp maybe_optimum_node(nodes, twa, vmg)
       when is_number(twa) and is_number(vmg) do
    if finite?(twa) and finite?(vmg) do
      folded = fold_twa(twa + 0.0)
      c = :math.cos(folded * @deg_to_rad)

      if abs(c) < @cos_eps do
        nodes
      else
        bsp = abs(vmg / c)
        if finite?(bsp) and bsp >= 0.0, do: [{folded, bsp, :optimum} | nodes], else: nodes
      end
    else
      nodes
    end
  end

  defp maybe_optimum_node(nodes, _, _), do: nodes

  # Merge near-duplicate TWA nodes; an optimum node wins over a grid/anchor node.
  defp merge_dups([]), do: []
  defp merge_dups([node]), do: [node]

  defp merge_dups([{x1, _, _} = a, {x2, _, _} = b | rest]) do
    if x2 - x1 < @twa_merge_eps do
      merge_dups([prefer(a, b) | rest])
    else
      [a | merge_dups([b | rest])]
    end
  end

  defp prefer({_, _, :optimum} = a, _), do: a
  defp prefer(_, {_, _, :optimum} = b), do: b
  defp prefer(a, _), do: a

  # Build a compiled curve {xs, ys, ms} from sorted, deduped nodes.
  defp build_curve(nodes) when length(nodes) < 2, do: nil

  defp build_curve(nodes) do
    xs = Enum.map(nodes, &elem(&1, 0))
    ys = Enum.map(nodes, &elem(&1, 1))
    ms = fc_tangents_curve(xs, ys)
    {List.to_tuple(xs), List.to_tuple(ys), List.to_tuple(ms)}
  end

  # =====================================================================
  # Internal — Fritsch–Carlson tangents
  # =====================================================================

  # Tangents for a TWA curve: clamp the end slopes to 0 (even about the wind
  # axis) and zero the slope at the (0,0) minimum.
  defp fc_tangents_curve(xs, ys), do: fc_tangents_for(xs, ys, true)

  # `clamp_ends?` toggles the polar-symmetry end-slope clamping.
  defp fc_tangents_for(xs, ys, clamp_ends?) when length(xs) >= 2 do
    pairs = Enum.zip(xs, ys)
    {hs, deltas} = secants(pairs)
    n = length(xs)

    interior =
      for k <- 1..(n - 2) do
        fc_interior_tangent(Enum.at(hs, k - 1), Enum.at(hs, k), Enum.at(deltas, k - 1), Enum.at(deltas, k))
      end

    {x0_first, y0_first} = List.first(pairs)
    {x0_last, y0_last} = List.last(pairs)

    first = end_tangent(List.first(deltas), clamp_ends?, x0_first, y0_first, :first)
    last = end_tangent(List.last(deltas), clamp_ends?, x0_last, y0_last, :last)

    [first] ++ interior ++ [last]
  end

  defp fc_tangents_for(xs, _ys, _), do: List.duplicate(0.0, length(xs))

  defp secants(pairs) do
    pairs
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [{x0, y0}, {x1, y1}] ->
      h = x1 - x0
      {h, (y1 - y0) / h}
    end)
    |> Enum.unzip()
  end

  # Weighted-harmonic-mean slope; zeroed at extrema (sign change or a zero
  # secant) to suppress overshoot.
  defp fc_interior_tangent(h_prev, h_next, d_prev, d_next) do
    cond do
      d_prev == 0.0 or d_next == 0.0 -> 0.0
      sign(d_prev) != sign(d_next) -> 0.0
      true -> harmonic_slope(h_prev, h_next, d_prev, d_next)
    end
  end

  defp harmonic_slope(h_prev, h_next, d_prev, d_next) do
    w1 = 2.0 * h_next + h_prev
    w2 = h_next + 2.0 * h_prev
    (w1 + w2) / (w1 / d_prev + w2 / d_next)
  end

  # End tangents: clamp to 0 for TWA curves at 0°/180° (polar symmetry) and at a
  # (0,0) minimum; otherwise carry the end secant (a stable one-sided estimate).
  defp end_tangent(_delta, true, x, y, _which) when x == 0.0 and y == 0.0, do: 0.0
  defp end_tangent(_delta, true, x, _y, :first) when x <= 0.0, do: 0.0
  defp end_tangent(_delta, true, x, _y, :last) when x >= 180.0, do: 0.0
  defp end_tangent(delta, _clamp_ends?, _x, _y, _which), do: delta

  defp sign(v) when v > 0.0, do: 1
  defp sign(v) when v < 0.0, do: -1
  defp sign(_), do: 0

  # =====================================================================
  # Internal — optima
  # =====================================================================

  defp index_optima(optima) do
    optima
    |> Enum.filter(&usable_optimum?/1)
    |> Map.new(fn o -> {o.tws_mps, o} end)
  end

  defp usable_optimum?(%{tws_mps: tws, beat_twa: bt, beat_vmg: bv, run_twa: rt, run_vmg: rv}) do
    Enum.all?([tws, bt, bv, rt, rv], &(is_number(&1) and finite?(&1)))
  end

  defp usable_optimum?(_), do: false

  # Compile the optima sequence into a tuple of
  # {tws, beat_twa, beat_bsp, beat_vmg, run_twa, run_bsp, run_vmg} plus the
  # across-TWS tangent tuples, or :derive when there are no usable optima.
  defp compile_optima(optima) do
    usable =
      optima
      |> Enum.filter(&usable_optimum?/1)
      |> Enum.map(&optimum_tuple/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(&elem(&1, 0))
      |> dedup_optima()

    case usable do
      [] ->
        :derive

      list ->
        txs = Enum.map(list, &elem(&1, 0))

        %{
          rows: List.to_tuple(list),
          tws: List.to_tuple(txs),
          beat_twa_m: fc_tangents_field(txs, list, 1),
          beat_bsp_m: fc_tangents_field(txs, list, 2),
          beat_vmg_m: fc_tangents_field(txs, list, 3),
          run_twa_m: fc_tangents_field(txs, list, 4),
          run_bsp_m: fc_tangents_field(txs, list, 5),
          run_vmg_m: fc_tangents_field(txs, list, 6)
        }
    end
  end

  defp optimum_tuple(%{tws_mps: tws, beat_twa: bt, beat_vmg: bv, run_twa: rt, run_vmg: rv}) do
    beat_bsp = vmg_to_bsp(bt, bv)
    run_bsp = vmg_to_bsp(rt, rv)

    if beat_bsp && run_bsp do
      {tws + 0.0, bt + 0.0, beat_bsp, bv + 0.0, rt + 0.0, run_bsp, rv + 0.0}
    else
      nil
    end
  end

  defp vmg_to_bsp(twa, vmg) do
    c = :math.cos(fold_twa(twa + 0.0) * @deg_to_rad)

    if abs(c) < @cos_eps do
      nil
    else
      bsp = abs(vmg / c)
      if finite?(bsp) and bsp >= 0.0, do: bsp, else: nil
    end
  end

  defp dedup_optima([]), do: []
  defp dedup_optima([o]), do: [o]

  defp dedup_optima([a, b | rest]) do
    if abs(elem(b, 0) - elem(a, 0)) < @twa_merge_eps do
      dedup_optima([b | rest])
    else
      [a | dedup_optima([b | rest])]
    end
  end

  defp fc_tangents_field(txs, list, idx) do
    ys = Enum.map(list, &elem(&1, idx))
    fc_tangents_for(txs, ys, false) |> List.to_tuple()
  end

  # Interpolate the provided optima across TWS (PCHIP).
  defp interp_optima(_t, %{rows: rows} = o, tws) do
    n = tuple_size(rows)

    cond do
      n == 1 ->
        format_optimum(elem(rows, 0))

      true ->
        txs = o.tws
        top = elem(txs, n - 1)
        bot = elem(txs, 0)

        cond do
          tws <= bot -> format_optimum(elem(rows, 0))
          tws >= top -> format_optimum(elem(rows, n - 1))
          true -> interp_optima_bracket(o, txs, tws, n)
        end
    end
  end

  defp interp_optima_bracket(o, txs, tws, n) do
    {i, j, w} = bracket(txs, tws, n)
    h = elem(txs, j) - elem(txs, i)
    a = elem(o.rows, i)
    b = elem(o.rows, j)

    btwa = hermite(elem(a, 1), elem(b, 1), elem(o.beat_twa_m, i), elem(o.beat_twa_m, j), h, w)
    bbsp = hermite(elem(a, 2), elem(b, 2), elem(o.beat_bsp_m, i), elem(o.beat_bsp_m, j), h, w)
    bvmg = hermite(elem(a, 3), elem(b, 3), elem(o.beat_vmg_m, i), elem(o.beat_vmg_m, j), h, w)
    rtwa = hermite(elem(a, 4), elem(b, 4), elem(o.run_twa_m, i), elem(o.run_twa_m, j), h, w)
    rbsp = hermite(elem(a, 5), elem(b, 5), elem(o.run_bsp_m, i), elem(o.run_bsp_m, j), h, w)
    rvmg = hermite(elem(a, 6), elem(b, 6), elem(o.run_vmg_m, i), elem(o.run_vmg_m, j), h, w)

    %{
      beat: %{twa: btwa, bsp: bbsp, vmg: bvmg},
      run: %{twa: rtwa, bsp: rbsp, vmg: rvmg}
    }
  end

  defp format_optimum({_tws, btwa, bbsp, bvmg, rtwa, rbsp, rvmg}) do
    %{
      beat: %{twa: btwa, bsp: bbsp, vmg: bvmg},
      run: %{twa: rtwa, bsp: rbsp, vmg: rvmg}
    }
  end

  # Surface-derived optimum (no provided optima): maximize |bsp * cos(twa)| over
  # the upwind (beat) or downwind (run) half.
  defp derive_optimum(%__MODULE__{} = t, tws, half) do
    {lo, hi} =
      case half do
        :beat -> {1.0, 90.0}
        :run -> {90.0, 179.0}
      end

    {twa, bsp, vmg} = golden_max_vmg(t, tws, lo, hi)
    %{twa: twa, bsp: bsp, vmg: vmg}
  end

  # Coarse scan + local golden-section refine for the VMG-maximizing TWA.
  defp golden_max_vmg(t, tws, lo, hi) do
    step = 1.0

    {best_twa, _} =
      lo
      |> Stream.iterate(&(&1 + step))
      |> Stream.take_while(&(&1 <= hi))
      |> Enum.reduce({lo, -1.0}, fn twa, {bt, bv} ->
        v = vmg_at(t, tws, twa)
        if v > bv, do: {twa, v}, else: {bt, bv}
      end)

    a = max(best_twa - step, lo)
    b = min(best_twa + step, hi)
    twa = golden_section(t, tws, a, b)
    bsp = surface_bsp(t, tws, twa)
    {twa, bsp, abs(bsp * :math.cos(twa * @deg_to_rad))}
  end

  defp vmg_at(t, tws, twa) do
    bsp = surface_bsp(t, tws, twa)
    abs(bsp * :math.cos(twa * @deg_to_rad))
  end

  defp surface_bsp(t, tws, twa) do
    {v, _} = eval_folded(t, fold_twa(twa), tws)
    v
  end

  @golden 0.6180339887498949
  defp golden_section(t, tws, a, b, iters \\ 40) do
    do_golden(t, tws, a, b, iters)
  end

  defp do_golden(_t, _tws, a, b, 0), do: (a + b) / 2.0

  defp do_golden(t, tws, a, b, iters) do
    c = b - @golden * (b - a)
    d = a + @golden * (b - a)

    if vmg_at(t, tws, c) > vmg_at(t, tws, d) do
      do_golden(t, tws, a, d, iters - 1)
    else
      do_golden(t, tws, c, b, iters - 1)
    end
  end

  # =====================================================================
  # Internal — misc helpers
  # =====================================================================

  defp dedup_tws([]), do: []
  defp dedup_tws([row]), do: [row]

  defp dedup_tws([{tws1, _} = a, {tws2, _} = b | rest]) do
    if abs(tws2 - tws1) < @twa_merge_eps do
      dedup_tws([a | rest])
    else
      [a | dedup_tws([b | rest])]
    end
  end

  # Largest finite IEEE-754 double; anything strictly beyond is +/-Inf.
  @max_finite 1.7976931348623157e308

  # NaN is the only value with `v != v`; +/-Inf compare outside the finite range.
  defp finite?(v) when is_float(v), do: v == v and v <= @max_finite and v >= -@max_finite
  defp finite?(v) when is_integer(v), do: true
  defp finite?(_), do: false
end
