Code.require_file(Path.expand("../synthetic_helper.exs", __DIR__))

defmodule RacingOrg.Tracker.Pro.Calibration.Estimator.AwaOffsetTest do
  @moduledoc """
  Synthetic-recovery tests for `Estimator.AwaOffset`. These LOCK the sign
  conventions:

    * A vane rotated toward starboard by δ_r reads `awa_meas = awa_true − δ_r`
      (starboard |AWA| LOW, port |AWA| HIGH); the recovered `rotation` estimate is
      the additive correction `+δ_r` — `awa_meas + rotation` restores truth.

    * An upwash ERROR that makes |AWA| read HIGH by δ_u on both tacks
      (`awa_meas = awa_true + δ_u · sign(awa_true)`) recovers `upwash = −δ_u` —
      the side-signed correction `awa + upwash · sign(awa)` restores truth.
  """
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.Calibration.Estimate
  alias RacingOrg.Tracker.Pro.Calibration.Estimator.AwaOffset
  alias RacingOrg.Tracker.Pro.Calibration.Synthetic

  defp observe_pairs(estimator, pairs),
    do: Enum.reduce(pairs, estimator, &AwaOffset.observe_pair(&2, &1))

  defp recover(pair_opts, n) do
    pairs = for _ <- 1..n, do: Synthetic.tack_pair(pair_opts)
    AwaOffset.new() |> observe_pairs(pairs) |> AwaOffset.snapshot()
  end

  # The full correction chain in the locked application order: rotation first,
  # then the side-signed upwash term.
  defp correct(awa_meas, rotation, upwash) do
    rotated = awa_meas + rotation
    sign = if rotated < 0, do: -1.0, else: 1.0
    rotated + upwash * sign
  end

  # Ockam-shaped truth CORRECTION curve for the banded tests: u(V) in degrees,
  # V in m/s, anchored at 6.17 m/s (12 kn). The synthetic vane ERROR that the
  # estimator maps to the correction u is `upwash: -u` (recovered = -injected),
  # so pairs built with `upwash: -truth(v)` recover a curve equal to +truth(v).
  defp truth(v), do: 3.0 - 0.5 * (v - 6.17)

  describe "pure rotation" do
    test "recovers δ_r = 3.0° as +3.0 rotation and ≈ 0 upwash over 10 pairs" do
      %{rotation: rotation, upwash: upwash} = recover([rotation: 3.0], 10)

      assert_in_delta rotation.value, 3.0, 0.2
      assert_in_delta upwash.value, 0.0, 0.2
    end

    test "a port-rotated vane (δ_r = −3.0°) recovers −3.0" do
      %{rotation: rotation, upwash: upwash} = recover([rotation: -3.0], 10)

      assert_in_delta rotation.value, -3.0, 0.2
      assert_in_delta upwash.value, 0.0, 0.2
    end
  end

  describe "pure upwash" do
    test "an |AWA|-reads-high error of δ_u = 2.0° recovers upwash = −2.0 and ≈ 0 rotation" do
      %{rotation: rotation, upwash: upwash} = recover([upwash: 2.0], 10)

      assert_in_delta upwash.value, -2.0, 0.3
      assert_in_delta rotation.value, 0.0, 0.2
    end

    test "the recovered correction restores the true signed AWA on both tacks" do
      %{rotation: rotation, upwash: upwash} = recover([upwash: 2.0], 10)

      truth = Synthetic.tack_pair([])
      measured = Synthetic.tack_pair(upwash: 2.0)

      corrected_stbd = correct(measured.starboard.awa_mean_signed, rotation.value, upwash.value)
      corrected_port = correct(measured.port.awa_mean_signed, rotation.value, upwash.value)

      assert_in_delta corrected_stbd, truth.starboard.awa_mean_signed, 0.35
      assert_in_delta corrected_port, truth.port.awa_mean_signed, 0.35
    end
  end

  describe "combined rotation + upwash (separability)" do
    test "recovers BOTH: rotation 3.0 and upwash −2.0" do
      %{rotation: rotation, upwash: upwash} = recover([rotation: 3.0, upwash: 2.0], 10)

      assert_in_delta rotation.value, 3.0, 0.2
      assert_in_delta upwash.value, -2.0, 0.3
    end

    test "the combined corrections restore the true signed AWA on both tacks" do
      %{rotation: rotation, upwash: upwash} = recover([rotation: 3.0, upwash: 2.0], 10)

      truth = Synthetic.tack_pair([])
      measured = Synthetic.tack_pair(rotation: 3.0, upwash: 2.0)

      corrected_stbd = correct(measured.starboard.awa_mean_signed, rotation.value, upwash.value)
      corrected_port = correct(measured.port.awa_mean_signed, rotation.value, upwash.value)

      assert_in_delta corrected_stbd, truth.starboard.awa_mean_signed, 0.5
      assert_in_delta corrected_port, truth.port.awa_mean_signed, 0.5
    end
  end

  describe "gaussian noise (σ = 0.8° per leg mean, 20 pairs)" do
    test "medians land within 0.4° and both trackers validate" do
      :rand.seed(:exsss, {42, 4242, 424_242})

      pairs = for _ <- 1..20, do: Synthetic.tack_pair(rotation: 3.0, upwash: 2.0, noise_sigma: 0.8)

      %{rotation: rotation, upwash: upwash} =
        AwaOffset.new() |> observe_pairs(pairs) |> AwaOffset.snapshot()

      assert_in_delta rotation.value, 3.0, 0.4
      assert_in_delta upwash.value, -2.0, 0.4
      assert %Estimate{state: :validated} = rotation
      assert %Estimate{state: :validated} = upwash
      assert rotation.sample_count == 20
      assert upwash.sample_count == 20
    end
  end

  describe "learning gate" do
    test "with only 3 pairs both estimates stay :learning and never validate" do
      pairs = for _ <- 1..3, do: Synthetic.tack_pair(rotation: 3.0)

      {_final, states} =
        Enum.reduce(pairs, {AwaOffset.new(), []}, fn pair, {est, acc} ->
          est = AwaOffset.observe_pair(est, pair)
          %{rotation: r, upwash: u} = AwaOffset.snapshot(est)
          {est, [{r.state, u.state} | acc]}
        end)

      assert Enum.all?(states, &(&1 == {:learning, :learning}))
    end
  end

  describe "TWS-banded upwash: curve recovery" do
    test "recovers the Ockam-shaped curve, backbone slope, and rotation simultaneously" do
      :rand.seed(:exsss, {7, 77, 777})

      # 12 pairs per band at TWS 4.5 / 7.0 / 10.5 m/s (bins 5 / 7 / 11),
      # interleaved as rounds like a real day, σ = 0.5° AWA noise per leg mean,
      # with a 2.0° rotation error injected simultaneously.
      pairs =
        for _round <- 1..12, tws <- [4.5, 7.0, 10.5] do
          Synthetic.tack_pair(tws: tws, upwash: -truth(tws), rotation: 2.0, noise_sigma: 0.5)
        end

      snap = AwaOffset.new() |> observe_pairs(pairs) |> AwaOffset.snapshot()

      assert Enum.map(snap.upwash_curve, &elem(&1, 0)) == [5, 7, 11]

      for {center, value} <- snap.upwash_curve do
        assert_in_delta value, truth(center), 0.5
      end

      assert_in_delta snap.upwash_backbone.b, -0.5, 0.15
      assert_in_delta snap.rotation.value, 2.0, 0.2
      assert snap.screened == 0
    end
  end

  describe "TWS-banded upwash: sparse-band pooling" do
    test "a 3-pair band consistent with the backbone publishes via pooling" do
      pairs =
        for _ <- 1..15, do: Synthetic.tack_pair(tws: 7.0, upwash: -truth(7.0))

      sparse =
        for _ <- 1..3, do: Synthetic.tack_pair(tws: 11.0, upwash: -truth(11.0))

      snap = AwaOffset.new() |> observe_pairs(pairs ++ sparse) |> AwaOffset.snapshot()

      # Far below the classic 8-pair gate, yet published through the backbone.
      assert %Estimate{sample_count: 3} = snap.upwash_bands[11]
      assert {11, v11} = List.keyfind(snap.upwash_curve, 11, 0)
      assert_in_delta v11, truth(11.0), 0.7
    end

    test "an adversarial 3-pair band 4° off a published 2-band curve never gets in" do
      base =
        for _ <- 1..12, do: Synthetic.tack_pair(tws: 4.5, upwash: -truth(4.5))

      base =
        base ++ for _ <- 1..15, do: Synthetic.tack_pair(tws: 7.0, upwash: -truth(7.0))

      bad =
        for _ <- 1..3, do: Synthetic.tack_pair(tws: 11.0, upwash: -(truth(11.0) - 4.0))

      snap = AwaOffset.new() |> observe_pairs(base ++ bad) |> AwaOffset.snapshot()

      assert snap.screened == 3
      refute Map.has_key?(snap.upwash_bands, 11)
      assert Enum.map(snap.upwash_curve, &elem(&1, 0)) == [5, 7]
      # The screened raws never reached the global fallback tracker either.
      assert snap.upwash.sample_count == 27
    end
  end

  describe "TWS-banded upwash: single band = legacy behavior" do
    test "one populated band publishes only after the classic ≥ 8-pair gate" do
      pairs = for _ <- 1..10, do: Synthetic.tack_pair(tws: 6.5, upwash: 2.0)

      {_est, curves} =
        Enum.reduce(pairs, {AwaOffset.new(), []}, fn pair, {est, acc} ->
          est = AwaOffset.observe_pair(est, pair)
          {est, [AwaOffset.snapshot(est).upwash_curve | acc]}
        end)

      curves = Enum.reverse(curves)

      assert Enum.all?(Enum.take(curves, 7), &(&1 == []))
      assert [{7, v}] = Enum.at(curves, 7)
      assert_in_delta v, -2.0, 0.3
    end

    test "the single band's tracker matches the global fallback tracker" do
      pairs = for _ <- 1..10, do: Synthetic.tack_pair(tws: 6.5, upwash: 2.0)

      snap = AwaOffset.new() |> observe_pairs(pairs) |> AwaOffset.snapshot()

      assert Map.keys(snap.upwash_bands) == [7]
      assert snap.upwash_bands[7].sample_count == snap.upwash.sample_count
      assert_in_delta snap.upwash_bands[7].value, snap.upwash.value, 1.0e-9

      assert [{7, _v}] = snap.upwash_curve
      assert snap.upwash_backbone.b == 0.0
      assert_in_delta snap.upwash_backbone.a, -2.0, 0.3
    end
  end

  describe "TWS-banded upwash: light-air exclusion (pair TWS < 2 m/s)" do
    test "light-air pairs feed rotation but never the upwash bins or global tracker" do
      pairs = for _ <- 1..5, do: Synthetic.tack_pair(tws: 1.5, rotation: 3.0)

      snap = AwaOffset.new() |> observe_pairs(pairs) |> AwaOffset.snapshot()

      assert snap.rotation.sample_count == 5
      assert_in_delta snap.rotation.value, 3.0, 0.2
      assert snap.upwash.sample_count == 0
      assert snap.upwash_bands == %{}
      assert snap.upwash_curve == []
      assert snap.upwash_backbone == nil
      assert snap.excluded_light == 5
      assert snap.screened == 0
    end
  end

  describe "TWS-banded upwash: shear-day screen" do
    test "a freak pair 6° off a published 2-band curve is rejected everywhere" do
      base =
        for _ <- 1..12, tws <- [4.5, 7.0] do
          Synthetic.tack_pair(tws: tws, upwash: -truth(tws))
        end

      est = observe_pairs(AwaOffset.new(), base)
      before = AwaOffset.snapshot(est)

      assert length(before.upwash_curve) == 2
      assert before.screened == 0

      freak = Synthetic.tack_pair(tws: 7.0, upwash: -(truth(7.0) - 6.0))
      snap = est |> AwaOffset.observe_pair(freak) |> AwaOffset.snapshot()

      assert snap.screened == 1
      assert snap.upwash_curve == before.upwash_curve
      assert snap.upwash.sample_count == before.upwash.sample_count
      assert snap.upwash_bands[7].sample_count == before.upwash_bands[7].sample_count
      # Rotation is never screened.
      assert snap.rotation.sample_count == before.rotation.sample_count + 1
    end
  end

  describe "TWS-banded upwash: pair-TWS fallback" do
    test "nil tws_mean legs fall back to the wind-triangle leg TWS to pick the bin" do
      pairs =
        for _ <- 1..8 do
          pair = Synthetic.tack_pair(tws: 7.0, upwash: 2.0)
          %{pair | starboard: %{pair.starboard | tws_mean: nil}, port: %{pair.port | tws_mean: nil}}
        end

      snap = AwaOffset.new() |> observe_pairs(pairs) |> AwaOffset.snapshot()

      assert Map.keys(snap.upwash_bands) == [7]
      assert [{7, v}] = snap.upwash_curve
      assert_in_delta v, -2.0, 0.3
    end
  end

  describe "input hygiene" do
    test "a pair with inconsistent tack signs is skipped" do
      good = Synthetic.tack_pair(rotation: 3.0)
      # Both slots on the same (port) tack: signed AWA sign does not match the label.
      bad = %{good | starboard: good.port}

      snapshot = AwaOffset.new() |> AwaOffset.observe_pair(bad) |> AwaOffset.snapshot()

      assert snapshot.rotation.sample_count == 0
      assert snapshot.upwash.sample_count == 0
    end

    test "a pair with missing wind data is skipped" do
      good = Synthetic.tack_pair(rotation: 3.0)
      bad = %{good | starboard: %{good.starboard | aws_mean: nil}}

      snapshot = AwaOffset.new() |> AwaOffset.observe_pair(bad) |> AwaOffset.snapshot()

      assert snapshot.rotation.sample_count == 0
      assert snapshot.upwash.sample_count == 0
    end
  end
end
