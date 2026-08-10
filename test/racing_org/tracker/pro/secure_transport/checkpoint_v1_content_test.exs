defmodule RacingOrg.Tracker.Pro.SecureTransport.CheckpointV1ContentTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1, as: Contract
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.Canonical
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.Checkpoint

  describe "closed checkpoint content schemas" do
    test "caps canonical content at the single-frame hydration boundary" do
      assert Contract.max_checkpoint_size() == 65_327

      oversized = :binary.copy(<<0>>, Contract.max_checkpoint_size() + 1)

      assert {:error, :checkpoint_too_large} =
               Checkpoint.decode_content(:polar, 1, oversized)
    end

    test "rejects finite calibration timestamps whose span overflows" do
      max_finite = 1.7976931348623157e308
      content = calibration_checkpoint()
      [upwind, reach, downwind] = content["aws_estimators"] |> hd() |> Map.fetch!("regimes")

      overflowing_regimes = [
        put_in(upwind, ["legs", Access.at(0), "t_end_s"], max_finite),
        put_in(reach, ["legs", Access.at(0), "t_end_s"], 0.0),
        put_in(downwind, ["legs", Access.at(0), "t_end_s"], -max_finite)
      ]

      regimes_path = ["aws_estimators", Access.at(0), "regimes"]
      overflowing = put_in(content, regimes_path, overflowing_regimes)

      assert {:ok, bytes} = Canonical.encode(overflowing)

      assert {:error, :invalid_checkpoint_content} =
               Checkpoint.decode_content(:calibration, 1, bytes)
    end

    test "round-trips exact nonempty calibration and wind-shift learner state" do
      for {kind, content} <- [
            calibration: calibration_checkpoint(),
            wind_shift: wind_shift_checkpoint()
          ] do
        assert {:ok, bytes} = Checkpoint.encode_content(kind, 1, content)
        assert {:ok, ^content} = Checkpoint.decode_content(kind, 1, bytes)
      end
    end

    test "preserves exact event order while extrema do not affect the append watermark" do
      content = wind_shift_checkpoint()
      events = content["pending_events"]
      newer_current = Enum.find(events, &(&1["kind"] == "regime_change"))

      delayed_extreme =
        events
        |> Enum.find(&(&1["kind"] == "lift_extreme"))
        |> Map.put("t_ms", content["session"]["started_at_ms"] + 20_000)

      future_extreme = Enum.find(events, &(&1["kind"] == "header_extreme"))

      next_current =
        events
        |> Enum.find(&(&1["kind"] == "new_high"))
        |> Map.put("t_ms", content["session"]["started_at_ms"] + 40_000)

      ordered_events = [newer_current, delayed_extreme, future_extreme, next_current]
      content = %{content | "pending_events" => ordered_events}

      assert Enum.map(ordered_events, & &1["t_ms"]) == [
               content["session"]["started_at_ms"] + 30_000,
               content["session"]["started_at_ms"] + 20_000,
               content["session"]["started_at_ms"] + 50_000,
               content["session"]["started_at_ms"] + 40_000
             ]

      assert {:ok, bytes} = Checkpoint.encode_content(:wind_shift, 1, content)
      assert {:ok, ^content} = Checkpoint.decode_content(:wind_shift, 1, bytes)
    end

    test "rejects a non-extreme event that regresses behind the append watermark" do
      content = wind_shift_checkpoint()
      events = content["pending_events"]

      newer_current =
        events
        |> Enum.find(&(&1["kind"] == "new_high"))
        |> Map.put("t_ms", content["session"]["started_at_ms"] + 40_000)

      delayed_extreme =
        events
        |> Enum.find(&(&1["kind"] == "lift_extreme"))
        |> Map.put("t_ms", content["session"]["started_at_ms"] + 20_000)

      older_current = Enum.find(events, &(&1["kind"] == "regime_change"))
      invalid = %{content | "pending_events" => [newer_current, delayed_extreme, older_current]}

      assert {:error, :invalid_checkpoint_content} =
               Checkpoint.encode_content(:wind_shift, 1, invalid)
    end

    test "rejects structurally impossible P-square and polar cell state" do
      content = polar_checkpoint()
      [cell] = content["cells"]

      assert {:error, :invalid_checkpoint_content} =
               Checkpoint.encode_content(
                 :polar,
                 1,
                 put_in(content, ["cells"], [%{cell | "count" => 6}])
               )

      invalid_quantile = put_in(cell, ["quantile", "q"], [1.0, 4.0, 3.0, 2.0, 5.0])

      assert {:error, :invalid_checkpoint_content} =
               Checkpoint.encode_content(
                 :polar,
                 1,
                 put_in(content, ["cells"], [invalid_quantile])
               )

      duplicate = %{cell | "twa_bin" => 46}

      assert {:error, :invalid_checkpoint_content} =
               Checkpoint.encode_content(:polar, 1, %{"cells" => [duplicate, cell]})
    end

    test "rejects impossible calibration counters and open wind-shift event details" do
      calibration = calibration_checkpoint()
      [awa] = calibration["awa_estimators"]
      impossible_awa = %{awa | "pairs_seen" => awa["pairs_seen"] + 1}

      assert {:error, :invalid_checkpoint_content} =
               Checkpoint.encode_content(
                 :calibration,
                 1,
                 %{calibration | "awa_estimators" => [impossible_awa]}
               )

      wind_shift = wind_shift_checkpoint()
      [event | rest] = wind_shift["pending_events"]
      open_detail = put_in(event, ["detail", "arbitrary"], 1.0)

      assert {:error, :invalid_checkpoint_content} =
               Checkpoint.encode_content(
                 :wind_shift,
                 1,
                 %{wind_shift | "pending_events" => [open_detail | rest]}
               )

      noncanonical_direction = %{event | "twd_deg" => 360.0}

      assert {:error, :invalid_checkpoint_content} =
               Checkpoint.encode_content(
                 :wind_shift,
                 1,
                 %{wind_shift | "pending_events" => [noncanonical_direction | rest]}
               )

      noncanonical_summary = put_in(wind_shift, ["last_summary", "mean_twd_deg"], 360.0)

      assert {:error, :invalid_checkpoint_content} =
               Checkpoint.encode_content(:wind_shift, 1, noncanonical_summary)

      [timeline] = wind_shift["pending_timeline"]
      noncanonical_phase = %{timeline | "phase_deg" => 180.0}

      assert {:error, :invalid_checkpoint_content} =
               Checkpoint.encode_content(
                 :wind_shift,
                 1,
                 %{wind_shift | "pending_timeline" => [noncanonical_phase]}
               )

      secret_capable = put_in(event, ["detail", "payload"], "synthetic-noncredential")

      assert {:error, :checkpoint_secret_forbidden} =
               Checkpoint.encode_content(
                 :wind_shift,
                 1,
                 %{wind_shift | "pending_events" => [secret_capable | rest]}
               )
    end

    test "rejects step event onset before the bound session" do
      wind_shift = wind_shift_checkpoint()
      started_at_ms = wind_shift["session"]["started_at_ms"]
      [first, step | rest] = wind_shift["pending_events"]
      pre_session_step = put_in(step, ["detail", "onset_t_ms"], started_at_ms - 1)
      invalid = %{wind_shift | "pending_events" => [first, pre_session_step | rest]}

      assert {:error, :invalid_checkpoint_content} =
               Checkpoint.encode_content(:wind_shift, 1, invalid)
    end

    test "fails closed on malformed containers and noncanonical sensor identities" do
      assert {:error, :invalid_checkpoint_content} =
               Checkpoint.encode_content(:polar, 1, %{<<0xFF>> => []})

      [cell] = polar_checkpoint()["cells"]

      assert {:error, :invalid_checkpoint_content} =
               Checkpoint.encode_content(:polar, 1, %{"cells" => [cell | :improper]})

      assert {:error, :checkpoint_secret_forbidden} =
               Checkpoint.encode_content(:polar, 1, %{
                 "cells" => [cell | :improper],
                 "payload" => "synthetic-noncredential"
               })

      calibration = calibration_checkpoint()
      [awa] = calibration["awa_estimators"]
      [aws] = calibration["aws_estimators"]

      assert {:error, :invalid_checkpoint_content} =
               Checkpoint.encode_content(
                 :calibration,
                 1,
                 %{calibration | "aws_estimators" => [%{aws | "regimes" => [1, 2, 3]}]}
               )

      assert {:error, :invalid_checkpoint_content} =
               Checkpoint.encode_content(
                 :calibration,
                 1,
                 %{
                   calibration
                   | "awa_estimators" => [%{awa | "hardware_identifier" => "wifi-password"}]
                 }
               )

      assert {:error, :invalid_checkpoint_content} =
               Checkpoint.encode_content(
                 :calibration,
                 1,
                 %{
                   calibration
                   | "awa_estimators" => [%{awa | "hardware_identifier" => <<0xFF>>}]
                 }
               )
    end
  end

  defp calibration_checkpoint do
    awa_tracker =
      estimate_tracker(max_spread: 2.0, clamp_min: -10.0, clamp_max: 10.0, max_slew: 0.5)

    light_awa_tracker =
      estimate_tracker(
        min_samples: 6,
        max_spread: 3.0,
        max_drift: 1.5,
        clamp_min: -10.0,
        clamp_max: 10.0,
        max_slew: 0.5
      )

    stw_tracker = estimate_tracker(min_samples: 6, max_spread: 0.04, max_drift: 0.02)

    %{
      "awa_estimators" => [
        %{
          "bands" => %{
            "band_tracker_options" =>
              estimate_options(
                max_spread: 2.0,
                max_drift: 1.0,
                clamp_min: -10.0,
                clamp_max: 10.0,
                max_slew: 0.5
              ),
            "bands" => [%{"center_mps" => 3, "tracker" => light_awa_tracker}],
            "clamp_max" => 10.0,
            "clamp_min" => -10.0,
            "classic_max_spread" => 2.0,
            "classic_min_samples" => 8,
            "excluded_light" => 0,
            "light_band_tracker_options" =>
              estimate_options(
                min_samples: 6,
                max_spread: 3.0,
                max_drift: 1.5,
                clamp_min: -10.0,
                clamp_max: 10.0,
                max_slew: 0.5
              ),
            "screened" => 0
          },
          "hardware_identifier" => "1A2B",
          "pairs_seen" => 5,
          "pairs_skipped" => 0,
          "rotation" => awa_tracker,
          "upwash" => awa_tracker
        }
      ],
      "aws_estimators" => [
        %{
          "hardware_identifier" => "1A2B",
          "legs_seen" => 3,
          "legs_skipped" => 0,
          "min_legs" => 3,
          "ratio" => fresh_estimate_tracker(max_spread: 0.15, max_drift: 0.075),
          "regimes" => [
            %{"legs" => [%{"t_end_s" => -100.0, "tws_mps" => 5.0}], "name" => "upwind"},
            %{"legs" => [%{"t_end_s" => -150.0, "tws_mps" => 5.2}], "name" => "reach"},
            %{"legs" => [%{"t_end_s" => -200.0, "tws_mps" => 5.1}], "name" => "downwind"}
          ],
          "window_s" => 7_200.0
        }
      ],
      "prev_applied" => [
        %{"hardware_identifier" => "1A2B", "parameter" => "awa_offset", "value" => 1.25},
        %{"hardware_identifier" => "1A2B", "parameter" => "awa_upwash", "value" => -0.75}
      ],
      "seq" => 7,
      "stw_estimators" => [
        %{
          "bands" => [
            %{
              "center_mps" => 3,
              "estimate" => stw_tracker,
              "p" => 0.5,
              "theta" => 1.02
            }
          ],
          "estimate_options" => estimate_options(min_samples: 6, max_spread: 0.04, max_drift: 0.02),
          "hardware_identifier" => "2B3C",
          "pairs_seen" => 5,
          "pairs_skipped" => 0
        }
      ]
    }
  end

  defp wind_shift_checkpoint do
    started_at_ms = 1_784_800_800_000

    %{
      "last_summary" => %{
        "mean_twd_deg" => 212.0,
        "oscillation_amplitude_deg" => 4.0,
        "oscillation_period_s" => 600.0,
        "regime" => "oscillating",
        "trend_deg_per_hr" => 1.2,
        "tws_mean_mps" => 5.5
      },
      "pending_events" => [
        %{
          "detail" => %{"max_deg" => 219.0, "min_deg" => 205.0},
          "kind" => "new_high",
          "magnitude_deg" => 14.0,
          "t_ms" => started_at_ms + 10_000,
          "twd_deg" => 219.0
        },
        %{
          "detail" => %{"onset_t_ms" => started_at_ms + 5_000},
          "kind" => "step",
          "magnitude_deg" => 8.0,
          "t_ms" => started_at_ms + 20_000,
          "twd_deg" => 220.0
        },
        %{
          "detail" => %{"confidence" => 0.8, "from" => "calm", "to" => "oscillating"},
          "kind" => "regime_change",
          "magnitude_deg" => nil,
          "t_ms" => started_at_ms + 30_000,
          "twd_deg" => 214.0
        },
        %{
          "detail" => %{"phase_deg" => 4.0},
          "kind" => "lift_extreme",
          "magnitude_deg" => 4.0,
          "t_ms" => started_at_ms + 40_000,
          "twd_deg" => 216.0
        },
        %{
          "detail" => %{"phase_deg" => -3.0},
          "kind" => "header_extreme",
          "magnitude_deg" => 3.0,
          "t_ms" => started_at_ms + 50_000,
          "twd_deg" => 209.0
        }
      ],
      "pending_timeline" => [
        %{
          "amplitude_deg" => 4.0,
          "mean_twd_deg" => 212.0,
          "period_s" => 600.0,
          "phase_deg" => 2.0,
          "t_ms" => started_at_ms + 60_000,
          "trend_deg_per_hr" => 1.2,
          "tws_mps" => 5.5
        }
      ],
      "seq" => 9,
      "session" => %{
        "lat_sum" => 42.0,
        "lon_sum" => -71.0,
        "pos_n" => 1,
        "started_at_ms" => started_at_ms,
        "tws_n" => 1,
        "tws_sum" => 5.5
      }
    }
  end

  defp polar_checkpoint do
    %{
      "cells" => [
        %{
          "count" => 5,
          "quantile" => p_square(0.9),
          "twa_bin" => 45,
          "tws_bin" => 3
        }
      ]
    }
  end

  defp estimate_tracker(opts) do
    options = estimate_options(opts)

    %{
      "clamp_max" => options["clamp_max"],
      "clamp_min" => options["clamp_min"],
      "count" => 5,
      "max_drift" => options["max_drift"],
      "max_slew" => options["max_slew"],
      "max_spread" => options["max_spread"],
      "min_samples" => options["min_samples"],
      "p25" => p_square(0.25),
      "p50" => p_square(0.5),
      "p75" => p_square(0.75),
      "recent" => [5.0, 4.0, 3.0, 2.0, 1.0],
      "stability_window" => options["stability_window"]
    }
  end

  defp fresh_estimate_tracker(opts) do
    options = estimate_options(opts)

    %{
      "clamp_max" => options["clamp_max"],
      "clamp_min" => options["clamp_min"],
      "count" => 0,
      "max_drift" => options["max_drift"],
      "max_slew" => options["max_slew"],
      "max_spread" => options["max_spread"],
      "min_samples" => options["min_samples"],
      "p25" => fresh_p_square(0.25),
      "p50" => fresh_p_square(0.5),
      "p75" => fresh_p_square(0.75),
      "recent" => [],
      "stability_window" => options["stability_window"]
    }
  end

  defp estimate_options(opts) do
    max_spread = Keyword.get(opts, :max_spread, 1.0)

    %{
      "clamp_max" => Keyword.get(opts, :clamp_max),
      "clamp_min" => Keyword.get(opts, :clamp_min),
      "max_drift" => Keyword.get(opts, :max_drift, max_spread / 2),
      "max_slew" => Keyword.get(opts, :max_slew),
      "max_spread" => max_spread,
      "min_samples" => Keyword.get(opts, :min_samples, 8),
      "stability_window" => Keyword.get(opts, :stability_window, 5)
    }
  end

  defp p_square(p) do
    %{
      "buffer" => [],
      "count" => 5,
      "dnp" => [0.0, p / 2, p, (1.0 + p) / 2, 1.0],
      "n" => [1, 2, 3, 4, 5],
      "np" => [1.0, 1.0 + 2.0 * p, 1.0 + 4.0 * p, 3.0 + 2.0 * p, 5.0],
      "p" => p,
      "q" => [1.0, 2.0, 3.0, 4.0, 5.0]
    }
  end

  defp fresh_p_square(p) do
    %{
      "buffer" => [],
      "count" => 0,
      "dnp" => nil,
      "n" => nil,
      "np" => nil,
      "p" => p,
      "q" => nil
    }
  end
end
