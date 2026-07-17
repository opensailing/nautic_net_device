defmodule RacingOrg.Tracker.Pro.Calibration.Observer.StoreTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.Calibration.Estimator.AwaOffset
  alias RacingOrg.Tracker.Pro.Calibration.Estimator.StwScale
  alias RacingOrg.Tracker.Pro.Calibration.Observer.Store

  setup do
    dir = Path.join(System.tmp_dir!(), "nn_cal_observer_store_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  defp pair do
    %{
      starboard: %{heading_mean: 315.0, stw_mean: 3.5, awa_mean_signed: 26.0, awa_abs_mean: 26.0, aws_mean: 8.8},
      port: %{heading_mean: 45.0, stw_mean: 3.5, awa_mean_signed: -32.0, awa_abs_mean: 32.0, aws_mean: 8.8}
    }
  end

  defp snapshot do
    awa = AwaOffset.observe_pair(AwaOffset.new(), pair())

    stw =
      StwScale.observe_pair(StwScale.new(), %{a: %{sog_mean: 2.0, stw_mean: 1.8}, b: %{sog_mean: 2.0, stw_mean: 1.8}})

    %{
      awa_estimators: %{"1A2B" => awa},
      stw_estimators: %{"3C4D" => stw},
      aws_estimators: %{},
      prev_applied: %{{"1A2B", "awa_offset"} => 1.5},
      seq: 7
    }
  end

  test "save then load round-trips the estimator states, prev_applied and seq", %{dir: dir} do
    assert :ok = Store.save(dir, snapshot())
    assert {:ok, loaded} = Store.load(dir)

    assert %AwaOffset{pairs_seen: 1} = loaded.awa_estimators["1A2B"]
    assert %StwScale{pairs_seen: 1} = loaded.stw_estimators["3C4D"]
    assert loaded.prev_applied == %{{"1A2B", "awa_offset"} => 1.5}
    assert loaded.seq == 7
  end

  test "the persisted term is term_to_binary/:safe round-trippable", %{dir: dir} do
    assert :ok = Store.save(dir, snapshot())
    binary = File.read!(Path.join(dir, "observer.calibration"))
    assert {2, %{}} = :erlang.binary_to_term(binary, [:safe])
  end

  test "load returns :empty when nothing is persisted", %{dir: dir} do
    assert :empty = Store.load(dir)
  end

  test "save uses an atomic rename and leaves no temp file", %{dir: dir} do
    assert :ok = Store.save(dir, snapshot())
    refute File.exists?(Path.join(dir, "observer.calibration.tmp"))
    assert File.exists?(Path.join(dir, "observer.calibration"))
  end

  test "load recovers from a corrupt file by returning :empty", %{dir: dir} do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "observer.calibration"), "not a term")
    assert :empty = Store.load(dir)
  end

  test "load ignores an unknown format version", %{dir: dir} do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "observer.calibration"), :erlang.term_to_binary({999, %{}}))
    assert :empty = Store.load(dir)
  end

  test "load ignores a format-1 snapshot (pre-banded-upwash estimators) — clean start", %{dir: dir} do
    # Format 1 persisted %AwaOffset{} structs WITHOUT the :bands field; restoring
    # them would KeyError inside the estimators, so v1 snapshots must be dropped.
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "observer.calibration"), :erlang.term_to_binary({1, snapshot()}))
    assert :empty = Store.load(dir)
  end

  test "does not clash with Calibration.Config's store file in the same dir", %{dir: dir} do
    # Config persists "current.calibration"; the Observer persists
    # "observer.calibration". Both must coexist under :calibration_directory.
    # (Calibration.Store's decode requires the modes/locks/learned shape.)
    config_state = %{applied_version: 1, modes: %{}, locks: %{}, learned: %{}}
    assert :ok = RacingOrg.Tracker.Pro.Calibration.Store.save(dir, config_state)
    assert :ok = Store.save(dir, snapshot())

    assert {:ok, %{applied_version: 1}} = RacingOrg.Tracker.Pro.Calibration.Store.load(dir)
    assert {:ok, %{seq: 7}} = Store.load(dir)
  end

  test "clear removes the persisted file", %{dir: dir} do
    assert :ok = Store.save(dir, snapshot())
    assert :ok = Store.clear(dir)
    assert :empty = Store.load(dir)
  end
end
