defmodule RacingOrg.Tracker.Pro.Calibration.StoreTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.Calibration.Store

  setup do
    dir = Path.join(System.tmp_dir!(), "calibration_store_test_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  @state %{
    applied_version: 3,
    modes: %{"awa_offset" => "auto", "awa_upwash" => "shadow", "stw_scale" => "auto", "aws_scale" => "shadow"},
    locks: %{{"1A2B", "awa_offset"} => %{locked: true, value: 2.5}},
    learned: %{
      "1A2B" => %{
        "stw_scale" => %{value: [{2.0, 1.05}], confidence: 0.9, sample_count: 400, state: "applied"}
      }
    }
  }

  test "save then load round-trips the state", %{dir: dir} do
    assert :ok = Store.save(dir, @state)
    assert {:ok, loaded} = Store.load(dir)
    assert loaded == @state
  end

  test "loading a missing store returns :empty", %{dir: dir} do
    assert :empty = Store.load(dir)
  end

  test "a corrupt store returns :empty (never raises)", %{dir: dir} do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "current.calibration"), "not a term")
    assert :empty = Store.load(dir)
  end

  test "an unknown-format / incompatible payload returns :empty", %{dir: dir} do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "current.calibration"), :erlang.term_to_binary({999, @state}))
    assert :empty = Store.load(dir)
  end

  test "a payload missing required keys returns :empty", %{dir: dir} do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "current.calibration"), :erlang.term_to_binary({1, %{applied_version: 1}}))
    assert :empty = Store.load(dir)
  end

  test "clear removes the persisted state", %{dir: dir} do
    :ok = Store.save(dir, @state)
    assert {:ok, _} = Store.load(dir)
    assert :ok = Store.clear(dir)
    assert :empty = Store.load(dir)
  end

  test "save is atomic — no leftover temp file", %{dir: dir} do
    :ok = Store.save(dir, @state)
    refute File.exists?(Path.join(dir, "current.calibration.tmp"))
  end
end
