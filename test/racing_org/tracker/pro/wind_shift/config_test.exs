defmodule RacingOrg.Tracker.Pro.WindShift.ConfigTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.WindShift.Config

  # --- helpers ---

  defp start_config(opts \\ []) do
    opts = opts |> Keyword.put_new(:name, nil) |> Keyword.put_new(:store_dir, nil)
    {:ok, pid} = Config.start_link(opts)
    pid
  end

  @default_windows %{fast_s: 30.0, mid_s: 300.0, slow_s: 1500.0, envelope_s: 1800.0}
  @default_alarms %{new_extreme_margin_deg: 2.0, enabled: true}

  # --- default behavior ---

  test "with no config applied the defaults are live" do
    pid = start_config()
    assert Config.applied_version(pid) == nil

    current = Config.current(pid)
    assert current.version == nil
    assert current.windows == @default_windows
    assert current.alarms == @default_alarms
    assert current.wally_mode == "off"

    status = Config.status(pid)
    assert status.applied_version == nil
    assert status.wally_mode == "off"
    assert status.status == "ok"
  end

  # --- versioned idempotency ---

  test "applying config is idempotent by version" do
    pid = start_config()

    assert {:ok, %{version: 1}} = Config.apply_config(pid, %{"version" => 1})
    assert Config.applied_version(pid) == 1

    # same and older versions are no-ops
    assert {:ok, :unchanged} = Config.apply_config(pid, %{"version" => 1})
    assert {:ok, :unchanged} = Config.apply_config(pid, %{"version" => 0})
    assert Config.applied_version(pid) == 1

    # a newer version applies
    assert {:ok, %{version: 2}} = Config.apply_config(pid, %{"version" => 2})
    assert Config.applied_version(pid) == 2
  end

  test "the first config (even version 0) is always applied" do
    pid = start_config()
    assert {:ok, %{version: 0}} = Config.apply_config(pid, %{"version" => 0})
    assert Config.applied_version(pid) == 0
  end

  test "a malformed config (no version) is rejected and nothing is applied" do
    pid = start_config()
    assert {:error, :bad_version} = Config.apply_config(pid, %{"wally" => %{"mode" => "on"}})
    assert Config.applied_version(pid) == nil
  end

  # --- normalization: defaults on omission, unknown keys ignored ---

  test "a bare-version config applies all defaults" do
    pid = start_config()
    assert {:ok, config} = Config.apply_config(pid, %{"version" => 1})
    assert config.windows == @default_windows
    assert config.alarms == @default_alarms
    assert config.wally_mode == "off"
  end

  test "windows/alarms/wally apply from the wire map (string keys)" do
    pid = start_config()

    assert {:ok, config} =
             Config.apply_config(pid, %{
               "version" => 4,
               "windows" => %{"fast_s" => 20, "mid_s" => 240, "slow_s" => 1200, "envelope_s" => 900},
               "alarms" => %{"new_extreme_margin_deg" => 3.5, "enabled" => false},
               "wally" => %{"mode" => "shadow"}
             })

    assert config.windows == %{fast_s: 20.0, mid_s: 240.0, slow_s: 1200.0, envelope_s: 900.0}
    assert config.alarms == %{new_extreme_margin_deg: 3.5, enabled: false}
    assert config.wally_mode == "shadow"
    assert Config.status(pid).wally_mode == "shadow"
  end

  test "atom keys are accepted too" do
    pid = start_config()

    assert {:ok, config} =
             Config.apply_config(pid, %{version: 2, windows: %{fast_s: 15}, wally: %{mode: "on"}})

    assert config.windows.fast_s == 15.0
    # unspecified windows keep their defaults
    assert config.windows.mid_s == 300.0
    assert config.wally_mode == "on"
  end

  test "partially-specified windows/alarms default the missing keys" do
    pid = start_config()

    assert {:ok, config} =
             Config.apply_config(pid, %{
               "version" => 1,
               "windows" => %{"envelope_s" => 1200},
               "alarms" => %{"enabled" => false}
             })

    assert config.windows == %{@default_windows | envelope_s: 1200.0}
    assert config.alarms == %{@default_alarms | enabled: false}
  end

  test "unknown keys are ignored, invalid window values fall back to defaults" do
    pid = start_config()

    assert {:ok, config} =
             Config.apply_config(pid, %{
               "version" => 1,
               "windows" => %{"fast_s" => "bogus", "mid_s" => -5, "unknown" => 1},
               "alarms" => %{"new_extreme_margin_deg" => "x"},
               "surprise" => %{"key" => true}
             })

    assert config.windows == @default_windows
    assert config.alarms == @default_alarms
  end

  # --- wally mode validation ---

  test "a bad wally mode is rejected and nothing is applied" do
    pid = start_config()
    assert {:error, :bad_wally_mode} = Config.apply_config(pid, %{"version" => 1, "wally" => %{"mode" => "bogus"}})
    assert Config.applied_version(pid) == nil
    assert Config.current(pid).wally_mode == "off"
  end

  test "all valid wally modes apply" do
    for {version, mode} <- Enum.with_index(["off", "shadow", "on"], 1) |> Enum.map(fn {m, i} -> {i, m} end) do
      pid = start_config()
      assert {:ok, config} = Config.apply_config(pid, %{"version" => version, "wally" => %{"mode" => mode}})
      assert config.wally_mode == mode
    end
  end

  test "a missing wally mode defaults to off (only a BAD mode rejects)" do
    pid = start_config()
    assert {:ok, config} = Config.apply_config(pid, %{"version" => 1, "wally" => %{}})
    assert config.wally_mode == "off"
  end

  # --- subscriptions ---

  test "subscribers are notified on apply (not on unchanged/rejected)" do
    pid = start_config()
    assert :ok = Config.subscribe(pid, self())

    assert {:ok, _} = Config.apply_config(pid, %{"version" => 1})
    assert_receive {:racing_org_wind_shift, :updated}

    assert {:ok, :unchanged} = Config.apply_config(pid, %{"version" => 1})
    refute_receive {:racing_org_wind_shift, :updated}, 50

    assert {:error, :bad_wally_mode} = Config.apply_config(pid, %{"version" => 2, "wally" => %{"mode" => "x"}})
    refute_receive {:racing_org_wind_shift, :updated}, 50
  end

  # --- persistence ---

  describe "persistence" do
    setup do
      dir = Path.join(System.tmp_dir!(), "wind_shift_config_test_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(dir) end)
      {:ok, dir: dir}
    end

    test "config survives a restart and is treated as already-applied", %{dir: dir} do
      pid = start_config(store_dir: dir)

      {:ok, _} =
        Config.apply_config(pid, %{"version" => 5, "windows" => %{"fast_s" => 20}, "wally" => %{"mode" => "on"}})

      :ok = GenServer.stop(pid)

      pid2 = start_config(store_dir: dir)
      assert Config.applied_version(pid2) == 5
      assert Config.current(pid2).windows.fast_s == 20.0
      assert Config.current(pid2).wally_mode == "on"

      # re-pushing the same version is a no-op; a newer one still applies
      assert {:ok, :unchanged} = Config.apply_config(pid2, %{"version" => 5})
      assert {:ok, %{version: 6}} = Config.apply_config(pid2, %{"version" => 6})
    end

    test "a corrupt persisted store falls back to safe defaults", %{dir: dir} do
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "current.wind_shift"), "garbage")

      pid = start_config(store_dir: dir)
      assert Config.applied_version(pid) == nil
      assert Config.current(pid).windows == @default_windows
      assert Config.current(pid).wally_mode == "off"
    end

    test "a rejected config is not persisted", %{dir: dir} do
      pid = start_config(store_dir: dir)
      assert {:error, :bad_wally_mode} = Config.apply_config(pid, %{"version" => 3, "wally" => %{"mode" => "no"}})
      :ok = GenServer.stop(pid)

      pid2 = start_config(store_dir: dir)
      assert Config.applied_version(pid2) == nil
    end
  end
end
