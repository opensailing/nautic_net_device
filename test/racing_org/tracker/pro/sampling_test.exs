defmodule RacingOrg.Tracker.Pro.SamplingTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.Commands
  alias RacingOrg.Tracker.Protobuf.CourseMark
  alias RacingOrg.Tracker.Protobuf.DeviceCommand
  alias RacingOrg.Tracker.Protobuf.LatLon
  alias RacingOrg.Tracker.Protobuf.RaceAssignment
  alias RacingOrg.Tracker.Protobuf.SamplingRules
  alias RacingOrg.Tracker.Protobuf.ServerReply
  alias RacingOrg.Tracker.Pro.Sampling
  alias RacingOrg.Tracker.Pro.Tracking.Config

  # A stand-in reporter that records the flush intervals AND damping the controller
  # requests, forwarding both to the test process.
  defmodule StubReporter do
    use GenServer
    def start_link(test_pid), do: GenServer.start_link(__MODULE__, test_pid)
    @impl true
    def init(test_pid), do: {:ok, test_pid}

    @impl true
    def handle_call({:set_flush_interval, ms}, _from, test_pid) do
      send(test_pid, {:flush_interval, ms})
      {:reply, :ok, test_pid}
    end

    def handle_call({:set_damping, tau}, _from, test_pid) do
      send(test_pid, {:damping, tau})
      {:reply, :ok, test_pid}
    end
  end

  @start ~U[2026-06-03 12:00:00Z]

  # The three-state config the server pushes (default values from the contract).
  @config %{
    version: 0,
    states: %{
      pre_race: %{damping_seconds: 2.0, send_rate_hz: 1.0},
      starting: %{damping_seconds: 1.0, send_rate_hz: 5.0},
      race: %{damping_seconds: 0.5, send_rate_hz: 10.0}
    }
  }

  defp ts(dt), do: RacingOrg.Tracker.Protobuf.to_proto_timestamp(dt)

  defp start_sampling(now, opts \\ []) do
    commands = start_supervised!({Commands, device_id: "dev"})
    reporter = start_supervised!({StubReporter, self()})

    dir = Path.join(System.tmp_dir!(), "nn_samp_cfg_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)

    config =
      start_supervised!({Config, name: nil, store_dir: dir, on_apply: fn _ -> :ok end, initial_config: @config})

    sampling =
      start_supervised!(
        {Sampling,
         commands: commands,
         reporter: reporter,
         tracking_config: config,
         now_fn: fn -> now end,
         reevaluate_interval_ms: Keyword.get(opts, :reevaluate_interval_ms, 60_000)}
      )

    %{commands: commands, sampling: sampling, config: config, reporter: reporter}
  end

  defp apply_race_assignment(commands, opts) do
    rules =
      struct(SamplingRules,
        default_mode: :SAMPLE_MODE_OUTING_1HZ,
        race_mode: :SAMPLE_MODE_RACE_5HZ,
        event_mode: :SAMPLE_MODE_EVENT_10HZ,
        start_window_seconds: 60,
        finish_window_seconds: 60,
        mark_proximity_meters: 100
      )

    race =
      struct(RaceAssignment,
        official_start_time: ts(@start),
        expected_duration_seconds: 3600,
        sampling_rules: rules,
        course_marks: Keyword.get(opts, :marks, [])
      )

    command =
      struct(DeviceCommand,
        command_id: "c1",
        assignment_id: "a1",
        assignment_version: 1,
        payload: {:race_assignment, race}
      )

    reply = struct(ServerReply, protocol_version: 1, device_id: "", command: command) |> ServerReply.encode()
    :applied = Commands.apply_reply(commands, reply)
  end

  test "boots at idle / pre_race and sets the reporter to the pre_race rate + damping" do
    %{sampling: s} = start_sampling(@start)
    assert Sampling.current_phase(s) == :idle
    assert Sampling.current_state(s) == :pre_race
    # pre_race: 1 Hz -> 1000 ms, damping 2.0s (read from the config at boot)
    assert_receive {:flush_interval, 1000}
    assert_receive {:damping, 2.0}
  end

  test "switches to the :race state when a race is underway (rate + damping from config)" do
    %{commands: c, sampling: s} = start_sampling(DateTime.add(@start, 120, :second))
    apply_race_assignment(c, [])
    assert {:racing, :race} = Sampling.reevaluate(s)
    assert Sampling.current_state(s) == :race
    # race: 10 Hz -> 100 ms, damping 0.5s
    assert_receive {:flush_interval, 100}
    assert_receive {:damping, 0.5}
  end

  test "maps the start window to the :starting state" do
    %{commands: c, sampling: s} = start_sampling(DateTime.add(@start, -30, :second))
    apply_race_assignment(c, [])
    assert {:pre_start, :starting} = Sampling.reevaluate(s)
    # starting: 5 Hz -> 200 ms, damping 1.0s
    assert_receive {:flush_interval, 200}
    assert_receive {:damping, 1.0}
  end

  test "mark rounding maps to the :race state (high rate)" do
    %{commands: c, sampling: s} = start_sampling(DateTime.add(@start, 120, :second))
    marks = [struct(CourseMark, code: "1", position: struct(LatLon, latitude: 42.0, longitude: -70.0))]
    apply_race_assignment(c, marks: marks)
    send(s, {:sampling_position, {42.0, -70.0}})
    assert {:rounding, :race} = Sampling.reevaluate(s)
    assert_receive {:flush_interval, 100}
    assert_receive {:damping, 0.5}
  end

  test "returns to :pre_race after the expected finish" do
    %{commands: c, sampling: s} = start_sampling(DateTime.add(@start, 3600, :second))
    apply_race_assignment(c, [])
    assert {:complete, :pre_race} = Sampling.reevaluate(s)
    assert_receive {:flush_interval, 1000}
    assert_receive {:damping, 2.0}
  end

  test "current_mode is preserved for proto tagging (race underway => :race_5hz)" do
    %{commands: c, sampling: s} = start_sampling(DateTime.add(@start, 120, :second))
    apply_race_assignment(c, [])
    Sampling.reevaluate(s)
    assert Sampling.current_mode(s) == :race_5hz
  end

  test "re-applies rate + damping when the tracking config changes" do
    %{sampling: s, config: cfg} = start_sampling(@start)
    # drain boot effects
    assert_receive {:flush_interval, 1000}

    # Push a new config (newer version) with different pre_race values.
    assert {:ok, _} =
             Config.apply_config(cfg, %{
               "version" => 1,
               "states" => %{
                 "pre_race" => %{"damping_seconds" => 4.0, "send_rate_hz" => 2.0},
                 "starting" => %{"damping_seconds" => 1.0, "send_rate_hz" => 5.0},
                 "race" => %{"damping_seconds" => 0.5, "send_rate_hz" => 10.0}
               }
             })

    # Sampling should re-evaluate and apply the new pre_race rate (2 Hz -> 500 ms)
    # + damping (4.0s) on a config-changed notification.
    Sampling.reconfigure(s)
    assert_receive {:flush_interval, 500}
    assert_receive {:damping, 4.0}
  end

  test "reconfigure uses the supplied config without calling back into Tracking.Config" do
    commands = start_supervised!({Commands, device_id: "dev"})
    reporter = start_supervised!({StubReporter, self()})
    missing_config = :"missing_tracking_config_#{System.unique_integer([:positive])}"

    sampling =
      start_supervised!(
        {Sampling,
         commands: commands,
         reporter: reporter,
         tracking_config: missing_config,
         now_fn: fn -> @start end,
         reevaluate_interval_ms: 60_000}
      )

    assert_receive {:flush_interval, 1000}
    assert_receive {:damping, initial_damping}
    assert_in_delta initial_damping, 0.0, 1.0e-12

    supplied =
      put_in(@config, [:states, :pre_race], %{
        damping_seconds: 4.0,
        send_rate_hz: 2.0
      })

    assert :ok = Sampling.reconfigure(sampling, supplied)
    assert_receive {:flush_interval, 500}
    assert_receive {:damping, 4.0}
  end

  test "authoritative reconfigure reports an unavailable Reporter" do
    commands = start_supervised!({Commands, device_id: "dev"})
    missing_reporter = :"missing_reporter_#{System.unique_integer([:positive])}"
    missing_config = :"missing_tracking_config_#{System.unique_integer([:positive])}"

    sampling =
      start_supervised!(
        {Sampling,
         commands: commands,
         reporter: missing_reporter,
         tracking_config: missing_config,
         now_fn: fn -> @start end,
         reevaluate_interval_ms: 60_000}
      )

    assert {:error, :reporter_unavailable} = Sampling.reconfigure(sampling, @config)
  end

  test "the tracking status reflects what Sampling is applying" do
    %{sampling: s, commands: c} = start_sampling(DateTime.add(@start, 120, :second))
    apply_race_assignment(c, [])
    Sampling.reevaluate(s)

    status = Sampling.tracking_status(s)
    assert status.active_state == :race
    assert status.active_rate_hz == 10.0
    assert status.active_damping_seconds == 0.5
    assert status.applied_version == 0
  end
end
