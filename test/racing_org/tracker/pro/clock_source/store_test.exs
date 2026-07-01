defmodule RacingOrg.Tracker.Pro.ClockSource.StoreTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.ClockSource.Store

  setup do
    dir = Path.join(System.tmp_dir!(), "clock_source_store_test_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  @config %{
    version: 3,
    mode: :sensor_priority,
    fallback: :tracker_receive_time,
    sources: [
      %{
        priority: 1,
        sensor_id: "s-1",
        sensor_uid: nil,
        hardware_identifier: "1234567890",
        source_bus: "nmea2000",
        source_address: "35",
        sensor_type: "gnss",
        label: "Masthead GPS",
        metadata: %{"source_nmea_name" => "1234567890"}
      }
    ]
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
    File.write!(Path.join(dir, "current.clock_source"), "not a term")
    assert :empty = Store.load(dir)
  end

  test "an unknown-format / incompatible payload returns :empty", %{dir: dir} do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "current.clock_source"), :erlang.term_to_binary({999, @config}))
    assert :empty = Store.load(dir)
  end

  test "a payload missing required keys returns :empty", %{dir: dir} do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "current.clock_source"), :erlang.term_to_binary({1, %{version: 1}}))
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
    refute File.exists?(Path.join(dir, "current.clock_source.tmp"))
  end
end
