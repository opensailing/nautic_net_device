defmodule RacingOrg.Tracker.Pro.Tracking.ConfigTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.Tracking.Config
  alias RacingOrg.Tracker.Pro.Tracking.Store

  setup do
    dir = Path.join(System.tmp_dir!(), "nn_tracking_cfg_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  # Wire-shape payload (string keys, as it arrives over the Slipstream channel).
  defp payload(version) do
    %{
      "version" => version,
      "states" => %{
        "pre_race" => %{"damping_seconds" => 2.0, "send_rate_hz" => 1.0},
        "starting" => %{"damping_seconds" => 1.0, "send_rate_hz" => 5.0},
        "race" => %{"damping_seconds" => 0.5, "send_rate_hz" => 10.0}
      }
    }
  end

  defp desired_payload(version) do
    Map.put(payload(version), "deviation_threshold_meters", 50.0)
  end

  defp start(opts) do
    parent = self()

    base =
      [
        name: nil,
        store_dir: opts[:dir],
        on_apply: fn applied -> send(parent, {:on_apply, applied}) end
      ]

    start_supervised!({Config, Keyword.merge(base, Keyword.delete(opts, :dir))})
  end

  describe "apply_config/2 — version 0 is a real config applied on first receipt" do
    test "applies version 0 on first receipt (applied_version starts below 0)", %{dir: dir} do
      pid = start(dir: dir)

      assert {:ok, applied} = Config.apply_config(pid, payload(0))
      assert applied.version == 0
      assert applied.states.race == %{damping_seconds: 0.5, send_rate_hz: 10.0}

      # The applied version is now 0 and reflected in status.
      assert Config.applied_version(pid) == 0
      assert Config.get_state(pid, :race) == %{damping_seconds: 0.5, send_rate_hz: 10.0}
    end

    test "invokes the injected on_apply side-effect with the applied config", %{dir: dir} do
      pid = start(dir: dir)
      assert {:ok, _} = Config.apply_config(pid, payload(0))
      assert_receive {:on_apply, applied}
      assert applied.version == 0
    end

    test "persists the applied config to the store", %{dir: dir} do
      pid = start(dir: dir)
      assert {:ok, _} = Config.apply_config(pid, payload(0))

      assert {:ok, persisted} = Store.load(dir)
      assert persisted.version == 0
      assert persisted.states.starting == %{damping_seconds: 1.0, send_rate_hz: 5.0}
    end
  end

  describe "idempotency on version" do
    test "re-applying the same version is a no-op", %{dir: dir} do
      pid = start(dir: dir)
      assert {:ok, _} = Config.apply_config(pid, payload(0))
      assert_receive {:on_apply, _}

      assert {:ok, :unchanged} = Config.apply_config(pid, payload(0))
      refute_receive {:on_apply, _}, 50
    end

    test "applying an older version is a no-op", %{dir: dir} do
      pid = start(dir: dir)
      assert {:ok, _} = Config.apply_config(pid, payload(3))
      assert_receive {:on_apply, _}

      assert {:ok, :unchanged} = Config.apply_config(pid, payload(2))
      refute_receive {:on_apply, _}, 50
      assert Config.applied_version(pid) == 3
    end

    test "applying a newer version is applied", %{dir: dir} do
      pid = start(dir: dir)
      assert {:ok, _} = Config.apply_config(pid, payload(0))
      assert_receive {:on_apply, _}

      assert {:ok, applied} = Config.apply_config(pid, payload(1))
      assert applied.version == 1
      assert_receive {:on_apply, %{version: 1}}
      assert Config.applied_version(pid) == 1
    end
  end

  describe "boot reconciliation" do
    test "loads a persisted config on boot and treats it as applied", %{dir: dir} do
      Store.save(dir, %{
        version: 7,
        states: %{
          pre_race: %{damping_seconds: 3.0, send_rate_hz: 2.0},
          starting: %{damping_seconds: 1.5, send_rate_hz: 4.0},
          race: %{damping_seconds: 0.25, send_rate_hz: 8.0}
        }
      })

      pid = start(dir: dir)

      assert Config.applied_version(pid) == 7
      assert Config.get_state(pid, :pre_race) == %{damping_seconds: 3.0, send_rate_hz: 2.0}

      # A re-push of the same version is then a no-op.
      assert {:ok, :unchanged} = Config.apply_config(pid, payload(7))
    end

    test "with no persisted config, applied_version is nil and states use safe defaults", %{dir: dir} do
      pid = start(dir: dir)
      assert Config.applied_version(pid) == nil
      # A get_state before any config returns a sane default (1 Hz, no damping).
      assert %{damping_seconds: _, send_rate_hz: hz} = Config.get_state(pid, :race)
      assert hz > 0
    end
  end

  describe "status/1" do
    test "reports the applied version + all three states", %{dir: dir} do
      pid = start(dir: dir)
      assert {:ok, _} = Config.apply_config(pid, payload(0))

      status = Config.status(pid)
      assert status.applied_version == 0
      assert status.states.race == %{damping_seconds: 0.5, send_rate_hz: 10.0}
    end
  end

  describe "authoritative side effects" do
    test "legacy apply does not publish owner state when its side effect fails", %{dir: dir} do
      {:ok, callback_result} = Agent.start_link(fn -> {:error, :sampling_unavailable} end)

      pid =
        start_supervised!(
          {Config, name: nil, store_dir: dir, on_apply: fn _config -> Agent.get(callback_result, & &1) end}
        )

      assert {:error, {:on_apply_failed, :sampling_unavailable}} =
               Config.apply_config(pid, payload(1))

      assert {:ok, %{version: 1}} = Store.load(dir)
      assert Config.applied_version(pid) == nil
      assert Config.get_state(pid, :race) == %{damping_seconds: 0.0, send_rate_hz: 1.0}

      Agent.update(callback_result, fn _result -> :ok end)
      assert {:ok, %{version: 1}} = Config.apply_config(pid, payload(1))
    end

    test "legacy apply does not publish or run side effects when persistence fails", %{dir: dir} do
      File.mkdir_p!(dir)
      blocked_dir = Path.join(dir, "not_a_directory")
      File.write!(blocked_dir, "blocked")
      parent = self()

      pid =
        start_supervised!(
          {Config, name: nil, store_dir: blocked_dir, on_apply: fn config -> send(parent, {:on_apply, config}) end}
        )

      assert {:error, _reason} = Config.apply_config(pid, payload(1))
      assert Config.applied_version(pid) == nil
      refute_receive {:on_apply, _config}
    end

    test "reconcile sanitizes a raised side-effect failure", %{dir: dir} do
      pid =
        start_supervised!(
          {Config, name: nil, store_dir: dir, on_apply: fn _config -> raise "sensitive callback detail" end}
        )

      assert {:error, {:on_apply_failed, :exception}} =
               Config.reconcile_config(pid, desired_payload(1))

      assert Process.alive?(pid)
      assert Config.applied_version(pid) == nil
    end

    test "reset reports a side-effect failure after durably returning to defaults", %{dir: dir} do
      pid =
        start_supervised!(
          {Config,
           name: nil,
           store_dir: dir,
           on_apply: fn
             %{version: nil} -> {:error, :sampling_unavailable}
             _config -> :ok
           end}
        )

      assert {:ok, %{version: 1}} = Config.reconcile_config(pid, desired_payload(1))

      assert {:error, {:on_apply_failed, :sampling_unavailable}} =
               Config.reset_config(pid)

      assert Store.load(dir) == :empty
      assert Config.applied_version(pid) == nil
      assert Config.get_state(pid, :race) == %{damping_seconds: 0.0, send_rate_hz: 1.0}
    end

    test "reconcile does not publish owner state when its side effect fails", %{dir: dir} do
      {:ok, callback_result} = Agent.start_link(fn -> {:error, :sampling_unavailable} end)

      pid =
        start_supervised!(
          {Config, name: nil, store_dir: dir, on_apply: fn _config -> Agent.get(callback_result, & &1) end}
        )

      assert {:error, {:on_apply_failed, :sampling_unavailable}} =
               Config.reconcile_config(pid, desired_payload(1))

      assert {:ok, %{version: 1}} = Store.load(dir)
      assert Config.applied_version(pid) == nil
      assert Config.get_state(pid, :race) == %{damping_seconds: 0.0, send_rate_hz: 1.0}

      Agent.update(callback_result, fn _result -> :ok end)
      assert {:ok, %{version: 1}} = Config.reconcile_config(pid, desired_payload(1))
      assert Config.get_state(pid, :race) == %{damping_seconds: 0.5, send_rate_hz: 10.0}
    end
  end

  # P3: the server pushes the route-deviation threshold (meters) in the SAME
  # set_tracking payload. The Config parses + persists + exposes it; the
  # DeviationMonitor reads it. Absent (older server) -> a safe 50.0 m default.
  describe "deviation_threshold_meters" do
    test "defaults to 50.0 m before any config is applied", %{dir: dir} do
      pid = start(dir: dir)
      assert Config.deviation_threshold(pid) == 50.0
    end

    test "reads deviation_threshold_meters from the set_tracking payload", %{dir: dir} do
      pid = start(dir: dir)
      payload = Map.put(payload(0), "deviation_threshold_meters", 75.0)
      assert {:ok, applied} = Config.apply_config(pid, payload)
      assert applied.deviation_threshold_meters == 75.0
      assert Config.deviation_threshold(pid) == 75.0
    end

    test "defaults to 50.0 m when the payload omits the threshold (older server)", %{dir: dir} do
      pid = start(dir: dir)
      assert {:ok, applied} = Config.apply_config(pid, payload(0))
      assert applied.deviation_threshold_meters == 50.0
      assert Config.deviation_threshold(pid) == 50.0
    end

    test "accepts an integer threshold and coerces it to a float", %{dir: dir} do
      pid = start(dir: dir)
      payload = Map.put(payload(0), "deviation_threshold_meters", 40)
      assert {:ok, applied} = Config.apply_config(pid, payload)
      assert applied.deviation_threshold_meters == 40.0
    end

    test "ignores a non-positive / malformed threshold and keeps the default", %{dir: dir} do
      pid = start(dir: dir)
      payload = Map.put(payload(0), "deviation_threshold_meters", -5.0)
      assert {:ok, applied} = Config.apply_config(pid, payload)
      assert applied.deviation_threshold_meters == 50.0
    end

    test "a newer config updates the threshold (mid-race change takes effect)", %{dir: dir} do
      pid = start(dir: dir)
      assert {:ok, _} = Config.apply_config(pid, Map.put(payload(0), "deviation_threshold_meters", 60.0))
      assert Config.deviation_threshold(pid) == 60.0

      assert {:ok, _} = Config.apply_config(pid, Map.put(payload(1), "deviation_threshold_meters", 120.0))
      assert Config.deviation_threshold(pid) == 120.0
    end

    test "persists + reloads the threshold across a reboot", %{dir: dir} do
      pid = start(dir: dir)
      assert {:ok, _} = Config.apply_config(pid, Map.put(payload(0), "deviation_threshold_meters", 88.0))
      assert {:ok, persisted} = Store.load(dir)
      assert persisted.deviation_threshold_meters == 88.0

      # A fresh manager started on the same dir reconciles the persisted threshold.
      pid2 =
        start_supervised!(
          {Config, name: nil, store_dir: dir, on_apply: fn _ -> :ok end},
          id: {Config, :reload}
        )

      assert Config.deviation_threshold(pid2) == 88.0
    end

    test "status includes the deviation threshold", %{dir: dir} do
      pid = start(dir: dir)
      assert {:ok, _} = Config.apply_config(pid, Map.put(payload(0), "deviation_threshold_meters", 65.0))
      assert Config.status(pid).deviation_threshold_meters == 65.0
    end
  end
end
