defmodule RacingOrg.Tracker.Pro.Polar.Observer.PSquare do
  @moduledoc """
  Streaming single-quantile estimator using the **P² (P-square) algorithm** of
  Jain & Chlamtac (1985).

  P² estimates a fixed quantile `p` (e.g. the 0.90 boat-speed percentile of a
  binned sailing cell) in **O(1) time per sample and constant memory**: it keeps
  only **five markers** — never the observations — and updates them online as
  each sample arrives. This is exactly what the observational ("sailed") polar
  needs: each (TWS, TWA) cell holds one of these estimators plus a count, so the
  per-cell memory is bounded no matter how long the boat sails.

  ## State

  Five markers, each with a height `q[i]` (the marker's current value estimate),
  an actual position `n[i]` (1-indexed rank among the samples seen), a desired
  position `np[i]`, and a per-sample desired-position increment `dnp[i]`:

      np  = [1, 1 + 2p, 1 + 4p, 3 + 2p, 5]
      dnp = [0, p/2,    p,      (1+p)/2, 1]
      n   = [1, 2, 3, 4, 5]

  The marker heights are initialized from the **first five samples sorted**.
  Marker 0 tracks the running min, marker 4 the running max, and marker 2 (the
  middle marker) carries the quantile estimate once ≥ 5 samples have been seen.

  ## Per-sample update (after the 5th sample)

    1. Find the cell `k` the new sample `x` falls in; if `x` is a new min/max,
       extend `q[0]` / `q[4]` and clamp `k` to the end cell.
    2. Increment the actual position `n[i]` for every marker above the cell, and
       advance every desired position `np[i] += dnp[i]`.
    3. For each interior marker `i ∈ {1, 2, 3}`, if its desired position has
       drifted at least one full rank from its actual position (and there is room
       to move), shift it by one rank using the **piecewise-parabolic (P²)
       prediction**, falling back to a **linear** prediction if the parabola
       would leave the bracketing markers' order.

  ## Before five samples

  `value/1` returns `nil` with no samples, and for 1–4 buffered samples returns
  the `p`-th **order statistic** of the buffered values (the closest available
  estimate before the markers exist). From the 5th sample on it returns `q[2]`.

  ## References

    * R. Jain & I. Chlamtac, *The P² Algorithm for Dynamic Calculation of
      Quantiles and Histograms Without Storing Observations*, CACM 28(10), 1985.
    * A. Akinshin, "P² quantile estimator" (aakinshin.net) — derivation/writeup.
  """

  @enforce_keys [:p]
  defstruct p: 0.9,
            count: 0,
            # buffer of the first <5 samples (kept sorted), then dropped
            buffer: [],
            # marker heights q[0..4] (tuple of 5 floats) once initialized
            q: nil,
            # actual positions n[0..4] (tuple of 5 ints/floats)
            n: nil,
            # desired positions np[0..4] (tuple of 5 floats)
            np: nil,
            # desired-position increments dnp[0..4] (tuple of 5 floats)
            dnp: nil

  @type t :: %__MODULE__{
          p: float(),
          count: non_neg_integer(),
          buffer: [float()],
          q: tuple() | nil,
          n: tuple() | nil,
          np: tuple() | nil,
          dnp: tuple() | nil
        }

  @doc """
  Build a fresh estimator for quantile `p` (default `0.90`), `0.0 < p < 1.0`.
  """
  @spec new(float()) :: t()
  def new(p \\ 0.9) when is_number(p) and p > 0.0 and p < 1.0 do
    %__MODULE__{p: p + 0.0}
  end

  @doc """
  Fold a new observation `x` into the estimator in O(1). Non-finite values are
  ignored (returned unchanged).
  """
  @spec add(t(), number()) :: t()
  def add(%__MODULE__{} = t, x) when is_number(x) do
    if finite?(x), do: do_add(t, x + 0.0), else: t
  end

  @doc """
  The current quantile estimate: `nil` until at least one sample, the buffered
  order statistic for 1–4 samples, and the running `q[2]` marker from the 5th
  sample on.
  """
  @spec value(t()) :: float() | nil
  def value(%__MODULE__{count: 0}), do: nil
  def value(%__MODULE__{q: nil, buffer: buf, p: p}), do: order_statistic(buf, p)
  def value(%__MODULE__{q: q}), do: elem(q, 2)

  @doc "Number of samples folded in so far."
  @spec count(t()) :: non_neg_integer()
  def count(%__MODULE__{count: c}), do: c

  # =====================================================================
  # Internal
  # =====================================================================

  # Phase 1: still buffering the first five samples.
  defp do_add(%__MODULE__{q: nil, buffer: buf, count: c} = t, x) do
    buffer = Enum.sort([x | buf])

    if c + 1 == 5 do
      initialize(%{t | count: 5}, buffer)
    else
      %{t | buffer: buffer, count: c + 1}
    end
  end

  # Phase 2: markers exist; do the P² update.
  defp do_add(%__MODULE__{} = t, x) do
    update(t, x)
  end

  # Initialize markers from the 5 sorted samples.
  defp initialize(%__MODULE__{p: p} = t, [s0, s1, s2, s3, s4]) do
    %{
      t
      | buffer: [],
        q: {s0, s1, s2, s3, s4},
        n: {1, 2, 3, 4, 5},
        np: {1.0, 1.0 + 2.0 * p, 1.0 + 4.0 * p, 3.0 + 2.0 * p, 5.0},
        dnp: {0.0, p / 2.0, p, (1.0 + p) / 2.0, 1.0}
    }
  end

  defp update(%__MODULE__{q: q, n: n, np: np, dnp: dnp, count: c} = t, x) do
    {q, k} = find_cell(q, x)

    # Step B: bump actual positions above the cell, advance all desired positions.
    n = bump_positions(n, k)
    np = advance_desired(np, dnp)

    # Step C: adjust the three interior markers if they've drifted a full rank.
    {q, n} = adjust_interior(q, n, np)

    %{t | q: q, n: n, np: np, count: c + 1}
  end

  # Locate the cell index k for x, extending the min/max marker if x is outside
  # the current [q0, q4] range. Returns {possibly-updated q, k} where k ∈ 0..3
  # meaning x lands in [q[k], q[k+1]).
  defp find_cell(q, x) do
    q0 = elem(q, 0)
    q4 = elem(q, 4)

    cond do
      x < q0 -> {put_elem(q, 0, x), 0}
      x >= q4 -> {put_elem(q, 4, x), 3}
      x < elem(q, 1) -> {q, 0}
      x < elem(q, 2) -> {q, 1}
      x < elem(q, 3) -> {q, 2}
      true -> {q, 3}
    end
  end

  # n[i] += 1 for i > k (markers above the cell shift up by one rank).
  defp bump_positions(n, k) do
    Enum.reduce((k + 1)..4, n, fn i, acc -> put_elem(acc, i, elem(acc, i) + 1) end)
  end

  # np[i] += dnp[i] for all markers.
  defp advance_desired(np, dnp) do
    Enum.reduce(0..4, np, fn i, acc -> put_elem(acc, i, elem(acc, i) + elem(dnp, i)) end)
  end

  # For each interior marker i ∈ {1,2,3}, move it ONE rank toward its desired
  # position when the desired/actual gap `d = np[i] - n[i]` has reached a full
  # rank AND there is room on that side (n[i+1]-n[i] > 1 going up, or
  # n[i-1]-n[i] < -1 going down). The new height comes from the parabolic (P²)
  # prediction, falling back to linear if the parabola breaks the marker order.
  defp adjust_interior(q, n, np) do
    Enum.reduce(1..3, {q, n}, fn i, {q, n} ->
      d = elem(np, i) - elem(n, i)

      cond do
        d >= 1.0 and elem(n, i + 1) - elem(n, i) > 1 -> shift_marker(q, n, i, 1)
        d <= -1.0 and elem(n, i - 1) - elem(n, i) < -1 -> shift_marker(q, n, i, -1)
        true -> {q, n}
      end
    end)
  end

  # Shift marker i by ds (∈ {-1, +1}): pick the parabolic height if it stays
  # strictly between the neighbouring marker heights, else the linear height;
  # then n[i] += ds.
  defp shift_marker(q, n, i, ds) do
    qi = elem(q, i)
    qim = elem(q, i - 1)
    qip = elem(q, i + 1)
    ni = elem(n, i)
    nim = elem(n, i - 1)
    nip = elem(n, i + 1)

    parab = parabolic(qi, qim, qip, ni, nim, nip, ds)

    new_qi =
      if qim < parab and parab < qip do
        parab
      else
        linear(q, n, i, ds)
      end

    {put_elem(q, i, new_qi), put_elem(n, i, ni + ds)}
  end

  # Piecewise-parabolic prediction (Jain & Chlamtac eq. for q'_i).
  defp parabolic(qi, qim, qip, ni, nim, nip, ds) do
    qi +
      ds / (nip - nim) *
        ((ni - nim + ds) * (qip - qi) / (nip - ni) +
           (nip - ni - ds) * (qi - qim) / (ni - nim))
  end

  # Linear prediction toward the neighbour in direction ds.
  defp linear(q, n, i, ds) do
    qi = elem(q, i)
    ni = elem(n, i)
    qn = elem(q, i + ds)
    nn = elem(n, i + ds)
    qi + ds * (qn - qi) / (nn - ni)
  end

  # Largest finite IEEE-754 double; anything strictly beyond is ±Inf, and NaN is
  # the only value with `v != v`.
  @max_finite 1.7976931348623157e308
  defp finite?(v) when is_float(v), do: v == v and v <= @max_finite and v >= -@max_finite
  defp finite?(v) when is_integer(v), do: true
  defp finite?(_), do: false

  # p-th order statistic of a sorted-or-unsorted small buffer (nearest-rank,
  # 1-indexed: ceil(p * n)).
  defp order_statistic([], _p), do: nil

  defp order_statistic(buf, p) do
    sorted = Enum.sort(buf)
    n = length(sorted)
    rank = max(1, min(n, trunc(:math.ceil(p * n))))
    Enum.at(sorted, rank - 1)
  end
end
