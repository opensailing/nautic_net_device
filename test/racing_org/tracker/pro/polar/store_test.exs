defmodule RacingOrg.Tracker.Pro.Polar.StoreTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.Polar
  alias RacingOrg.Tracker.Pro.Polar.Store

  setup do
    dir = Path.join(System.tmp_dir!(), "nn_polar_store_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  defp polar do
    %Polar{
      polar_id: "boat-42",
      version: 3,
      rows: [
        %{tws_mps: 5.0, cells: [%{twa_deg: 45.0, boat_speed_mps: 4.1}, %{twa_deg: 90.0, boat_speed_mps: 6.2}]}
      ],
      optima: [%{tws_mps: 5.0, beat_twa: 42.0, beat_vmg: 3.0, run_twa: 165.0, run_vmg: 5.1}]
    }
  end

  test "save then load round-trips the polar", %{dir: dir} do
    assert :ok = Store.save(dir, polar())
    assert {:ok, loaded} = Store.load(dir)
    assert loaded.polar_id == "boat-42"
    assert loaded.version == 3
    assert [%{tws_mps: 5.0, cells: cells}] = loaded.rows
    assert [%{twa_deg: 45.0, boat_speed_mps: 4.1} | _] = cells
    assert [%{beat_twa: 42.0, run_vmg: 5.1}] = loaded.optima
  end

  test "load returns :empty when nothing is persisted", %{dir: dir} do
    assert :empty = Store.load(dir)
  end

  test "save uses an atomic rename and leaves no temp file", %{dir: dir} do
    assert :ok = Store.save(dir, polar())
    refute File.exists?(Path.join(dir, "reference.polar.tmp"))
    assert File.exists?(Path.join(dir, "reference.polar"))
  end

  test "load recovers from a corrupt file by returning :empty", %{dir: dir} do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "reference.polar"), <<0, 1, 2, 3, 255>>)
    assert :empty = Store.load(dir)
  end

  test "load ignores an unknown format version", %{dir: dir} do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "reference.polar"), :erlang.term_to_binary({999, %{}}))
    assert :empty = Store.load(dir)
  end

  test "clear removes the persisted file", %{dir: dir} do
    Store.save(dir, polar())
    assert :ok = Store.clear(dir)
    assert :empty = Store.load(dir)
  end
end
