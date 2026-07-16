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
