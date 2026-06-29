defmodule RacingOrg.Tracker.Pro.Polar.Observer.PSquareTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.Polar.Observer.PSquare

  # Exact percentile of a list using the "nearest-rank on a linear interpolation"
  # convention that matches what P^2 converges to (the value v such that a
  # fraction p of the data is <= v). We use the simple linear-interpolation
  # (a.k.a. type-7 / "inclusive") estimator over the sorted sample as the gold
  # standard to compare the streaming estimate against.
  defp exact_percentile(values, p) do
    sorted = Enum.sort(values)
    n = length(sorted)
    # type-7 linear interpolation, h = (n-1)*p
    h = (n - 1) * p
    lo = trunc(:math.floor(h))
    hi = trunc(:math.ceil(h))
    v_lo = Enum.at(sorted, lo)
    v_hi = Enum.at(sorted, hi)
    v_lo + (h - lo) * (v_hi - v_lo)
  end

  # Deterministic PRNG (xorshift64*) so the convergence numbers are reproducible.
  defp prng(seed), do: seed

  defp next(state) do
    x = state
    x = Bitwise.bxor(x, Bitwise.bsr(x, 12))
    x = Bitwise.bxor(x, Bitwise.band(Bitwise.bsl(x, 25), 0xFFFFFFFFFFFFFFFF))
    x = Bitwise.bxor(x, Bitwise.bsr(x, 27))
    x = Bitwise.band(x, 0xFFFFFFFFFFFFFFFF)
    u = Bitwise.band(x * 0x2545F4914F6CDD1D, 0xFFFFFFFFFFFFFFFF) / 0x10000000000000000
    {u, x}
  end

  # Draw n uniform(0,1) values from the deterministic stream, returning the list.
  defp uniform_stream(n, seed) do
    {vals, _} =
      Enum.map_reduce(1..n, prng(seed), fn _, st ->
        {u, st} = next(st)
        {u, st}
      end)

    vals
  end

  # Box-Muller normal(mean, sd) from the uniform stream.
  defp normal_stream(n, seed, mean, sd) do
    us = uniform_stream(2 * n, seed)

    us
    |> Enum.chunk_every(2)
    |> Enum.map(fn [u1, u2] ->
      u1 = max(u1, 1.0e-12)
      z = :math.sqrt(-2.0 * :math.log(u1)) * :math.cos(2.0 * :math.pi() * u2)
      mean + sd * z
    end)
    |> Enum.take(n)
  end

  # Exponential(rate) via inverse-CDF from the uniform stream.
  defp exponential_stream(n, seed, rate) do
    n
    |> uniform_stream(seed)
    |> Enum.map(fn u ->
      u = max(u, 1.0e-12)
      -:math.log(u) / rate
    end)
  end

  defp feed(values, p) do
    Enum.reduce(values, PSquare.new(p), &PSquare.add(&2, &1))
  end

  describe "new/1 and value/1 before 5 samples" do
    test "value is nil with no samples" do
      assert PSquare.value(PSquare.new(0.9)) == nil
    end

    test "with 1..4 samples returns an order-statistic estimate from the buffer" do
      # For a small buffer, the estimate is the p-th order statistic of what we've
      # seen so far (so it is always one of the observed values / in-range).
      est1 = PSquare.new(0.9) |> PSquare.add(7.0) |> PSquare.value()
      assert est1 == 7.0

      vals = [3.0, 1.0, 4.0, 2.0]
      est4 = feed(vals, 0.9) |> PSquare.value()
      assert est4 >= 1.0 and est4 <= 4.0
      # 90th percentile of 4 sorted values [1,2,3,4] should be at/near the top.
      assert est4 >= 3.0
    end

    test "exactly 5 samples returns the running estimate (q[2] after init)" do
      vals = [5.0, 1.0, 3.0, 2.0, 4.0]
      est = feed(vals, 0.5) |> PSquare.value()
      # median of [1,2,3,4,5] is 3.0
      assert_in_delta est, 3.0, 1.0e-9
    end
  end

  describe "convergence to true quantile (large N)" do
    test "uniform(0,1) p=0.90" do
      vals = uniform_stream(100_000, 0x1234_5678_9ABC_DEF0)
      est = feed(vals, 0.90) |> PSquare.value()
      exact = exact_percentile(vals, 0.90)
      # true 90th percentile of U(0,1) is 0.90
      assert_in_delta est, 0.90, 0.01
      assert_in_delta est, exact, 0.01
    end

    test "uniform(0,1) p=0.50 (median)" do
      vals = uniform_stream(100_000, 0x0F0F_0F0F_0F0F_0F0F)
      est = feed(vals, 0.50) |> PSquare.value()
      exact = exact_percentile(vals, 0.50)
      assert_in_delta est, 0.50, 0.01
      assert_in_delta est, exact, 0.01
    end

    test "uniform(0,1) p=0.99 (tail)" do
      vals = uniform_stream(200_000, 0xDEAD_BEEF_CAFE_F00D)
      est = feed(vals, 0.99) |> PSquare.value()
      exact = exact_percentile(vals, 0.99)
      assert_in_delta est, exact, 0.01
    end

    test "normal(10, 2) p=0.90" do
      vals = normal_stream(100_000, 0xABCD_0123_4567_89EF, 10.0, 2.0)
      est = feed(vals, 0.90) |> PSquare.value()
      exact = exact_percentile(vals, 0.90)
      # true 90th percentile of N(10,2) ~= 10 + 1.2816*2 = 12.563
      assert_in_delta est, 12.563, 0.1
      assert_in_delta est, exact, 0.1
    end

    test "exponential(rate=1) p=0.90" do
      vals = exponential_stream(100_000, 0x5555_AAAA_5555_AAAA, 1.0)
      est = feed(vals, 0.90) |> PSquare.value()
      exact = exact_percentile(vals, 0.90)
      # true 90th percentile of Exp(1) = -ln(0.1) ~= 2.3026
      assert_in_delta est, 2.3026, 0.1
      assert_in_delta est, exact, 0.1
    end
  end

  describe "constant memory / bounded state" do
    test "internal state size does not grow with sample count" do
      small = feed(uniform_stream(10, 1), 0.9)
      large = feed(uniform_stream(50_000, 1), 0.9)
      huge = feed(uniform_stream(500_000, 1), 0.9)
      # term_to_binary size is a proxy for retained memory; P^2 keeps 5 markers
      # regardless of how many samples were fed. The only thing that can grow is
      # the magnitude of the integer position/count counters (a few bytes), NOT
      # the number of retained terms — so the footprint is bounded by a small
      # constant and a 50x larger stream costs at most a handful of extra bytes.
      small_bytes = byte_size(:erlang.term_to_binary(small))
      large_bytes = byte_size(:erlang.term_to_binary(large))
      huge_bytes = byte_size(:erlang.term_to_binary(huge))

      # Bounded: 10x and 100x more data than `large` adds essentially nothing.
      assert huge_bytes - large_bytes <= 16
      assert large_bytes - small_bytes <= 32
      # And the whole thing is tiny (5 markers x ~4 fields of floats/ints).
      assert huge_bytes < 400
    end

    test "order is robust: shuffled stream gives essentially same estimate" do
      base = uniform_stream(20_000, 42)
      shuffled = Enum.shuffle(base)
      e1 = feed(base, 0.9) |> PSquare.value()
      e2 = feed(shuffled, 0.9) |> PSquare.value()
      # P^2 is order-sensitive but should land close for a stationary stream.
      assert_in_delta e1, e2, 0.02
    end
  end

  describe "degenerate inputs" do
    test "all-equal stream returns that value" do
      est = feed(List.duplicate(3.5, 1000), 0.9) |> PSquare.value()
      assert_in_delta est, 3.5, 1.0e-9
    end

    test "monotone increasing stream still tracks the quantile" do
      vals = Enum.map(1..10_000, &(&1 / 1.0))
      est = feed(vals, 0.90) |> PSquare.value()
      exact = exact_percentile(vals, 0.90)
      assert_in_delta est, exact, 50.0
    end
  end
end
