defmodule RacingOrg.Tracker.Pro.DesiredState.OwnerReconciliationTest do
  use ExUnit.Case, async: false

  defmodule RemoveFaultFileSystem do
    @behaviour RacingOrg.Tracker.Pro.SecureTransport.KeyStore.FileSystem

    alias RacingOrg.Tracker.Pro.SecureTransport.KeyStore.FileSystem

    @fault_key {__MODULE__, :remove_fault}

    def arm, do: :persistent_term.put(@fault_key, true)
    def clear, do: :persistent_term.erase(@fault_key)

    def remove(path) do
      if :persistent_term.get(@fault_key, false),
        do: {:error, :remove_fault},
        else: FileSystem.remove(path)
    end

    defdelegate read(path), to: FileSystem
    defdelegate mkdir_p(path), to: FileSystem
    defdelegate chmod(path, mode), to: FileSystem
    defdelegate open(path, modes), to: FileSystem
    defdelegate write(device, contents), to: FileSystem
    defdelegate sync(device), to: FileSystem
    defdelegate close(device), to: FileSystem
    defdelegate rename(source, destination), to: FileSystem
  end

  alias RacingOrg.Tracker.Pro.Calibration.Config, as: CalibrationConfig
  alias RacingOrg.Tracker.Pro.Calibration.Store, as: CalibrationStore
  alias RacingOrg.Tracker.Pro.ClockSource.Config, as: ClockSourceConfig
  alias RacingOrg.Tracker.Pro.ClockSource.Store, as: ClockSourceStore
  alias RacingOrg.Tracker.Pro.Compute.Engine
  alias RacingOrg.Tracker.Pro.Compute.Store, as: ComputeStore
  alias RacingOrg.Tracker.Pro.DesiredStateTestSupport
  alias RacingOrg.Tracker.Pro.Tracking.Config, as: TrackingConfig
  alias RacingOrg.Tracker.Pro.Tracking.Store, as: TrackingStore
  alias RacingOrg.Tracker.Pro.Upstream.Config, as: UpstreamConfig
  alias RacingOrg.Tracker.Pro.Upstream.Store, as: UpstreamStore
  alias RacingOrg.Tracker.Pro.WindShift.Config, as: WindShiftConfig
  alias RacingOrg.Tracker.Pro.WindShift.Store, as: WindShiftStore

  @owners [
    {:calibration, CalibrationConfig},
    {:clock_source, ClockSourceConfig},
    {:computed_values, Engine},
    {:tracking, TrackingConfig},
    {:upstream, UpstreamConfig},
    {:wind_shift, WindShiftConfig}
  ]

  setup do
    base =
      Path.join(
        System.tmp_dir!(),
        "desired_state_owner_reconciliation_#{System.unique_integer([:positive])}"
      )

    on_exit(fn ->
      RemoveFaultFileSystem.clear()
      :persistent_term.erase({UpstreamConfig, :disabled_signals})
      File.rm_rf(base)
    end)

    %{base: base}
  end

  test "every config owner exposes pure desired-state validation" do
    contents = DesiredStateTestSupport.default_contents()

    Enum.each(@owners, fn {section, owner} ->
      assert {:ok, %{version: 1}} = owner.validate_config(Map.fetch!(contents, section))
      assert {:error, _reason} = owner.validate_config(%{"version" => "invalid"})
    end)
  end

  test "desired-state validation rejects malformed complete owner projections" do
    contents = DesiredStateTestSupport.default_contents()

    invalid = [
      {CalibrationConfig, Map.put(contents.calibration, "parameters", [])},
      {CalibrationConfig,
       Map.put(contents.calibration, "sensors", [
         %{"hardware_identifier" => "A1", "parameter" => "awa_offset", "locked" => true, "value" => nil}
       ])},
      {ClockSourceConfig, Map.put(contents.clock_source, "mode", "unknown")},
      {ClockSourceConfig, Map.put(contents.clock_source, "fallback", "sensor_priority")},
      {ClockSourceConfig, Map.put(contents.clock_source, "sources", [%{"priority" => "first"}])},
      {Engine,
       %{
         "version" => 1,
         "values" => [
           %{
             "id" => "value-1",
             "name" => "Value",
             "definition_type" => "expression",
             "library_key" => nil,
             "input_bindings" => [],
             "rpn" => [1.0],
             "signals" => [],
             "output_pgn" => nil,
             "output_field" => nil,
             "output_reference" => nil,
             "output_unit" => nil,
             "output_instance" => nil,
             "damping_seconds" => 0.0,
             "broadcast_rate_hz" => 1.0,
             "broadcast_enabled" => false,
             "stream_to_backend" => false
           }
         ]
       }},
      {TrackingConfig, Map.put(contents.tracking, "deviation_threshold_meters", 0)},
      {UpstreamConfig, Map.put(contents.upstream, "signals", Map.delete(contents.upstream["signals"], "wind"))},
      {WindShiftConfig,
       Map.put(contents.wind_shift, "windows", Map.put(contents.wind_shift["windows"], "fast_s", "fast"))},
      {WindShiftConfig,
       Map.put(contents.wind_shift, "alarms", Map.put(contents.wind_shift["alarms"], "enabled", "yes"))}
    ]

    Enum.each(invalid, fn {owner, content} ->
      assert {:error, _reason} = owner.validate_config(content)
    end)

    Enum.each(@owners, fn {section, owner} ->
      assert {:error, _reason} =
               owner.validate_config(Map.put(Map.fetch!(contents, section), "version", "1"))
    end)
  end

  test "forced reconciliation uses strict desired-state validation before persistence", %{base: base} do
    contents = DesiredStateTestSupport.default_contents()

    owners = [
      {CalibrationConfig, [name: nil, store_dir: Path.join(base, "strict-calibration")],
       Map.put(contents.calibration, "parameters", [])},
      {ClockSourceConfig, [name: nil, store_dir: Path.join(base, "strict-clock-source")],
       Map.put(contents.clock_source, "mode", "unknown")},
      {Engine,
       [
         name: nil,
         store_dir: Path.join(base, "strict-computed-values"),
         commands: nil,
         calibration: nil
       ],
       %{
         "version" => 1,
         "values" => [
           %{
             "id" => "value-1",
             "name" => "Value",
             "definition_type" => "expression",
             "library_key" => nil,
             "input_bindings" => [],
             "rpn" => [1.0],
             "signals" => [],
             "output_pgn" => nil,
             "output_field" => nil,
             "output_reference" => nil,
             "output_unit" => nil,
             "output_instance" => nil,
             "damping_seconds" => 0.0,
             "broadcast_rate_hz" => 1.0,
             "broadcast_enabled" => false,
             "stream_to_backend" => false
           }
         ]
       }},
      {TrackingConfig,
       [
         name: nil,
         store_dir: Path.join(base, "strict-tracking"),
         on_apply: fn _ -> flunk("invalid desired state must not apply") end
       ], Map.put(contents.tracking, "deviation_threshold_meters", 0)},
      {UpstreamConfig, [name: nil, store_dir: Path.join(base, "strict-upstream")],
       Map.put(contents.upstream, "signals", Map.delete(contents.upstream["signals"], "wind"))},
      {WindShiftConfig, [name: nil, store_dir: Path.join(base, "strict-wind-shift")],
       Map.put(contents.wind_shift, "windows", Map.put(contents.wind_shift["windows"], "fast_s", "fast"))}
    ]

    Enum.each(owners, fn {owner, opts, invalid} ->
      pid = start_supervised!({owner, opts})
      assert {:error, _reason} = owner.reconcile_config(pid, invalid)
      assert owner.applied_version(pid) == nil
    end)
  end

  test "legacy apply_config keeps its established lenient defaults", %{base: base} do
    tracking =
      start_supervised!(
        {TrackingConfig, name: nil, store_dir: Path.join(base, "legacy-tracking"), on_apply: fn _config -> :ok end}
      )

    legacy =
      DesiredStateTestSupport.default_contents().tracking
      |> Map.delete("deviation_threshold_meters")

    assert {:ok, %{deviation_threshold_meters: 50.0}} = TrackingConfig.apply_config(tracking, legacy)
  end

  test "forced reconciliation bypasses only legacy version monotonicity", %{base: base} do
    pid =
      start_supervised!(
        {TrackingConfig,
         name: nil, store_dir: Path.join(base, "tracking"), on_apply: fn config -> send(self(), {:applied, config}) end}
      )

    newer = tracking_config(8, 8.0)
    desired = tracking_config(2, 2.0)

    assert {:ok, %{version: 8}} = TrackingConfig.apply_config(pid, newer)
    assert {:ok, :unchanged} = TrackingConfig.apply_config(pid, desired)
    assert TrackingConfig.get_state(pid, :race).send_rate_hz == 8.0

    assert {:ok, %{version: 2}} = TrackingConfig.reconcile_config(pid, desired)
    assert TrackingConfig.applied_version(pid) == 2
    assert TrackingConfig.get_state(pid, :race).send_rate_hz == 2.0
  end

  test "forced reconciliation does not mutate owner state when durable persistence fails", %{
    base: base
  } do
    blocker = Path.join(base, "not-a-directory")
    File.mkdir_p!(base)
    File.write!(blocker, "file")

    pid =
      start_supervised!(
        {TrackingConfig,
         name: nil,
         store_dir: Path.join(blocker, "tracking"),
         on_apply: fn _config -> flunk("failed persistence must not trigger owner side effects") end}
      )

    assert {:error, _reason} = TrackingConfig.reconcile_config(pid, tracking_config(3, 3.0))
    assert TrackingConfig.applied_version(pid) == nil
    assert TrackingConfig.get_state(pid, :race).send_rate_hz == 1.0
  end

  test "every config owner durably resets to its compile default", %{base: base} do
    contents = DesiredStateTestSupport.default_contents()

    calibration_dir = Path.join(base, "reset-calibration")
    calibration = start_supervised!({CalibrationConfig, name: nil, store_dir: calibration_dir})
    calibration_config = put_in(contents.calibration, ["parameters", "awa_offset", "mode"], "off")
    assert {:ok, %{version: 1}} = CalibrationConfig.reconcile_config(calibration, calibration_config)

    assert :ok =
             CalibrationConfig.put_learned(calibration, "A1", "stw_scale", %{
               value: 1.05,
               confidence: 0.9,
               sample_count: 30,
               state: "applied"
             })

    assert CalibrationConfig.status(calibration).modes["awa_offset"] == "off"
    assert CalibrationConfig.status(calibration).sensors != []
    assert :ok = CalibrationConfig.subscribe(calibration)
    assert :ok = CalibrationConfig.reset_config(calibration)
    assert_receive {:racing_org_calibration, :updated}
    assert CalibrationConfig.applied_version(calibration) == nil
    assert CalibrationConfig.status(calibration).modes["awa_offset"] == "auto"
    assert CalibrationConfig.status(calibration).sensors == []
    assert CalibrationConfig.corrections(calibration) == %{}
    assert CalibrationStore.load(calibration_dir) == :empty

    clock_source_dir = Path.join(base, "reset-clock-source")
    clock_source = start_supervised!({ClockSourceConfig, name: nil, store_dir: clock_source_dir})
    clock_source_config = Map.put(contents.clock_source, "mode", "sensor_priority")
    assert {:ok, %{version: 1}} = ClockSourceConfig.reconcile_config(clock_source, clock_source_config)
    assert ClockSourceConfig.status(clock_source).mode == "sensor_priority"
    assert :ok = ClockSourceConfig.reset_config(clock_source)
    assert ClockSourceConfig.applied_version(clock_source) == nil
    assert ClockSourceConfig.status(clock_source).mode == "tracker_receive_time"
    assert ClockSourceStore.load(clock_source_dir) == :empty

    computed_values_dir = Path.join(base, "reset-computed-values")

    engine =
      start_supervised!({Engine, name: nil, store_dir: computed_values_dir, commands: nil, calibration: nil})

    assert {:ok, %{version: 1}} = Engine.reconcile_config(engine, computed_values_config())
    assert length(Engine.current_values(engine)) == 1
    assert :ok = Engine.reset_config(engine)
    assert Engine.applied_version(engine) == nil
    assert Engine.current_values(engine) == []
    assert ComputeStore.load(computed_values_dir) == :empty

    tracking_dir = Path.join(base, "reset-tracking")
    test_pid = self()

    tracking =
      start_supervised!(
        {TrackingConfig,
         name: nil, store_dir: tracking_dir, on_apply: fn config -> send(test_pid, {:tracking_applied, config}) end}
      )

    assert {:ok, %{version: 1}} = TrackingConfig.reconcile_config(tracking, tracking_config(1, 8.0))
    assert_receive {:tracking_applied, %{version: 1}}
    assert TrackingConfig.get_state(tracking, :race).send_rate_hz == 8.0
    assert :ok = TrackingConfig.reset_config(tracking)
    assert_receive {:tracking_applied, %{version: nil}}
    assert TrackingConfig.applied_version(tracking) == nil
    assert TrackingConfig.get_state(tracking, :race).send_rate_hz == 1.0
    assert TrackingStore.load(tracking_dir) == :empty

    upstream_dir = Path.join(base, "reset-upstream")
    upstream = start_supervised!({UpstreamConfig, store_dir: upstream_dir})
    upstream_config = put_in(contents.upstream, ["signals", "wind"], false)
    assert {:ok, %{version: 1}} = UpstreamConfig.reconcile_config(upstream, upstream_config)
    refute UpstreamConfig.stream?(upstream, :wind)
    refute UpstreamConfig.stream_signal?(:wind)
    assert :ok = UpstreamConfig.reset_config(upstream)
    assert UpstreamConfig.applied_version(upstream) == nil
    assert UpstreamConfig.stream?(upstream, :wind)
    assert UpstreamConfig.stream_signal?(:wind)
    assert UpstreamStore.load(upstream_dir) == :empty

    wind_shift_dir = Path.join(base, "reset-wind-shift")
    wind_shift = start_supervised!({WindShiftConfig, name: nil, store_dir: wind_shift_dir})
    wind_shift_config = put_in(contents.wind_shift, ["wally", "mode"], "on")
    assert {:ok, %{version: 1}} = WindShiftConfig.reconcile_config(wind_shift, wind_shift_config)
    assert WindShiftConfig.current(wind_shift).wally_mode == "on"
    assert :ok = WindShiftConfig.subscribe(wind_shift)
    assert :ok = WindShiftConfig.reset_config(wind_shift)
    assert_receive {:racing_org_wind_shift, :updated}
    assert WindShiftConfig.applied_version(wind_shift) == nil
    assert WindShiftConfig.current(wind_shift).wally_mode == "off"
    assert WindShiftStore.load(wind_shift_dir) == :empty
  end

  test "a durable clear failure leaves every owner on its candidate authority", %{base: base} do
    contents = DesiredStateTestSupport.default_contents()
    test_pid = self()

    calibration_dir = Path.join(base, "failed-reset-calibration")

    calibration =
      start_supervised!({CalibrationConfig, name: nil, store_dir: calibration_dir, file_system: RemoveFaultFileSystem})

    calibration_config = put_in(contents.calibration, ["parameters", "awa_offset", "mode"], "off")
    assert {:ok, %{version: 1}} = CalibrationConfig.reconcile_config(calibration, calibration_config)
    assert :ok = CalibrationConfig.subscribe(calibration)

    clock_source_dir = Path.join(base, "failed-reset-clock-source")

    clock_source =
      start_supervised!({ClockSourceConfig, name: nil, store_dir: clock_source_dir, file_system: RemoveFaultFileSystem})

    clock_source_config = Map.put(contents.clock_source, "mode", "sensor_priority")
    assert {:ok, %{version: 1}} = ClockSourceConfig.reconcile_config(clock_source, clock_source_config)

    computed_values_dir = Path.join(base, "failed-reset-computed-values")

    engine =
      start_supervised!(
        {Engine,
         name: nil, store_dir: computed_values_dir, commands: nil, calibration: nil, file_system: RemoveFaultFileSystem}
      )

    assert {:ok, %{version: 1}} = Engine.reconcile_config(engine, computed_values_config())

    tracking_dir = Path.join(base, "failed-reset-tracking")

    tracking =
      start_supervised!(
        {TrackingConfig,
         name: nil,
         store_dir: tracking_dir,
         file_system: RemoveFaultFileSystem,
         on_apply: fn config -> send(test_pid, {:failed_reset_tracking_applied, config}) end}
      )

    assert {:ok, %{version: 1}} = TrackingConfig.reconcile_config(tracking, tracking_config(1, 8.0))
    assert_receive {:failed_reset_tracking_applied, %{version: 1}}

    upstream_dir = Path.join(base, "failed-reset-upstream")

    upstream =
      start_supervised!({UpstreamConfig, store_dir: upstream_dir, file_system: RemoveFaultFileSystem})

    upstream_config = put_in(contents.upstream, ["signals", "wind"], false)
    assert {:ok, %{version: 1}} = UpstreamConfig.reconcile_config(upstream, upstream_config)

    wind_shift_dir = Path.join(base, "failed-reset-wind-shift")

    wind_shift =
      start_supervised!({WindShiftConfig, name: nil, store_dir: wind_shift_dir, file_system: RemoveFaultFileSystem})

    wind_shift_config = put_in(contents.wind_shift, ["wally", "mode"], "on")
    assert {:ok, %{version: 1}} = WindShiftConfig.reconcile_config(wind_shift, wind_shift_config)
    assert :ok = WindShiftConfig.subscribe(wind_shift)

    RemoveFaultFileSystem.arm()

    expected_error = {:error, {:pre_remove, {:remove, :remove_fault}}}
    assert ^expected_error = CalibrationConfig.reset_config(calibration)
    assert ^expected_error = ClockSourceConfig.reset_config(clock_source)
    assert ^expected_error = Engine.reset_config(engine)
    assert ^expected_error = TrackingConfig.reset_config(tracking)
    assert ^expected_error = UpstreamConfig.reset_config(upstream)
    assert ^expected_error = WindShiftConfig.reset_config(wind_shift)

    assert CalibrationConfig.applied_version(calibration) == 1
    assert CalibrationConfig.status(calibration).modes["awa_offset"] == "off"
    assert ClockSourceConfig.status(clock_source).mode == "sensor_priority"
    assert length(Engine.current_values(engine)) == 1
    assert TrackingConfig.get_state(tracking, :race).send_rate_hz == 8.0
    refute UpstreamConfig.stream?(upstream, :wind)
    refute UpstreamConfig.stream_signal?(:wind)
    assert WindShiftConfig.current(wind_shift).wally_mode == "on"

    refute_receive {:racing_org_calibration, :updated}
    refute_receive {:failed_reset_tracking_applied, %{version: nil}}
    refute_receive {:racing_org_wind_shift, :updated}

    assert {:ok, _config} = CalibrationStore.load(calibration_dir)
    assert {:ok, _config} = ClockSourceStore.load(clock_source_dir)
    assert {:ok, _config} = ComputeStore.load(computed_values_dir)
    assert {:ok, _config} = TrackingStore.load(tracking_dir)
    assert {:ok, _config} = UpstreamStore.load(upstream_dir)
    assert {:ok, _config} = WindShiftStore.load(wind_shift_dir)
  end

  defp computed_values_config do
    %{
      "version" => 1,
      "values" => [
        %{
          "id" => "constant",
          "name" => "Constant",
          "definition_type" => "expression",
          "library_key" => nil,
          "input_bindings" => %{},
          "rpn" => [1.0],
          "signals" => [],
          "output_pgn" => nil,
          "output_field" => nil,
          "output_reference" => nil,
          "output_unit" => nil,
          "output_instance" => nil,
          "damping_seconds" => 0.0,
          "broadcast_rate_hz" => 1.0,
          "broadcast_enabled" => false,
          "stream_to_backend" => false
        }
      ]
    }
  end

  defp tracking_config(version, race_rate) do
    %{
      "version" => version,
      "states" => %{
        "pre_race" => %{"damping_seconds" => 0.0, "send_rate_hz" => 1.0},
        "starting" => %{"damping_seconds" => 0.0, "send_rate_hz" => 1.0},
        "race" => %{"damping_seconds" => 0.0, "send_rate_hz" => race_rate}
      },
      "deviation_threshold_meters" => 50.0
    }
  end
end
