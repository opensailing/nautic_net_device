defmodule RacingOrg.Tracker.Pro.Upstream.StoreTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.Upstream.Store

  setup do
    dir = Path.join(System.tmp_dir!(), "nn_upstream_store_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  @config %{
    version: 3,
    signals: %{
      heading: true,
      speed: true,
      velocity: false,
      wind: false,
      water_depth: true,
      attitude: true
    }
  }

  test "save/2 then load/1 round-trips the signal map + version", %{dir: dir} do
    assert :ok = Store.save(dir, @config)
    assert {:ok, loaded} = Store.load(dir)
    assert loaded.version == 3
    assert loaded.signals.velocity == false
    assert loaded.signals.heading == true
  end

  test "load/1 on a missing dir returns :empty", %{dir: dir} do
    assert :empty = Store.load(dir)
  end

  test "load/1 on corrupt data returns :empty (never raises)", %{dir: dir} do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "current.upstream"), "not a term")
    assert :empty = Store.load(dir)
  end

  test "clear/1 removes the persisted config", %{dir: dir} do
    assert :ok = Store.save(dir, @config)
    assert :ok = Store.clear(dir)
    assert :empty = Store.load(dir)
  end
end
