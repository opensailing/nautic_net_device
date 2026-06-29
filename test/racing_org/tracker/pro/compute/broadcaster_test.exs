defmodule RacingOrg.Tracker.Pro.Compute.BroadcasterTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.Compute.Broadcaster
  alias RacingOrg.Tracker.NMEA2000.J1939

  @deg_per_rad 180.0 / :math.pi()

  # A stub engine: current_values/1 returns whatever was stashed in an Agent. This
  # lets each test drive the exact computed-values list the Broadcaster reads.
  defmodule StubEngine do
    def start(values), do: Agent.start_link(fn -> values end)
    def set(agent, values), do: Agent.update(agent, fn _ -> values end)
    def current_values(agent), do: Agent.get(agent, & &1)
  end

  defp result(def_overrides, outputs, valid?, computed_at_ms \\ 0) do
    base = %{
      id: "id-#{System.unique_integer([:positive])}",
      name: "v",
      definition_type: :expression,
      output_pgn: 128_259,
      output_field: "speed_water_referenced",
      output_reference: nil,
      output_unit: "m/s",
      output_instance: nil,
      damping_seconds: 0.0,
      broadcast_rate_hz: 2.0,
      broadcast_enabled: true,
      stream_to_backend: true
    }

    %{def: Map.merge(base, def_overrides), outputs: outputs, valid?: valid?, computed_at_ms: computed_at_ms}
  end

  # Start a Broadcaster whose engine is the stub, with an injected clock + a sender
  # that forwards encoded frames to the test process. `:tick_ms` large so only manual
  # `tick_now/1` fires (deterministic). The backend stream sender is also injected and
  # forwards each flushed batch to the test process as `{:stream, values}`.
  defp start_bcast(values, opts \\ []) do
    test_pid = self()
    {:ok, engine} = StubEngine.start(values)
    clock = opts[:clock] || fn -> 0 end

    bcast =
      start_supervised!(
        {Broadcaster,
         [
           engine: {StubEngine, engine},
           tick_ms: opts[:tick_ms] || 3_600_000,
           now_fn: clock,
           transmit_fn: fn priority, pgn, payload -> send(test_pid, {:tx, priority, pgn, payload}) end,
           stream_fn: opts[:stream_fn] || fn streamed -> send(test_pid, {:stream, streamed}) end,
           name: nil
         ] ++ Keyword.take(opts, [:stream_interval_ms])},
        id: {Broadcaster, System.unique_integer([:positive])}
      )

    %{engine: engine, bcast: bcast}
  end

  describe "valid + enabled defs are encoded and sent" do
    test "a valid water-speed def is encoded and broadcast on tick" do
      values = [result(%{output_pgn: 128_259, output_field: "speed_water_referenced"}, %{"value" => 4.0}, true)]
      %{bcast: b} = start_bcast(values)

      assert sent = Broadcaster.tick_now(b)
      assert sent >= 1

      assert_receive {:tx, _priority, 128_259, payload}
      decoded = J1939.SpeedParams.decode(payload)
      assert_in_delta decoded.water_speed, 4.0, 0.01
    end

    test "a true_wind library calc broadcasts 130306 with speed + angle + reference=true" do
      values = [
        result(
          %{
            definition_type: :library,
            output_pgn: 130_306,
            output_field: "wind_speed",
            output_reference: "true",
            damping_seconds: 0.0
          },
          %{"true_wind_speed" => 8.0, "true_wind_angle" => 30.0, "true_wind_direction" => 210.0},
          true
        )
      ]

      %{bcast: b} = start_bcast(values)
      Broadcaster.tick_now(b)

      assert_receive {:tx, _p, 130_306, payload}
      decoded = J1939.WindDataParams.decode(payload)
      assert_in_delta decoded.wind_speed, 8.0, 0.01
      assert_in_delta decoded.wind_angle, 30.0 / @deg_per_rad, 0.001
      assert decoded.wind_reference in [:true_boat_referenced, :true_water_referenced, :true_ground_referenced]
    end
  end

  describe "invalid / disabled defs are NOT sent" do
    test "an invalid def is skipped (no stale/garbage on the bus)" do
      values = [result(%{}, %{}, false)]
      %{bcast: b} = start_bcast(values)
      assert 0 == Broadcaster.tick_now(b)
      refute_receive {:tx, _, _, _}, 50
    end

    test "a broadcast_disabled def is skipped even when valid" do
      values = [result(%{broadcast_enabled: false}, %{"value" => 4.0}, true)]
      %{bcast: b} = start_bcast(values)
      assert 0 == Broadcaster.tick_now(b)
      refute_receive {:tx, _, _, _}, 50
    end
  end

  describe "per-def rate limiting" do
    test "a 2 Hz value is not sent 10x on a 10 Hz tick — only when due" do
      values = [result(%{broadcast_rate_hz: 2.0, output_field: "speed_water_referenced"}, %{"value" => 4.0}, true)]

      # Drive a clock we control; 10 ticks 100ms apart = 1 second of 10 Hz ticks.
      clock = :counters.new(1, [])
      :counters.put(clock, 1, 0)
      now_fn = fn -> :counters.get(clock, 1) end

      %{bcast: b} = start_bcast(values, clock: now_fn)

      sent_total =
        Enum.reduce(0..9, 0, fn i, acc ->
          :counters.put(clock, 1, i * 100)
          acc + Broadcaster.tick_now(b)
        end)

      # At 2 Hz over ~1s of ticks we expect ~2 sends (first tick + one ~500ms later),
      # NOT 10. Allow 2..3 for boundary timing.
      assert sent_total in 2..3
    end

    test "first tick always sends (no prior timestamp)" do
      values = [result(%{broadcast_rate_hz: 1.0}, %{"value" => 4.0}, true)]
      %{bcast: b} = start_bcast(values)
      assert 1 == Broadcaster.tick_now(b)
    end
  end

  describe "output damping" do
    test "tau = 0 passes the value through unchanged" do
      values = [result(%{damping_seconds: 0.0, output_field: "speed_water_referenced"}, %{"value" => 10.0}, true)]
      %{bcast: b} = start_bcast(values)
      Broadcaster.tick_now(b)
      assert_receive {:tx, _, 128_259, payload}
      decoded = J1939.SpeedParams.decode(payload)
      assert_in_delta decoded.water_speed, 10.0, 0.01
    end

    test "tau > 0 smooths a step change toward the new value (linear speed)" do
      clock = :counters.new(1, [])
      :counters.put(clock, 1, 0)
      now_fn = fn -> :counters.get(clock, 1) end

      # Stable id so the per-def EWMA state carries across the two ticks.
      damp = %{id: "damp-linear", damping_seconds: 2.0, broadcast_rate_hz: 100.0}
      {:ok, engine} = StubEngine.start([result(damp, %{"value" => 0.0}, true)])
      test_pid = self()

      b =
        start_supervised!(
          {Broadcaster,
           engine: {StubEngine, engine},
           tick_ms: 3_600_000,
           now_fn: now_fn,
           transmit_fn: fn _p, pgn, payload -> send(test_pid, {:tx, pgn, payload}) end,
           name: nil},
          id: {Broadcaster, System.unique_integer([:positive])}
        )

      # First tick at t=0 seeds the EWMA at 0.0.
      Broadcaster.tick_now(b)
      assert_receive {:tx, 128_259, p0}
      assert_in_delta J1939.SpeedParams.decode(p0).water_speed, 0.0, 0.01

      # Step the input to 10.0; advance 1s with tau=2s. Smoothed value must be
      # strictly between 0 and 10 (partial approach), not the raw 10.
      StubEngine.set(engine, [result(damp, %{"value" => 10.0}, true)])
      :counters.put(clock, 1, 1_000)
      Broadcaster.tick_now(b)
      assert_receive {:tx, 128_259, p1}
      v1 = J1939.SpeedParams.decode(p1).water_speed
      assert v1 > 0.5 and v1 < 9.5
    end

    test "circular damping averages a wind angle the short way across the 360/0 wrap" do
      clock = :counters.new(1, [])
      :counters.put(clock, 1, 0)
      now_fn = fn -> :counters.get(clock, 1) end

      mk = fn angle ->
        [
          result(
            %{
              id: "damp-circular",
              definition_type: :library,
              output_pgn: 130_306,
              output_field: "wind_speed",
              output_reference: "true",
              damping_seconds: 2.0,
              broadcast_rate_hz: 100.0
            },
            %{"true_wind_speed" => 5.0, "true_wind_angle" => angle},
            true
          )
        ]
      end

      {:ok, engine} = StubEngine.start(mk.(350.0))
      test_pid = self()

      b =
        start_supervised!(
          {Broadcaster,
           engine: {StubEngine, engine},
           tick_ms: 3_600_000,
           now_fn: now_fn,
           transmit_fn: fn _p, pgn, payload -> send(test_pid, {:tx, pgn, payload}) end,
           name: nil},
          id: {Broadcaster, System.unique_integer([:positive])}
        )

      Broadcaster.tick_now(b)
      assert_receive {:tx, 130_306, _p0}

      # Now step to 10 deg. With tau=2s over 1s the smoothed angle moves only PART of
      # the way and "the short way" across 0 — it lands just above 350 (≈358), proving
      # circular averaging (a naive linear mean of 350 and 10 would give ~180).
      StubEngine.set(engine, mk.(10.0))
      :counters.put(clock, 1, 1_000)
      Broadcaster.tick_now(b)
      assert_receive {:tx, 130_306, p1}
      deg = J1939.WindDataParams.decode(p1).wind_angle * @deg_per_rad
      # Short-way blend from 350 toward 10: in (350, 360) or wrapped into [0, 10).
      assert (deg > 350.0 and deg < 360.0) or (deg >= 0.0 and deg < 10.0)
      refute deg > 90.0 and deg < 270.0
    end
  end

  describe "B&G 130824 target/VMG/next-leg key-value broadcast" do
    # B&G = 381, Marine = 4 -> manufacturer header bytes 7D 99 (see PgnEncode).
    @bandg_header <<0x7D, 0x99>>

    test "a 130824 next_leg_awa def broadcasts a B&G key-value frame on tick" do
      values = [
        result(
          %{output_pgn: 130_824, output_field: "next_leg_awa", broadcast_enabled: true, damping_seconds: 0.0},
          %{"next_leg_awa" => 30.0},
          true
        )
      ]

      %{bcast: b} = start_bcast(values)
      assert Broadcaster.tick_now(b) >= 1

      assert_receive {:tx, _priority, 130_824, payload}
      # Key 111, length 2 (descriptor 6F 20), 30 deg -> 0.5236 rad -> 5236 = LE 74 14.
      assert payload == @bandg_header <> <<0x6F, 0x20, 0x74, 0x14>>
    end

    test "a 130824 target_boat_speed def broadcasts its Key 125 frame" do
      values = [
        result(
          %{output_pgn: 130_824, output_field: "target_boat_speed", broadcast_enabled: true, damping_seconds: 0.0},
          %{"target_boat_speed" => 5.0},
          true
        )
      ]

      %{bcast: b} = start_bcast(values)
      Broadcaster.tick_now(b)

      assert_receive {:tx, _p, 130_824, payload}
      # Key 125 -> descriptor 7D 20; 5.0 m/s -> 500 = LE F4 01.
      assert payload == @bandg_header <> <<0x7D, 0x20, 0xF4, 0x01>>
    end

    test "the standard PGNs still encode/broadcast as before (no regression)" do
      values = [
        result(%{output_pgn: 128_259, output_field: "speed_water_referenced"}, %{"value" => 4.0}, true),
        result(
          %{output_pgn: 130_824, output_field: "vmg", broadcast_enabled: true, damping_seconds: 0.0},
          %{"vmg" => 3.21},
          true
        )
      ]

      %{bcast: b} = start_bcast(values)
      Broadcaster.tick_now(b)

      # The standard speed PGN is unchanged...
      assert_receive {:tx, _p, 128_259, speed_payload}
      assert_in_delta J1939.SpeedParams.decode(speed_payload).water_speed, 4.0, 0.01
      # ...and the new 130824 vmg frame is also emitted (Key 127 -> 7F 20; 3.21 -> 321 = 41 01).
      assert_receive {:tx, _p, 130_824, vmg_payload}
      assert vmg_payload == @bandg_header <> <<0x7F, 0x20, 0x41, 0x01>>
    end

    test "target_twa / next_leg_awa are damped CIRCULARLY (short way across the wrap)" do
      clock = :counters.new(1, [])
      :counters.put(clock, 1, 0)
      now_fn = fn -> :counters.get(clock, 1) end

      mk = fn angle ->
        [
          result(
            %{
              id: "twa-circular",
              output_pgn: 130_824,
              output_field: "target_twa",
              broadcast_enabled: true,
              damping_seconds: 2.0,
              broadcast_rate_hz: 100.0
            },
            %{"target_twa" => angle},
            true
          )
        ]
      end

      {:ok, engine} = StubEngine.start(mk.(170.0))
      test_pid = self()

      b =
        start_supervised!(
          {Broadcaster,
           engine: {StubEngine, engine},
           tick_ms: 3_600_000,
           now_fn: now_fn,
           transmit_fn: fn _p, pgn, payload -> send(test_pid, {:tx, pgn, payload}) end,
           name: nil},
          id: {Broadcaster, System.unique_integer([:positive])}
        )

      # Seed at 170 deg.
      Broadcaster.tick_now(b)
      assert_receive {:tx, 130_824, _p0}

      # Step to -170 deg (i.e. 190). The SHORT way from 170 to -170 crosses ±180, so a
      # circular blend lands NEAR ±180 (|deg| > 170), not back through 0. A linear mean
      # of 170 and -170 would give ~0 — this proves circular damping is applied.
      StubEngine.set(engine, mk.(-170.0))
      :counters.put(clock, 1, 1_000)
      Broadcaster.tick_now(b)
      assert_receive {:tx, 130_824, p1}
      # Decode the i16 rad value out of the B&G frame and back to degrees.
      <<_hdr::binary-2, _desc::binary-2, raw::little-signed-16>> = p1
      deg = raw * 1.0e-4 * @deg_per_rad
      assert abs(deg) > 170.0
      refute abs(deg) < 90.0
    end
  end

  describe "broadcasting status" do
    test "broadcasting? is true after a tick actually sent something" do
      values = [result(%{}, %{"value" => 4.0}, true)]
      %{bcast: b} = start_bcast(values)
      refute Broadcaster.broadcasting?(b)
      Broadcaster.tick_now(b)
      assert Broadcaster.broadcasting?(b)
    end

    test "broadcasting? is false when nothing is eligible" do
      values = [result(%{broadcast_enabled: false}, %{"value" => 4.0}, true)]
      %{bcast: b} = start_bcast(values)
      Broadcaster.tick_now(b)
      refute Broadcaster.broadcasting?(b)
    end
  end

  describe "backend streamback (Phase 10)" do
    test "a valid stream_to_backend def's value is streamed as {id, value} (no at)" do
      values = [
        result(
          %{id: "stream-1", output_field: "speed_water_referenced", stream_to_backend: true},
          %{"value" => 4.0},
          true
        )
      ]

      %{bcast: b} = start_bcast(values)
      Broadcaster.tick_now(b)

      assert_receive {:stream, streamed}
      assert [%{id: "stream-1", value: value}] = streamed
      assert_in_delta value, 4.0, 0.001
      # The streamed payload omits per-sample timestamps (the server stamps receipt).
      refute Map.has_key?(hd(streamed), :at)
    end

    test "stream_to_backend == false is NOT streamed (even when valid + broadcasting)" do
      values = [result(%{id: "no-stream", stream_to_backend: false}, %{"value" => 4.0}, true)]
      %{bcast: b} = start_bcast(values)
      Broadcaster.tick_now(b)
      # The bus broadcast still happens, but nothing is streamed to the backend.
      refute_receive {:stream, _}, 50
    end

    test "an invalid def is NOT streamed (no stale/garbage to the backend)" do
      values = [result(%{id: "invalid", stream_to_backend: true}, %{"value" => 4.0}, false)]
      %{bcast: b} = start_bcast(values)
      Broadcaster.tick_now(b)
      refute_receive {:stream, _}, 50
    end

    test "multiple due stream values are batched into ONE flush" do
      values = [
        result(%{id: "a", output_field: "speed_water_referenced", stream_to_backend: true}, %{"value" => 1.0}, true),
        result(%{id: "b", output_field: "speed_water_referenced", stream_to_backend: true}, %{"value" => 2.0}, true)
      ]

      %{bcast: b} = start_bcast(values)
      Broadcaster.tick_now(b)

      # Exactly ONE stream message carrying BOTH values (not one message per value).
      assert_receive {:stream, streamed}
      ids = Enum.map(streamed, & &1.id) |> Enum.sort()
      assert ids == ["a", "b"]
      refute_receive {:stream, _}, 50
    end

    test "the streamed value is the DAMPED (smoothed) value, not the raw input" do
      clock = :counters.new(1, [])
      :counters.put(clock, 1, 0)
      now_fn = fn -> :counters.get(clock, 1) end

      damp = %{
        id: "damp-stream",
        output_field: "speed_water_referenced",
        damping_seconds: 2.0,
        broadcast_rate_hz: 100.0,
        stream_to_backend: true
      }

      {:ok, engine} = StubEngine.start([result(damp, %{"value" => 0.0}, true)])
      test_pid = self()

      b =
        start_supervised!(
          {Broadcaster,
           engine: {StubEngine, engine},
           tick_ms: 3_600_000,
           now_fn: now_fn,
           transmit_fn: fn _p, _pgn, _payload -> :ok end,
           stream_fn: fn streamed -> send(test_pid, {:stream, streamed}) end,
           stream_interval_ms: 500,
           name: nil},
          id: {Broadcaster, System.unique_integer([:positive])}
        )

      # First tick at t=0 seeds the EWMA at 0.0 and streams 0.0.
      Broadcaster.tick_now(b)
      assert_receive {:stream, [%{id: "damp-stream", value: v0}]}
      assert_in_delta v0, 0.0, 0.001

      # Step input to 10.0; advance 1s with tau=2s. The streamed value must be the
      # smoothed value (strictly between 0 and 10), the SAME value the bus gets — not
      # the raw 10.0.
      StubEngine.set(engine, [result(damp, %{"value" => 10.0}, true)])
      :counters.put(clock, 1, 1_000)
      Broadcaster.tick_now(b)
      assert_receive {:stream, [%{id: "damp-stream", value: v1}]}
      assert v1 > 0.5 and v1 < 9.5
    end

    test "a multi-output library calc streams its PRIMARY output (output_field)" do
      values = [
        result(
          %{
            id: "wind",
            definition_type: :library,
            output_pgn: 130_306,
            output_field: "true_wind_speed",
            output_reference: "true",
            damping_seconds: 0.0,
            stream_to_backend: true
          },
          %{"true_wind_speed" => 8.0, "true_wind_angle" => 30.0, "true_wind_direction" => 210.0},
          true
        )
      ]

      %{bcast: b} = start_bcast(values)
      Broadcaster.tick_now(b)

      assert_receive {:stream, [%{id: "wind", value: value}]}
      assert_in_delta value, 8.0, 0.001
    end

    test "the stream is rate-limited to ~2 Hz, independent of a 50 Hz broadcast rate" do
      clock = :counters.new(1, [])
      :counters.put(clock, 1, 0)
      now_fn = fn -> :counters.get(clock, 1) end

      # broadcast_rate_hz is high (would emit on every 10 Hz tick), but the stream must
      # be capped at ~2 Hz (a 500 ms interval).
      values = [
        result(
          %{id: "fast", output_field: "speed_water_referenced", broadcast_rate_hz: 50.0, stream_to_backend: true},
          %{"value" => 4.0},
          true
        )
      ]

      %{bcast: b} = start_bcast(values, clock: now_fn, stream_interval_ms: 500)

      # 10 ticks 100 ms apart = 1 second of 10 Hz ticks.
      stream_msgs =
        Enum.reduce(0..9, 0, fn i, acc ->
          :counters.put(clock, 1, i * 100)
          Broadcaster.tick_now(b)

          receive do
            {:stream, _} -> acc + 1
          after
            0 -> acc
          end
        end)

      # At 2 Hz over ~1s of ticks we expect ~2 stream flushes (t=0 and ~t=500ms), NOT 10.
      assert stream_msgs in 2..3
    end

    test "no stream flush is sent when there are no eligible stream values" do
      values = [result(%{id: "x", broadcast_enabled: true, stream_to_backend: false}, %{"value" => 4.0}, true)]
      %{bcast: b} = start_bcast(values)
      Broadcaster.tick_now(b)
      refute_receive {:stream, _}, 50
    end
  end
end
