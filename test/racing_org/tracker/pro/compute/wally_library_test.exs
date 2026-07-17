defmodule RacingOrg.Tracker.Pro.Compute.WallyLibraryTest do
  @moduledoc """
  WALLY modulation of the `target_boat_speed` / `target_twa` library calcs.

  Uses the same hand-computable single-TWS polar fixture as PolarLibraryTest
  (beat optimum twa=45, bsp = 4/cos(45); grid rises to 6.0 m/s at twa=60), so
  the footed/pinched targets are honest polar values at the modulated angle:
  footing (twa > 45, toward the 60-deg node) is FASTER than the optimum bsp,
  pinching (twa < 45) is SLOWER.

  The zero-diff cases assert STRUCTURAL EQUALITY of the whole outputs map
  against a run with no wally signals at all — byte-identical behavior.
  """
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.Compute.Library
  alias RacingOrg.Tracker.Pro.Polar
  alias RacingOrg.Tracker.Pro.Polar.Lookup

  @rad_per_deg :math.pi() / 180.0

  # Exactly the values Lookup's optimum recovery produces (abs(vmg / cos(twa))),
  # so primaries can be compared with == (bit-identical), not just in_delta.
  @base_beat_twa 45.0
  @base_beat_bsp abs(4.0 / :math.cos(45.0 * @rad_per_deg))

  defp single_tws_polar do
    %Polar{
      polar_id: "test",
      version: 1,
      rows: [
        %{
          tws_mps: 10.0,
          cells: [
            %{twa_deg: 45.0, boat_speed_mps: 5.65685},
            %{twa_deg: 60.0, boat_speed_mps: 6.0},
            %{twa_deg: 90.0, boat_speed_mps: 7.0},
            %{twa_deg: 120.0, boat_speed_mps: 6.5},
            %{twa_deg: 150.0, boat_speed_mps: 5.7735},
            %{twa_deg: 180.0, boat_speed_mps: 4.0}
          ]
        }
      ],
      optima: [
        %{tws_mps: 10.0, beat_twa: 45.0, beat_vmg: 4.0, run_twa: 150.0, run_vmg: 5.0}
      ]
    }
  end

  defp lookup do
    {:ok, lk} = Lookup.build(single_tws_polar())
    lk
  end

  defp ctx, do: %{polar_lookup: lookup()}

  # Upwind base signals (twa 40 -> beat leg) with NO wally signals.
  defp base_signals(overrides \\ %{}) do
    Map.merge(%{"true_wind_angle" => 40.0, "true_wind_speed" => 10.0}, overrides)
  end

  # Fully-active wally signal set: oscillating, confident, +8 deg lift.
  defp wally_signals(mode, overrides \\ %{}) do
    Map.merge(
      %{"wally_mode" => mode, "wind_lift_deg" => 8.0, "wind_regime" => 2, "shift_confidence" => 80.0},
      overrides
    )
  end

  defp polar_speed_at(twa) do
    {:ok, bsp} = Lookup.boat_speed(lookup(), twa, 10.0)
    bsp
  end

  describe "mode 2 (on): primaries become the modulated targets" do
    test "lifted (+8 deg): FOOT — target TWA widens by half the shift, speed is the polar at the footed angle" do
      signals = base_signals(wally_signals(2))

      assert {:ok, twa_out} = Library.compute(:target_twa, signals, ctx())
      assert twa_out["target_twa"] == @base_beat_twa + 4.0
      assert twa_out["wally_delta_deg"] == 4.0
      assert twa_out["wally_active"] == 1.0
      # On-mode primaries REPLACE the base; no shadow keys ride along.
      assert Map.keys(twa_out) |> Enum.sort() == ["target_twa", "wally_active", "wally_delta_deg"]

      assert {:ok, bsp_out} = Library.compute(:target_boat_speed, signals, ctx())
      assert bsp_out["target_boat_speed"] == polar_speed_at(49.0)
      # Footing rides the polar's rising side: honestly FASTER than the optimum bsp.
      assert bsp_out["target_boat_speed"] > @base_beat_bsp
      assert bsp_out["wally_delta_deg"] == 4.0
      assert bsp_out["wally_active"] == 1.0
    end

    test "headed (-8 deg): PINCH — target TWA narrows by half the shift, speed is the polar at the pinched angle" do
      signals = base_signals(wally_signals(2, %{"wind_lift_deg" => -8.0}))

      assert {:ok, twa_out} = Library.compute(:target_twa, signals, ctx())
      assert twa_out["target_twa"] == @base_beat_twa - 4.0
      assert twa_out["wally_delta_deg"] == -4.0

      assert {:ok, bsp_out} = Library.compute(:target_boat_speed, signals, ctx())
      assert bsp_out["target_boat_speed"] == polar_speed_at(41.0)
      # Pinching gives up speed for height: honestly SLOWER than the optimum bsp.
      assert bsp_out["target_boat_speed"] < @base_beat_bsp
    end

    test "the delta clamps at 6 deg for a huge shift" do
      signals = base_signals(wally_signals(2, %{"wind_lift_deg" => 20.0}))

      assert {:ok, out} = Library.compute(:target_twa, signals, ctx())
      assert out["target_twa"] == @base_beat_twa + 6.0
      assert out["wally_delta_deg"] == 6.0
    end

    test "port tack (twa -40) modulates the |TWA| target identically (lift is already tack-resolved)" do
      signals = base_signals(wally_signals(2, %{"true_wind_angle" => -40.0}))

      assert {:ok, out} = Library.compute(:target_twa, signals, ctx())
      assert out["target_twa"] == @base_beat_twa + 4.0
    end
  end

  describe "mode 1 (shadow): primaries untouched, wally_* extras ride along" do
    test "primaries are bit-identical to the no-wally run; wally_target_* carry the modulated values" do
      {:ok, plain_twa} = Library.compute(:target_twa, base_signals(), ctx())
      {:ok, plain_bsp} = Library.compute(:target_boat_speed, base_signals(), ctx())

      signals = base_signals(wally_signals(1))

      assert {:ok, twa_out} = Library.compute(:target_twa, signals, ctx())
      assert twa_out["target_twa"] === plain_twa["target_twa"]
      assert twa_out["wally_target_twa"] == @base_beat_twa + 4.0
      assert twa_out["wally_target_boat_speed"] == polar_speed_at(49.0)
      assert twa_out["wally_delta_deg"] == 4.0
      assert twa_out["wally_active"] == 1.0

      assert {:ok, bsp_out} = Library.compute(:target_boat_speed, signals, ctx())
      assert bsp_out["target_boat_speed"] === plain_bsp["target_boat_speed"]
      assert bsp_out["wally_target_twa"] == @base_beat_twa + 4.0
      assert bsp_out["wally_target_boat_speed"] == polar_speed_at(49.0)
      assert bsp_out["wally_delta_deg"] == 4.0
      assert bsp_out["wally_active"] == 1.0
    end
  end

  describe "zero-diff: mode off / inactive gates / missing signals are byte-identical to today" do
    # Every one of these signal overlays must leave BOTH target calcs' whole
    # outputs map STRUCTURALLY EQUAL to a run with no wally signals at all.
    test "the outputs map is structurally equal to the no-wally run" do
      inert_overlays = [
        # Mode off, even with every gate otherwise open.
        wally_signals(0),
        # Mode on but a gate fails: wrong regime / low confidence / inside the deadband.
        wally_signals(2, %{"wind_regime" => 1}),
        wally_signals(2, %{"wind_regime" => 3}),
        wally_signals(2, %{"shift_confidence" => 49.0}),
        wally_signals(2, %{"wind_lift_deg" => 1.9}),
        # Partial signal sets: mode alone, mode + lift only.
        %{"wally_mode" => 2},
        %{"wally_mode" => 2, "wind_lift_deg" => 8.0},
        # No wally signals at all (the trivial identity).
        %{}
      ]

      for key <- [:target_twa, :target_boat_speed] do
        {:ok, plain} = Library.compute(key, base_signals(), ctx())

        for overlay <- inert_overlays do
          assert Library.compute(key, base_signals(overlay), ctx()) == {:ok, plain},
                 "#{key} with overlay #{inspect(overlay)} must be byte-identical to the no-wally run"
        end
      end
    end

    test "downwind (twa 120) is never modulated, even fully lifted and confident (documented deferral)" do
      downwind = %{"true_wind_angle" => 120.0, "true_wind_speed" => 10.0}

      for key <- [:target_twa, :target_boat_speed] do
        {:ok, plain} = Library.compute(key, downwind, ctx())
        assert Library.compute(key, Map.merge(downwind, wally_signals(2)), ctx()) == {:ok, plain}
        refute Map.has_key?(plain, "wally_active")
      end

      # And the base downwind values are the run optimum, untouched.
      {:ok, out} = Library.compute(:target_twa, Map.merge(downwind, wally_signals(2)), ctx())
      assert_in_delta out["target_twa"], 150.0, 1.0e-9
    end

    test "no polar stays :invalid with or without wally signals" do
      assert :invalid = Library.compute(:target_twa, base_signals(wally_signals(2)), %{polar_lookup: nil})
      assert :invalid = Library.compute(:target_boat_speed, base_signals(wally_signals(2)), %{})
    end
  end
end
