defmodule RacingOrg.Tracker.Pro.WindShift.StoreTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.WindShift.Store

  setup do
    dir = Path.join(System.tmp_dir!(), "wind_shift_store_test_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  @config %{
    version: 3,
    windows: %{fast_s: 30.0, mid_s: 300.0, slow_s: 1500.0, envelope_s: 1800.0},
    alarms: %{new_extreme_margin_deg: 2.0, enabled: true},
    wally_mode: "shadow"
  }

  test "save then load round-trips the config", %{dir: dir} do
    assert :ok = Store.save(dir, @config)
    assert {:ok, loaded} = Store.load(dir)
    assert loaded == @config
  end

  test "loading a missing store returns :empty", %{dir: dir} do
    assert :empty = Store.load(dir)
  end

  test "a corrupt store returns :empty (never raises)", %{dir: dir} do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "current.wind_shift"), "not a term")
    assert :empty = Store.load(dir)
  end

  test "an unknown-format / incompatible payload returns :empty", %{dir: dir} do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "current.wind_shift"), :erlang.term_to_binary({999, @config}))
    assert :empty = Store.load(dir)
  end

  test "a payload missing required keys returns :empty", %{dir: dir} do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "current.wind_shift"), :erlang.term_to_binary({1, %{version: 1}}))
    assert :empty = Store.load(dir)
  end

  test "clear removes the persisted config", %{dir: dir} do
    :ok = Store.save(dir, @config)
    assert {:ok, _} = Store.load(dir)
    assert :ok = Store.clear(dir)
    assert :empty = Store.load(dir)
  end

  test "save is atomic — no leftover temp file", %{dir: dir} do
    :ok = Store.save(dir, @config)
    refute File.exists?(Path.join(dir, "current.wind_shift.tmp"))
  end
end
