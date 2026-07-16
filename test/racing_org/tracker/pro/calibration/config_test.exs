defmodule RacingOrg.Tracker.Pro.Calibration.ConfigTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.Calibration.Config

  @default_modes %{
    "awa_offset" => "auto",
    "awa_upwash" => "auto",
    "stw_scale" => "auto",
    "aws_scale" => "shadow"
  }

  # --- helpers ---

  defp start_config(opts \\ []) do
    opts = opts |> Keyword.put_new(:name, nil) |> Keyword.put_new(:store_dir, nil)
    {:ok, pid} = Config.start_link(opts)
    pid
  end

  defp calibration_config(version, overrides \\ %{}) do
    Map.merge(%{"version" => version, "parameters" => %{}, "sensors" => []}, overrides)
  end

  defp learned_entry(overrides \\ %{}) do
    Map.merge(%{value: 3.0, confidence: 0.9, sample_count: 500, state: "applied"}, overrides)
  end

  # --- defaults ---

  test "with no config: nil version, default modes, no sensors, empty corrections" do
    pid = start_config()
    assert Config.applied_version(pid) == nil
    assert Config.corrections(pid) == %{}

    status = Config.status(pid)
    assert status.applied_version == nil
    assert status.modes == @default_modes
    assert status.sensors == []
    assert status.status == "ok"
  end

  # --- versioned idempotency (house pattern) ---

  test "applying config is idempotent by version" do
    pid = start_config()

    assert {:ok, %{version: 1}} = Config.apply_config(pid, calibration_config(1))
    assert Config.applied_version(pid) == 1

    assert {:ok, :unchanged} = Config.apply_config(pid, calibration_config(1))
    assert {:ok, :unchanged} = Config.apply_config(pid, calibration_config(0))
    assert Config.applied_version(pid) == 1

    assert {:ok, %{version: 2}} = Config.apply_config(pid, calibration_config(2))
    assert Config.applied_version(pid) == 2
  end

  test "the first config (even version 0) is always applied" do
    pid = start_config()
    assert {:ok, %{version: 0}} = Config.apply_config(pid, calibration_config(0))
    assert Config.applied_version(pid) == 0
  end

  test "a malformed config (missing/invalid version) is rejected and nothing is applied" do
    pid = start_config()
    assert {:error, :bad_version} = Config.apply_config(pid, %{"parameters" => %{}})
    assert {:error, :bad_version} = Config.apply_config(pid, %{"version" => "nope"})
    assert Config.applied_version(pid) == nil
  end

  # --- parameter modes ---

  test "parameter modes are applied; omitted parameters keep their defaults" do
    pid = start_config()

    {:ok, _} =
      Config.apply_config(
        pid,
        calibration_config(1, %{"parameters" => %{"awa_offset" => %{"mode" => "shadow"}}})
      )

    assert Config.status(pid).modes == %{@default_modes | "awa_offset" => "shadow"}
  end

  test "an unknown parameter name is ignored (config still applies)" do
    pid = start_config()

    {:ok, _} =
      Config.apply_config(
        pid,
        calibration_config(1, %{
          "parameters" => %{"bogus" => %{"mode" => "auto"}, "stw_scale" => %{"mode" => "off"}}
        })
      )

    assert Config.applied_version(pid) == 1
    modes = Config.status(pid).modes
    refute Map.has_key?(modes, "bogus")
    assert modes["stw_scale"] == "off"
  end

  test "an unknown mode is ignored (parameter keeps its default)" do
    pid = start_config()

    {:ok, _} =
      Config.apply_config(
        pid,
        calibration_config(1, %{"parameters" => %{"awa_upwash" => %{"mode" => "warp"}}})
      )

    assert Config.status(pid).modes["awa_upwash"] == "auto"
  end

  test "aws_scale supports only off|shadow — auto is ignored (stays shadow)" do
    pid = start_config()

    {:ok, _} =
      Config.apply_config(
        pid,
        calibration_config(1, %{"parameters" => %{"aws_scale" => %{"mode" => "auto"}}})
      )

    assert Config.status(pid).modes["aws_scale"] == "shadow"
  end

  # --- sensor locks (canonicalized hardware identifiers) ---

  test "a lock's hardware_identifier is canonicalized to uppercase hex" do
    pid = start_config()

    {:ok, _} =
      Config.apply_config(
        pid,
        calibration_config(1, %{
          "sensors" => [
            %{"hardware_identifier" => "0x1a2b", "parameter" => "awa_offset", "locked" => true, "value" => 2.5}
          ]
        })
      )

    assert Config.corrections(pid) == %{"1A2B" => %{awa_offset_deg: 2.5}}

    assert [%{hardware_identifier: "1A2B", parameter: "awa_offset", state: "locked", value: 2.5}] =
             Config.status(pid).sensors
  end

  test "a lock with an unknown parameter is ignored (config still applies)" do
    pid = start_config()

    {:ok, _} =
      Config.apply_config(
        pid,
        calibration_config(1, %{
          "sensors" => [%{"hardware_identifier" => "1A2B", "parameter" => "bogus", "locked" => true, "value" => 1.0}]
        })
      )

    assert Config.applied_version(pid) == 1
    assert Config.corrections(pid) == %{}
    assert Config.status(pid).sensors == []
  end

  test "a locked stw_scale pin compiles to a uniform gain" do
    pid = start_config()

    {:ok, _} =
      Config.apply_config(
        pid,
        calibration_config(1, %{
          "sensors" => [
            %{"hardware_identifier" => "1A2B", "parameter" => "stw_scale", "locked" => true, "value" => 1.05}
          ]
        })
      )

    assert Config.corrections(pid) == %{"1A2B" => %{stw_gains: [{0.0, 1.05}]}}
  end

  test "locks apply even when the parameter mode is shadow (explicit operator intent)" do
    pid = start_config()

    {:ok, _} =
      Config.apply_config(
        pid,
        calibration_config(1, %{
          "parameters" => %{"awa_offset" => %{"mode" => "shadow"}},
          "sensors" => [
            %{"hardware_identifier" => "1A2B", "parameter" => "awa_offset", "locked" => true, "value" => 2.5}
          ]
        })
      )

    assert Config.corrections(pid) == %{"1A2B" => %{awa_offset_deg: 2.5}}
  end

  test "mode off excludes even a locked pin" do
    pid = start_config()

    {:ok, _} =
      Config.apply_config(
        pid,
        calibration_config(1, %{
          "parameters" => %{"awa_offset" => %{"mode" => "off"}},
          "sensors" => [
            %{"hardware_identifier" => "1A2B", "parameter" => "awa_offset", "locked" => true, "value" => 2.5}
          ]
        })
      )

    assert Config.corrections(pid) == %{}
  end

  test "an unlocked lock entry or a locked entry without a numeric value never pins" do
    pid = start_config()

    {:ok, _} =
      Config.apply_config(
        pid,
        calibration_config(1, %{
          "sensors" => [
            %{"hardware_identifier" => "1A2B", "parameter" => "awa_offset", "locked" => false, "value" => 2.5},
            %{"hardware_identifier" => "3C4D", "parameter" => "awa_offset", "locked" => true, "value" => nil}
          ]
        })
      )

    assert Config.corrections(pid) == %{}
  end

  # --- put_learned + corrections compilation matrix ---

  test "put_learned canonicalizes the sensor id and an applied entry in auto mode is compiled" do
    pid = start_config()
    assert :ok = Config.put_learned(pid, "0x1a2b", "awa_offset", learned_entry())
    assert Config.corrections(pid) == %{"1A2B" => %{awa_offset_deg: 3.0}}
  end

  test "shadow/validated/learning learned states are NOT compiled" do
    pid = start_config()

    for state <- ["shadow", "validated", "learning"] do
      assert :ok = Config.put_learned(pid, "1A2B", "awa_offset", learned_entry(%{state: state}))
      assert Config.corrections(pid) == %{}
    end
  end

  test "a learned applied entry is NOT compiled when the parameter mode is shadow or off" do
    for mode <- ["shadow", "off"] do
      pid = start_config()

      {:ok, _} =
        Config.apply_config(pid, calibration_config(1, %{"parameters" => %{"awa_offset" => %{"mode" => mode}}}))

      assert :ok = Config.put_learned(pid, "1A2B", "awa_offset", learned_entry())
      assert Config.corrections(pid) == %{}
    end
  end

  test "a locked pin wins over a learned applied entry" do
    pid = start_config()

    {:ok, _} =
      Config.apply_config(
        pid,
        calibration_config(1, %{
          "sensors" => [
            %{"hardware_identifier" => "1A2B", "parameter" => "awa_offset", "locked" => true, "value" => 2.5}
          ]
        })
      )

    assert :ok = Config.put_learned(pid, "1A2B", "awa_offset", learned_entry(%{value: 9.9}))
    assert Config.corrections(pid) == %{"1A2B" => %{awa_offset_deg: 2.5}}
  end

  test "learned stw_scale supports a single float (uniform gain) and a list of {center, gain} pairs" do
    pid = start_config()

    assert :ok = Config.put_learned(pid, "1A2B", "stw_scale", learned_entry(%{value: 1.04}))
    assert Config.corrections(pid) == %{"1A2B" => %{stw_gains: [{0.0, 1.04}]}}

    assert :ok = Config.put_learned(pid, "1A2B", "stw_scale", learned_entry(%{value: [{6.0, 1.02}, {2.0, 1.1}]}))
    assert Config.corrections(pid) == %{"1A2B" => %{stw_gains: [{2.0, 1.1}, {6.0, 1.02}]}}
  end

  test "aws_scale never compiles into corrections (shadow-only parameter)" do
    pid = start_config()
    assert :ok = Config.put_learned(pid, "1A2B", "aws_scale", learned_entry(%{value: 1.1}))
    assert Config.corrections(pid) == %{}
    # ...but it IS reported in status for the server to observe.
    assert [%{parameter: "aws_scale", state: "applied", value: 1.1}] = Config.status(pid).sensors
  end

  test "multiple parameters for one sensor merge into one corrections entry" do
    pid = start_config()
    assert :ok = Config.put_learned(pid, "1A2B", "awa_offset", learned_entry(%{value: 2.0}))
    assert :ok = Config.put_learned(pid, "1A2B", "awa_upwash", learned_entry(%{value: 1.5}))
    assert :ok = Config.put_learned(pid, "1A2B", "stw_scale", learned_entry(%{value: 1.03}))

    assert Config.corrections(pid) == %{
             "1A2B" => %{awa_offset_deg: 2.0, awa_upwash_deg: 1.5, stw_gains: [{0.0, 1.03}]}
           }
  end

  test "put_learned rejects unknown parameters and malformed entries" do
    pid = start_config()
    assert {:error, :bad_parameter} = Config.put_learned(pid, "1A2B", "bogus", learned_entry())
    assert {:error, :bad_entry} = Config.put_learned(pid, "1A2B", "awa_offset", %{value: 1.0})
    assert {:error, :bad_entry} = Config.put_learned(pid, "1A2B", "awa_offset", learned_entry(%{state: "bogus"}))
    assert {:error, :bad_entry} = Config.put_learned(pid, "1A2B", "awa_offset", learned_entry(%{value: "x"}))
    assert Config.corrections(pid) == %{}
  end

  # --- status ---

  test "status flattens learned + locks; a locked (sensor, parameter) reports state locked" do
    pid = start_config()

    {:ok, _} =
      Config.apply_config(
        pid,
        calibration_config(1, %{
          "sensors" => [
            %{"hardware_identifier" => "1A2B", "parameter" => "awa_offset", "locked" => true, "value" => 2.5}
          ]
        })
      )

    assert :ok = Config.put_learned(pid, "1A2B", "awa_offset", learned_entry(%{value: 9.9}))
    assert :ok = Config.put_learned(pid, "3C4D", "stw_scale", learned_entry(%{value: 1.02, state: "learning"}))

    status = Config.status(pid)
    assert Map.keys(status) |> Enum.sort() == [:applied_version, :modes, :sensors, :status]

    locked = Enum.find(status.sensors, &(&1.hardware_identifier == "1A2B"))
    # The pinned value is what is applied; learned diagnostics ride along.
    assert %{parameter: "awa_offset", state: "locked", value: 2.5, confidence: 0.9, sample_count: 500} = locked

    learning = Enum.find(status.sensors, &(&1.hardware_identifier == "3C4D"))
    assert %{parameter: "stw_scale", state: "learning", value: 1.02} = learning
  end

  # --- subscribe / notify ---

  test "apply_config notifies subscribers; put_learned notifies ONLY when applied corrections change" do
    pid = start_config()
    assert :ok = Config.subscribe(pid, self())

    {:ok, _} = Config.apply_config(pid, calibration_config(1))
    assert_receive {:racing_org_calibration, :updated}

    # A learning-state entry changes nothing applied -> no notification.
    assert :ok = Config.put_learned(pid, "1A2B", "awa_offset", learned_entry(%{state: "learning"}))
    refute_receive {:racing_org_calibration, :updated}, 50

    # Promoting it to applied changes the corrections -> notified.
    assert :ok = Config.put_learned(pid, "1A2B", "awa_offset", learned_entry(%{state: "applied"}))
    assert_receive {:racing_org_calibration, :updated}

    # Re-recording the identical entry changes nothing -> no notification.
    assert :ok = Config.put_learned(pid, "1A2B", "awa_offset", learned_entry(%{state: "applied"}))
    refute_receive {:racing_org_calibration, :updated}, 50
  end

  test "a re-applied (unchanged) or malformed config does not notify" do
    pid = start_config()
    {:ok, _} = Config.apply_config(pid, calibration_config(1))
    assert :ok = Config.subscribe(pid, self())

    assert {:ok, :unchanged} = Config.apply_config(pid, calibration_config(1))
    assert {:error, :bad_version} = Config.apply_config(pid, %{"parameters" => %{}})
    refute_receive {:racing_org_calibration, :updated}, 50
  end

  # --- persistence ---

  describe "persistence" do
    setup do
      dir = Path.join(System.tmp_dir!(), "calibration_config_test_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(dir) end)
      {:ok, dir: dir}
    end

    test "config + learned state survive a restart and are treated as already-applied", %{dir: dir} do
      pid = start_config(store_dir: dir)

      {:ok, _} =
        Config.apply_config(
          pid,
          calibration_config(5, %{
            "parameters" => %{"awa_upwash" => %{"mode" => "shadow"}},
            "sensors" => [
              %{"hardware_identifier" => "1A2B", "parameter" => "awa_offset", "locked" => true, "value" => 2.5}
            ]
          })
        )

      assert :ok = Config.put_learned(pid, "3C4D", "stw_scale", learned_entry(%{value: 1.03}))
      corrections = Config.corrections(pid)
      :ok = GenServer.stop(pid)

      pid2 = start_config(store_dir: dir)
      assert Config.applied_version(pid2) == 5
      assert Config.status(pid2).modes["awa_upwash"] == "shadow"
      assert Config.corrections(pid2) == corrections
      # re-pushing the same version is a no-op; a newer one still applies
      assert {:ok, :unchanged} = Config.apply_config(pid2, calibration_config(5))
      assert {:ok, %{version: 6}} = Config.apply_config(pid2, calibration_config(6))
    end

    test "a corrupt persisted store falls back to safe defaults", %{dir: dir} do
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "current.calibration"), "garbage")

      pid = start_config(store_dir: dir)
      assert Config.applied_version(pid) == nil
      assert Config.status(pid).modes == @default_modes
      assert Config.corrections(pid) == %{}
    end
  end
end
