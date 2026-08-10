defmodule RacingOrg.Tracker.Pro.WindShift.Observer.StoreTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.WindShift.Observer.Store

  setup do
    dir = Path.join(System.tmp_dir!(), "wind_shift_observer_store_test_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  @snapshot %{
    session: %{
      started_at_ms: 1_784_800_800_000,
      lat_sum: 82.0,
      lon_sum: -142.0,
      pos_n: 2,
      tws_sum: 12.4,
      tws_n: 2
    },
    seq: 7,
    pending_timeline: [
      %{
        t_ms: 1_784_800_860_000,
        mean_twd_deg: 201.5,
        phase_deg: 1.2,
        amplitude_deg: nil,
        period_s: nil,
        trend_deg_per_hr: nil,
        tws_mps: 6.2
      }
    ],
    pending_events: [
      %{t_ms: 1_784_800_870_000, kind: "new_high", twd_deg: 212.0, magnitude_deg: 14.0, detail: %{}}
    ],
    last_summary: %{
      mean_twd_deg: 201.5,
      trend_deg_per_hr: nil,
      oscillation_period_s: nil,
      oscillation_amplitude_deg: nil,
      regime: "insufficient_history",
      tws_mean_mps: 6.2
    }
  }

  test "save then load round-trips the snapshot", %{dir: dir} do
    assert :ok = Store.save(dir, @snapshot)
    assert {:ok, loaded} = Store.load(dir)
    assert loaded == @snapshot
  end

  test "preserves pending event list order without sorting or restamping", %{dir: dir} do
    newer_current = %{
      t_ms: 1_784_800_880_000,
      kind: "regime_change",
      twd_deg: 214.0,
      magnitude_deg: nil,
      detail: %{from: "calm", to: "oscillating", confidence: 0.8}
    }

    delayed_extreme = %{
      t_ms: 1_784_800_875_000,
      kind: "lift_extreme",
      twd_deg: 216.0,
      magnitude_deg: 4.0,
      detail: %{phase_deg: 4.0}
    }

    snapshot = %{@snapshot | pending_events: [newer_current, delayed_extreme]}

    assert :ok = Store.save(dir, snapshot)
    assert {:ok, loaded} = Store.load(dir)
    assert loaded.pending_events == [newer_current, delayed_extreme]
  end

  test "loading a missing store returns :empty", %{dir: dir} do
    assert :empty = Store.load(dir)
  end

  test "a corrupt store returns :empty (never raises)", %{dir: dir} do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "observer.wind_shift"), "not a term")
    assert :empty = Store.load(dir)
  end

  test "an unknown-format / incompatible payload returns :empty", %{dir: dir} do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "observer.wind_shift"), :erlang.term_to_binary({999, @snapshot}))
    assert :empty = Store.load(dir)
  end

  test "the config store and the observer store share the directory without clashing", %{dir: dir} do
    alias RacingOrg.Tracker.Pro.WindShift.Store, as: ConfigStore

    config = %{
      version: 1,
      windows: %{fast_s: 30.0, mid_s: 300.0, slow_s: 1500.0, envelope_s: 1800.0},
      alarms: %{new_extreme_margin_deg: 2.0, enabled: true},
      wally_mode: "off"
    }

    assert :ok = ConfigStore.save(dir, config)
    assert :ok = Store.save(dir, @snapshot)
    assert {:ok, ^config} = ConfigStore.load(dir)
    assert {:ok, loaded} = Store.load(dir)
    assert loaded == @snapshot
  end

  test "save is atomic — no leftover temp file", %{dir: dir} do
    :ok = Store.save(dir, @snapshot)
    refute File.exists?(Path.join(dir, "observer.wind_shift.tmp"))
  end

  test "authoritative duplicate marker persists only a fixed closed fingerprint", %{dir: dir} do
    fingerprint = :crypto.hash(:sha256, "accepted authoritative wind snapshot")

    assert :ok = Store.save_authoritative_fingerprint(dir, fingerprint)
    assert {:ok, ^fingerprint} = Store.load_authoritative_fingerprint(dir)

    assert <<"WSAF", 1, ^fingerprint::binary-size(32)>> =
             File.read!(Path.join(dir, "observer.wind_shift.authoritative"))

    refute File.exists?(Path.join(dir, "observer.wind_shift.authoritative.tmp"))
  end

  test "corrupt or incompatible authoritative duplicate markers fail closed", %{dir: dir} do
    File.mkdir_p!(dir)
    path = Path.join(dir, "observer.wind_shift.authoritative")

    File.write!(path, <<"WSAF", 2, 0::256>>)
    assert :empty = Store.load_authoritative_fingerprint(dir)

    File.write!(path, <<"WSAF", 1, 0::128>>)
    assert :empty = Store.load_authoritative_fingerprint(dir)
  end
end
