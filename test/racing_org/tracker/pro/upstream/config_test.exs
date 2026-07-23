defmodule RacingOrg.Tracker.Pro.Upstream.ConfigTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.Upstream.Config
  alias RacingOrg.Tracker.Pro.Upstream.Store

  setup do
    dir = Path.join(System.tmp_dir!(), "nn_upstream_cfg_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  # Wire-shape payload (string keys, as it arrives over the Slipstream channel) —
  # the backend's Devices.upstream_config_for_push/1 shape.
  defp payload(version, overrides \\ %{}) do
    signals =
      Map.merge(
        %{
          "heading" => true,
          "speed" => true,
          "velocity" => true,
          "wind" => true,
          "water_depth" => true,
          "attitude" => true
        },
        overrides
      )

    %{"version" => version, "signals" => signals}
  end

  defp start(opts) do
    base = [name: nil, store_dir: opts[:dir]]
    start_supervised!({Config, Keyword.merge(base, Keyword.delete(opts, :dir))})
  end

  describe "apply_config/2 — version 0 is a real config applied on first receipt" do
    test "applies version 0 on first receipt", %{dir: dir} do
      pid = start(dir: dir)

      assert {:ok, applied} = Config.apply_config(pid, payload(0, %{"wind" => false}))
      assert applied.version == 0
      assert applied.signals.wind == false
      assert applied.signals.heading == true
      assert Config.applied_version(pid) == 0
    end

    test "persists the applied config to the store", %{dir: dir} do
      pid = start(dir: dir)
      assert {:ok, _} = Config.apply_config(pid, payload(3, %{"attitude" => false}))

      assert {:ok, persisted} = Store.load(dir)
      assert persisted.version == 3
      assert persisted.signals.attitude == false
    end

    test "is idempotent on version — a re-push of the same version is unchanged", %{dir: dir} do
      pid = start(dir: dir)
      assert {:ok, _} = Config.apply_config(pid, payload(2, %{"wind" => false}))
      assert {:ok, :unchanged} = Config.apply_config(pid, payload(2, %{"wind" => true}))
      # The stale re-push did not overwrite the applied signals.
      refute Config.stream?(pid, :wind)
    end

    test "an older version is ignored", %{dir: dir} do
      pid = start(dir: dir)
      assert {:ok, _} = Config.apply_config(pid, payload(5))
      assert {:ok, :unchanged} = Config.apply_config(pid, payload(4, %{"speed" => false}))
      assert Config.stream?(pid, :speed)
    end

    test "a malformed payload is rejected without changing state", %{dir: dir} do
      pid = start(dir: dir)
      assert {:ok, _} = Config.apply_config(pid, payload(1, %{"wind" => false}))
      assert {:error, _reason} = Config.apply_config(pid, %{"version" => "nope"})
      assert {:error, _reason} = Config.apply_config(pid, %{"version" => 2, "signals" => %{"wind" => "sometimes"}})
      assert Config.applied_version(pid) == 1
      refute Config.stream?(pid, :wind)
    end

    test "unknown signal keys are tolerated (forward compatibility)", %{dir: dir} do
      pid = start(dir: dir)
      assert {:ok, applied} = Config.apply_config(pid, payload(1, %{"future_signal" => false}))
      refute Map.has_key?(applied.signals, :future_signal)
    end
  end

  describe "boot state" do
    test "with no persisted config every signal streams and applied_version is nil", %{dir: dir} do
      pid = start(dir: dir)
      assert Config.applied_version(pid) == nil

      for signal <- [:heading, :speed, :velocity, :wind, :water_depth, :attitude] do
        assert Config.stream?(pid, signal), "expected #{signal} to stream by default"
      end
    end

    test "a persisted config is loaded on boot and treated as already applied", %{dir: dir} do
      pid = start(dir: dir)
      assert {:ok, _} = Config.apply_config(pid, payload(4, %{"water_depth" => false}))
      stop_supervised!(Config)

      pid2 = start(dir: dir)
      assert Config.applied_version(pid2) == 4
      refute Config.stream?(pid2, :water_depth)
      # The same version re-pushed after reboot is a no-op.
      assert {:ok, :unchanged} = Config.apply_config(pid2, payload(4))
    end
  end

  describe "the hot-path read (used by Telemetry per sample)" do
    test "stream_signal?/1 reads the module-registered instance without a call", %{dir: dir} do
      # The default-named instance registers itself for the zero-cost global read.
      start_supervised!({Config, store_dir: dir})
      assert Config.stream_signal?(:wind)

      assert {:ok, _} = Config.apply_config(Config, payload(1, %{"wind" => false}))
      refute Config.stream_signal?(:wind)
      assert Config.stream_signal?(:heading)
    end

    test "stream_signal?/1 defaults to true when no instance is running" do
      # No named Config started in this branch: everything streams (fail-open —
      # dropping telemetry because a config process is down would be data loss).
      assert Config.stream_signal?(:attitude)
    end

    test "position is never a filterable signal", %{dir: dir} do
      start_supervised!({Config, store_dir: dir})
      # Even a hostile payload claiming position: false cannot disable it.
      assert {:ok, _} = Config.apply_config(Config, %{"version" => 1, "signals" => %{"position" => false}})
      assert Config.stream_signal?(:position)
    end
  end

  describe "upstream_status/1 (the channel echo)" do
    test "reports nil before any config and the version after", %{dir: dir} do
      pid = start(dir: dir)
      assert %{applied_version: nil} = Config.upstream_status(pid)

      assert {:ok, _} = Config.apply_config(pid, payload(7))
      assert %{applied_version: 7} = Config.upstream_status(pid)
    end
  end
end
