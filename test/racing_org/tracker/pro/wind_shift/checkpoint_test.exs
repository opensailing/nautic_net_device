defmodule RacingOrg.Tracker.Pro.WindShift.CheckpointTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.Checkpoint, as: ContractCheckpoint
  alias RacingOrg.Tracker.Pro.WindShift.Checkpoint

  @started_at_ms 1_784_800_800_000

  test "projects a real Observer.Store snapshot through the canonical wind-shift contract and hydrates it exactly" do
    snapshot = snapshot()

    assert {:ok, content} = Checkpoint.project(snapshot)
    assert content == content()

    assert {:ok, bytes} = ContractCheckpoint.encode_content(:wind_shift, 1, content)
    assert {:ok, decoded} = ContractCheckpoint.decode_content(:wind_shift, 1, bytes)
    assert {:ok, hydrated} = Checkpoint.hydrate(decoded)

    assert hydrated == snapshot
  end

  test "preserves a newer current event followed by a delayed older extreme exactly" do
    newer_current =
      snapshot().pending_events
      |> Enum.find(&(&1.kind == "regime_change"))
      |> Map.put(:t_ms, @started_at_ms + 40_000)

    delayed_extreme =
      snapshot().pending_events
      |> Enum.find(&(&1.kind == "lift_extreme"))
      |> Map.put(:t_ms, @started_at_ms + 20_000)

    snapshot = %{snapshot() | pending_events: [newer_current, delayed_extreme]}

    assert {:ok, content} = Checkpoint.project(snapshot)
    assert Enum.map(content["pending_events"], & &1["t_ms"]) == [@started_at_ms + 40_000, @started_at_ms + 20_000]
    assert Enum.map(content["pending_events"], & &1["kind"]) == ["regime_change", "lift_extreme"]

    assert {:ok, bytes} = ContractCheckpoint.encode_content(:wind_shift, 1, content)
    assert {:ok, decoded} = ContractCheckpoint.decode_content(:wind_shift, 1, bytes)
    assert {:ok, hydrated} = Checkpoint.hydrate(decoded)
    assert hydrated == snapshot
  end

  test "round-trips the pre-session Observer.Store snapshot without inventing learner state" do
    snapshot = %{
      session: nil,
      seq: 12,
      pending_timeline: [],
      pending_events: [],
      last_summary: nil
    }

    assert {:ok, content} = Checkpoint.project(snapshot)
    assert {:ok, bytes} = ContractCheckpoint.encode_content(:wind_shift, 1, content)
    assert {:ok, decoded} = ContractCheckpoint.decode_content(:wind_shift, 1, bytes)
    assert Checkpoint.hydrate(decoded) == {:ok, snapshot}
  end

  test "rejects open snapshot fields instead of serializing ephemeral estimation cores or metadata" do
    for open_snapshot <- [
          Map.put(snapshot(), :means, %{slow: 212.0}),
          Map.put(snapshot(), :envelope, %{min_deg: 205.0, max_deg: 219.0}),
          Map.put(snapshot(), :metadata, %{arbitrary: true})
        ] do
      assert {:error, :invalid_wind_shift_snapshot} = Checkpoint.project(open_snapshot)
    end
  end

  test "rejects malformed, regressed non-extreme events, out-of-order timeline, and session-unbound snapshots" do
    [first_event, second_event | remaining_events] = snapshot().pending_events

    regressed_non_extreme_events =
      put_in(snapshot(), [:pending_events], [second_event, first_event | remaining_events])

    [first_row, second_row] = snapshot().pending_timeline
    out_of_order_timeline = put_in(snapshot(), [:pending_timeline], [second_row, first_row])

    step_index = Enum.find_index(snapshot().pending_events, &(&1.kind == "step"))

    onset_before_session =
      update_in(snapshot(), [:pending_events, Access.at(step_index), :detail, :onset_t_ms], fn _ ->
        @started_at_ms - 1
      end)

    no_bound_session = %{snapshot() | session: nil}

    for malformed <- [
          %{snapshot() | seq: -1},
          regressed_non_extreme_events,
          out_of_order_timeline,
          onset_before_session,
          no_bound_session
        ] do
      assert {:error, :invalid_wind_shift_snapshot} = Checkpoint.project(malformed)
    end
  end

  test "hydrates only canonical closed content and rejects secrets or open metadata" do
    assert {:error, :invalid_checkpoint_content} = Checkpoint.hydrate(snapshot())

    assert {:error, :checkpoint_secret_forbidden} =
             content()
             |> Map.put("metadata", %{"token" => "not-a-credential"})
             |> Checkpoint.hydrate()

    [event | rest] = content()["pending_events"]
    open_detail = put_in(event, ["detail", "payload"], "not-a-secret")

    assert {:error, :checkpoint_secret_forbidden} =
             content()
             |> Map.put("pending_events", [open_detail | rest])
             |> Checkpoint.hydrate()
  end

  test "rejects a step onset before the bound session during hydration" do
    step_index = Enum.find_index(content()["pending_events"], &(&1["kind"] == "step"))

    pre_session_onset =
      update_in(content(), ["pending_events", Access.at(step_index), "detail", "onset_t_ms"], fn _ ->
        @started_at_ms - 1
      end)

    assert {:error, :invalid_checkpoint_content} = Checkpoint.hydrate(pre_session_onset)
  end

  defp snapshot do
    %{
      session: %{
        started_at_ms: @started_at_ms,
        lat_sum: 82.0,
        lon_sum: -142.0,
        pos_n: 2,
        tws_sum: 12.4,
        tws_n: 2
      },
      seq: 9,
      pending_timeline: [
        %{
          t_ms: @started_at_ms + 55_000,
          mean_twd_deg: nil,
          phase_deg: nil,
          amplitude_deg: nil,
          period_s: nil,
          trend_deg_per_hr: nil,
          tws_mps: nil
        },
        %{
          t_ms: @started_at_ms + 60_000,
          mean_twd_deg: 212.0,
          phase_deg: 2.0,
          amplitude_deg: 4.0,
          period_s: 600.0,
          trend_deg_per_hr: 1.2,
          tws_mps: 5.5
        }
      ],
      pending_events: [
        %{
          t_ms: @started_at_ms + 10_000,
          kind: "new_high",
          twd_deg: 219.0,
          magnitude_deg: 14.0,
          detail: %{min_deg: 205.0, max_deg: 219.0}
        },
        %{
          t_ms: @started_at_ms + 15_000,
          kind: "new_low",
          twd_deg: 205.0,
          magnitude_deg: 14.0,
          detail: %{min_deg: 205.0, max_deg: 219.0}
        },
        %{
          t_ms: @started_at_ms + 20_000,
          kind: "step",
          twd_deg: 220.0,
          magnitude_deg: 8.0,
          detail: %{onset_t_ms: @started_at_ms + 5_000}
        },
        %{
          t_ms: @started_at_ms + 30_000,
          kind: "regime_change",
          twd_deg: 214.0,
          magnitude_deg: nil,
          detail: %{from: "calm", to: "oscillating", confidence: 0.8}
        },
        %{
          t_ms: @started_at_ms + 40_000,
          kind: "lift_extreme",
          twd_deg: 216.0,
          magnitude_deg: 4.0,
          detail: %{phase_deg: 4.0}
        },
        %{
          t_ms: @started_at_ms + 50_000,
          kind: "header_extreme",
          twd_deg: 209.0,
          magnitude_deg: 3.0,
          detail: %{phase_deg: -3.0}
        }
      ],
      last_summary: %{
        mean_twd_deg: 212.0,
        trend_deg_per_hr: 1.2,
        oscillation_period_s: 600.0,
        oscillation_amplitude_deg: 4.0,
        regime: "oscillating",
        tws_mean_mps: 5.5
      }
    }
  end

  defp content do
    %{
      "session" => %{
        "started_at_ms" => @started_at_ms,
        "lat_sum" => 82.0,
        "lon_sum" => -142.0,
        "pos_n" => 2,
        "tws_sum" => 12.4,
        "tws_n" => 2
      },
      "seq" => 9,
      "pending_timeline" => [
        %{
          "t_ms" => @started_at_ms + 55_000,
          "mean_twd_deg" => nil,
          "phase_deg" => nil,
          "amplitude_deg" => nil,
          "period_s" => nil,
          "trend_deg_per_hr" => nil,
          "tws_mps" => nil
        },
        %{
          "t_ms" => @started_at_ms + 60_000,
          "mean_twd_deg" => 212.0,
          "phase_deg" => 2.0,
          "amplitude_deg" => 4.0,
          "period_s" => 600.0,
          "trend_deg_per_hr" => 1.2,
          "tws_mps" => 5.5
        }
      ],
      "pending_events" => [
        %{
          "t_ms" => @started_at_ms + 10_000,
          "kind" => "new_high",
          "twd_deg" => 219.0,
          "magnitude_deg" => 14.0,
          "detail" => %{"min_deg" => 205.0, "max_deg" => 219.0}
        },
        %{
          "t_ms" => @started_at_ms + 15_000,
          "kind" => "new_low",
          "twd_deg" => 205.0,
          "magnitude_deg" => 14.0,
          "detail" => %{"min_deg" => 205.0, "max_deg" => 219.0}
        },
        %{
          "t_ms" => @started_at_ms + 20_000,
          "kind" => "step",
          "twd_deg" => 220.0,
          "magnitude_deg" => 8.0,
          "detail" => %{"onset_t_ms" => @started_at_ms + 5_000}
        },
        %{
          "t_ms" => @started_at_ms + 30_000,
          "kind" => "regime_change",
          "twd_deg" => 214.0,
          "magnitude_deg" => nil,
          "detail" => %{"from" => "calm", "to" => "oscillating", "confidence" => 0.8}
        },
        %{
          "t_ms" => @started_at_ms + 40_000,
          "kind" => "lift_extreme",
          "twd_deg" => 216.0,
          "magnitude_deg" => 4.0,
          "detail" => %{"phase_deg" => 4.0}
        },
        %{
          "t_ms" => @started_at_ms + 50_000,
          "kind" => "header_extreme",
          "twd_deg" => 209.0,
          "magnitude_deg" => 3.0,
          "detail" => %{"phase_deg" => -3.0}
        }
      ],
      "last_summary" => %{
        "mean_twd_deg" => 212.0,
        "trend_deg_per_hr" => 1.2,
        "oscillation_period_s" => 600.0,
        "oscillation_amplitude_deg" => 4.0,
        "regime" => "oscillating",
        "tws_mean_mps" => 5.5
      }
    }
  end
end
