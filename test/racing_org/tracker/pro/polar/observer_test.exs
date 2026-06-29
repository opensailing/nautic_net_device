defmodule RacingOrg.Tracker.Pro.Polar.ObserverTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.Commands
  alias RacingOrg.Tracker.Pro.Polar
  alias RacingOrg.Tracker.Pro.Polar.Observer
  alias RacingOrg.Tracker.Pro.Polar.Observer.Bins
  alias RacingOrg.Tracker.Protobuf.DeviceCommand
  alias RacingOrg.Tracker.Protobuf.PolarCell
  alias RacingOrg.Tracker.Protobuf.PolarOptimum
  alias RacingOrg.Tracker.Protobuf.PolarRow
  alias RacingOrg.Tracker.Protobuf.PolarTable
  alias RacingOrg.Tracker.Protobuf.ServerReply

  # --- fixtures -----------------------------------------------------------

  # A steady close-hauled raw-signal map (engine shape: %{name => {value, mono_ms}}).
  # AWA 30°, AWS 8, STW 4, level, heading 0 -> STW-based true wind: TWS ≈ 4.957,
  # TWA ≈ 53.79° (verified against Library.compute(:true_wind, …)).
  defp signals(mono_ms, overrides \\ %{}) do
    base = %{
      "apparent_wind_speed" => 8.0,
      "apparent_wind_angle" => 30.0,
      "boat_speed" => 4.0,
      "heel" => 0.0,
      "pitch" => 0.0,
      "heading" => 0.0
    }

    base
    |> Map.merge(Map.new(overrides))
    |> Map.new(fn {k, v} -> {k, {v, mono_ms}} end)
  end

  # The cell that fixture A lands in: TWS 4.957 / 0.514444 -> 9; TWA 53.79 / 5 -> 10.
  @cell_a {9, 10}

  # A signals_fn that replays a pre-scripted list of raw-signal maps, one per call,
  # then keeps returning the last one. Lets a test drive N deterministic ticks.
  defp scripted(maps) do
    {:ok, agent} = Agent.start_link(fn -> maps end)

    fn ->
      Agent.get_and_update(agent, fn
        [last] -> {last, [last]}
        [head | tail] -> {head, tail}
        [] -> {%{}, []}
      end)
    end
  end

  # A sender that forwards every sailed-polar update to the test process.
  defp collecting_sender do
    me = self()

    fn _channel, update ->
      send(me, {:sailed_update, update})
      :ok
    end
  end

  # Start an Observer with the timer OFF (tests drive tick/1 by hand). By default the
  # monotonic clock advances on each read so throttles eventually fire under sync_ms/
  # persist_ms 0; tests that assert NON-firing pin now_fn to a constant.
  defp start_observer(opts) do
    defaults = [
      name: nil,
      sample_ms: 0,
      dir: nil,
      sender: fn _c, _u -> :ok end,
      boat_identifier: "boat-test"
    ]

    {:ok, pid} = Observer.start_link(Keyword.merge(defaults, opts))
    pid
  end

  # --- sampling -> gate -> bin -> accumulate ------------------------------

  describe "accumulation" do
    test "a steady scripted stream populates the expected cell with a sane percentile" do
      # A steady stream at 1 Hz (advancing t_ms): the window fills, then admits.
      stream = for i <- 0..11, do: signals(i * 1000)
      pid = start_observer(signals_fn: scripted(stream))

      # 12 steady ticks (> the default 10 dwell).
      for _ <- 0..11, do: Observer.tick(pid)

      [{key, {tws_c, twa_c}, %{boat_speed_mps: bsp, count: count}}] = Observer.cells(pid)
      assert key == @cell_a
      # Bin centers: (9 + 0.5) * knot, (10 + 0.5) * 5.
      assert_in_delta tws_c, 9.5 * Bins.knot_mps(), 1.0e-6
      assert_in_delta twa_c, 52.5, 1.0e-6
      # Every admitted sample carried STW 4.0, so the percentile is ~4.0.
      assert_in_delta bsp, 4.0, 1.0e-6
      assert count >= 1

      stats = Observer.stats(pid)
      assert stats.admitted >= 1
      assert stats.populated_cells == 1
    end

    test "samples below the dwell are rejected, not accumulated" do
      pid = start_observer(signals_fn: fn -> signals(0) end)

      # Only 3 ticks: window never reaches the dwell of 10.
      for _ <- 1..3, do: Observer.tick(pid)

      assert Observer.cells(pid) == []
      stats = Observer.stats(pid)
      assert stats.admitted == 0
      assert stats.reject_reasons[:insufficient_dwell] >= 1
    end

    test "at-rest / sub-min-STW samples do NOT accumulate (min-STW floor)" do
      # Steady, on-angle, level, but barely moving: STW 0.1 < the 0.3 m/s floor.
      stream = for i <- 0..11, do: signals(i * 1000, %{"boat_speed" => 0.1})
      pid = start_observer(signals_fn: scripted(stream))

      for _ <- 0..11, do: Observer.tick(pid)

      assert Observer.cells(pid) == []
      stats = Observer.stats(pid)
      assert stats.admitted == 0
      assert stats.reject_reasons[:at_rest] >= 1
    end

    test "a turning boat (high heading rate) does NOT accumulate" do
      # Heading slews 20°/tick (=20°/s at 1 Hz) >> the 3°/s turn-rate gate.
      stream = for i <- 0..11, do: signals(i * 1000, %{"heading" => i * 20.0})
      pid = start_observer(signals_fn: scripted(stream))

      for _ <- 0..11, do: Observer.tick(pid)

      assert Observer.cells(pid) == []
      assert Observer.stats(pid).reject_reasons[:turning] >= 1
    end

    test "an accelerating boat does NOT accumulate" do
      # STW climbs 1 m/s/tick (=1 m/s² at 1 Hz) >> the 0.05 m/s² accel gate.
      stream = for i <- 0..11, do: signals(i * 1000, %{"boat_speed" => 2.0 + i * 1.0})
      pid = start_observer(signals_fn: scripted(stream))

      for _ <- 0..11, do: Observer.tick(pid)

      assert Observer.cells(pid) == []
      assert Observer.stats(pid).reject_reasons[:accelerating] >= 1
    end

    test "a no-go-angle boat (in irons) does NOT accumulate" do
      # AWA ~5° -> true wind angle well inside the no-go band -> rejected.
      stream = for i <- 0..11, do: signals(i * 1000, %{"apparent_wind_angle" => 5.0})
      pid = start_observer(signals_fn: scripted(stream))

      for _ <- 0..11, do: Observer.tick(pid)

      assert Observer.cells(pid) == []
      assert Observer.stats(pid).reject_reasons[:no_go_angle] >= 1
    end
  end

  # --- true wind is STW-based --------------------------------------------

  describe "true wind is STW-based (not SOG-based)" do
    test "an SOG signal distinct from STW does not change the cell" do
      with_sog = for i <- 0..11, do: signals(i * 1000, %{"sog" => 1.0, "velocity_ground" => 1.0})
      pid = start_observer(signals_fn: scripted(with_sog))

      for _ <- 0..11, do: Observer.tick(pid)

      # The boat still bins into the STW-derived cell @cell_a, unaffected by SOG.
      assert [{@cell_a, _, _}] = Observer.cells(pid)
    end

    test "live true_wind_* signals are used when present" do
      # Force a true wind that bins to a DIFFERENT cell than the apparent triangle:
      # TWS 10.3 -> bin floor(10.3/0.514444)=20; TWA 92 -> bin floor(92/5)=18.
      stream =
        for i <- 0..11,
            do: signals(i * 1000, %{"true_wind_speed" => 10.3, "true_wind_angle" => 92.0})

      pid = start_observer(signals_fn: scripted(stream))

      for _ <- 0..11, do: Observer.tick(pid)

      assert [{{20, 18}, _, _}] = Observer.cells(pid)
    end
  end

  # --- persistence --------------------------------------------------------

  describe "persistence" do
    setup do
      dir = Path.join(System.tmp_dir!(), "nn_observer_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(dir) end)
      %{dir: dir}
    end

    test "accumulate -> persist -> a fresh Observer restores and resumes", %{dir: dir} do
      pid = start_observer(signals_fn: fn -> signals(0) end, dir: dir, persist_ms: 0)
      for _ <- 0..14, do: Observer.tick(pid)
      :ok = Observer.persist_now(pid)

      [{@cell_a, _, %{count: count1}}] = Observer.cells(pid)
      assert count1 >= 1
      GenServer.stop(pid)

      # Fresh Observer over the same dir restores the cell and continues counting.
      pid2 = start_observer(signals_fn: fn -> signals(0) end, dir: dir)
      [{@cell_a, _, %{count: restored}}] = Observer.cells(pid2)
      assert restored == count1

      for _ <- 0..14, do: Observer.tick(pid2)
      [{@cell_a, _, %{count: count2}}] = Observer.cells(pid2)
      assert count2 > restored
    end

    test "a corrupt persisted file starts empty without crashing", %{dir: dir} do
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "sailed.polar"), "garbage")

      pid = start_observer(signals_fn: fn -> signals(0) end, dir: dir)
      assert Observer.cells(pid) == []
      # Still functional: it accumulates fresh.
      for _ <- 0..14, do: Observer.tick(pid)
      assert [{@cell_a, _, _}] = Observer.cells(pid)
    end

    test "terminate flushes the final window to disk", %{dir: dir} do
      pid = start_observer(signals_fn: fn -> signals(0) end, dir: dir, persist_ms: 1_000_000)
      for _ <- 0..14, do: Observer.tick(pid)
      # Nothing persisted yet (throttle not due).
      GenServer.stop(pid)

      pid2 = start_observer(signals_fn: fn -> signals(0) end, dir: dir)
      assert [{@cell_a, _, _}] = Observer.cells(pid2)
    end

    test "with dir nil, persistence is disabled (no file, no crash)" do
      pid = start_observer(signals_fn: fn -> signals(0) end, dir: nil)
      for _ <- 0..14, do: Observer.tick(pid)
      assert :ok = Observer.persist_now(pid)
      assert [{@cell_a, _, _}] = Observer.cells(pid)
    end

    test "persistence is throttled (no write before the interval is due)", %{dir: dir} do
      # Clock pinned at 0; persist_ms 30_000 -> the throttle never fires on its own.
      pid = start_observer(signals_fn: fn -> signals(0) end, dir: dir, persist_ms: 30_000, now_fn: fn -> 0 end)
      for _ <- 0..14, do: Observer.tick(pid)

      refute File.exists?(Path.join(dir, "sailed.polar"))
    end
  end

  # --- upstream sync ------------------------------------------------------

  describe "upstream sync" do
    test "changed cells are emitted as a batched delta with the right shape + ordering id" do
      # Pinned clock + large interval: only the explicit sync_now (force) fires, so the
      # per-tick maybe_sync never races into the mailbox.
      pid =
        start_observer(
          signals_fn: fn -> signals(0) end,
          sender: collecting_sender(),
          sync_ms: 30_000,
          now_fn: fn -> 0 end
        )

      for _ <- 0..14, do: Observer.tick(pid)
      :ok = Observer.sync_now(pid)

      assert_received {:sailed_update, update}
      assert update.boat_identifier == "boat-test"
      assert is_integer(update.seq) and update.seq >= 1
      assert [cell] = update.cells
      assert %{tws_mps: tws, twa_deg: twa, boat_speed_mps: bsp, count: count} = cell
      assert_in_delta tws, 9.5 * Bins.knot_mps(), 1.0e-6
      assert_in_delta twa, 52.5, 1.0e-6
      assert_in_delta bsp, 4.0, 1.0e-6
      assert count >= 1
    end

    test "seq is monotonic across syncs (server can order/merge)" do
      pid =
        start_observer(
          signals_fn: fn -> signals(0) end,
          sender: collecting_sender(),
          sync_ms: 30_000,
          now_fn: fn -> 0 end
        )

      for _ <- 0..14, do: Observer.tick(pid)
      :ok = Observer.sync_now(pid)
      assert_received {:sailed_update, %{seq: seq1}}

      for _ <- 0..14, do: Observer.tick(pid)
      :ok = Observer.sync_now(pid)
      assert_received {:sailed_update, %{seq: seq2}}

      assert seq2 > seq1
    end

    test "throttling holds — no per-sample sends" do
      # Clock pinned at 0, sync_ms 30_000 -> the per-tick maybe_sync never fires.
      pid =
        start_observer(
          signals_fn: fn -> signals(0) end,
          sender: collecting_sender(),
          sync_ms: 30_000,
          now_fn: fn -> 0 end
        )

      for _ <- 0..30, do: Observer.tick(pid)

      refute_received {:sailed_update, _}
    end

    test "unchanged cells are not re-sent on the next sync" do
      pid =
        start_observer(
          signals_fn: fn -> signals(0) end,
          sender: collecting_sender(),
          sync_ms: 30_000,
          now_fn: fn -> 0 end
        )

      for _ <- 0..14, do: Observer.tick(pid)
      :ok = Observer.sync_now(pid)
      assert_received {:sailed_update, %{cells: [_]}}

      # No new ticks -> nothing changed -> the next sync emits nothing.
      :ok = Observer.sync_now(pid)
      refute_received {:sailed_update, _}
    end
  end

  # --- non-interference with the reference polar --------------------------

  describe "does not interfere with the reference polar" do
    setup do
      dir = Path.join(System.tmp_dir!(), "nn_observer_ref_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(dir) end)
      %{dir: dir}
    end

    defp polar_reply do
      table =
        struct(PolarTable,
          polar_id: "ref-boat",
          version: 3,
          rows: [struct(PolarRow, tws_mps: 5.0, cells: [struct(PolarCell, twa_deg: 45.0, boat_speed_mps: 4.0)])],
          optima: [struct(PolarOptimum, tws_mps: 5.0, beat_twa: 42.0, beat_vmg: 3.0, run_twa: 165.0, run_vmg: 5.0)]
        )

      command =
        struct(DeviceCommand,
          command_id: "ref-polar",
          assignment_id: "",
          assignment_version: 0,
          payload: {:polar_table, table}
        )

      struct(ServerReply, protocol_version: 1, device_id: "", command: command) |> ServerReply.encode()
    end

    test "accumulating + persisting the sailed polar leaves the reference polar untouched", %{dir: dir} do
      # A real Commands holding a reference polar, persisted to the SAME polar dir the
      # Observer writes its sailed.polar into.
      commands = start_supervised!({Commands, device_id: "dev", polar_dir: dir})
      assert :applied = Commands.apply_reply(commands, polar_reply())
      %Polar{version: 3, polar_id: "ref-boat"} = ref_before = Commands.current_polar(commands)

      pid = start_observer(signals_fn: fn -> signals(0) end, dir: dir, persist_ms: 0)
      for _ <- 0..14, do: Observer.tick(pid)
      :ok = Observer.persist_now(pid)

      # The Observer accumulated its own cells...
      assert [{@cell_a, _, _}] = Observer.cells(pid)
      # ...and wrote a SEPARATE file, leaving the reference polar file + state intact.
      assert File.exists?(Path.join(dir, "sailed.polar"))
      assert File.exists?(Path.join(dir, "reference.polar"))
      assert Commands.current_polar(commands) == ref_before
    end
  end
end
