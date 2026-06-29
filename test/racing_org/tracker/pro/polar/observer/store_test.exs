defmodule RacingOrg.Tracker.Pro.Polar.Observer.StoreTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.Polar.Observer.PSquare
  alias RacingOrg.Tracker.Pro.Polar.Observer.Store

  setup do
    dir = Path.join(System.tmp_dir!(), "nn_sailed_store_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  defp cells do
    ps = Enum.reduce([4.0, 4.2, 4.4, 4.6, 4.8, 5.0], PSquare.new(0.9), &PSquare.add(&2, &1))
    %{{5, 9} => {6, ps}, {6, 18} => {3, PSquare.new(0.9)}}
  end

  test "save then load round-trips the sailed cells", %{dir: dir} do
    assert :ok = Store.save(dir, cells())
    assert {:ok, loaded} = Store.load(dir)
    assert {6, %PSquare{} = ps} = loaded[{5, 9}]
    assert PSquare.count(ps) == 6
    assert {3, %PSquare{}} = loaded[{6, 18}]
  end

  test "the persisted term is term_to_binary/:safe round-trippable (plain floats/ints/tuples)", %{dir: dir} do
    assert :ok = Store.save(dir, cells())
    binary = File.read!(Path.join(dir, "sailed.polar"))
    # :safe must not raise (no atoms/unknown terms outside the struct's own).
    assert {1, %{}} = :erlang.binary_to_term(binary, [:safe])
  end

  test "load returns :empty when nothing is persisted", %{dir: dir} do
    assert :empty = Store.load(dir)
  end

  test "save uses an atomic rename and leaves no temp file", %{dir: dir} do
    assert :ok = Store.save(dir, cells())
    refute File.exists?(Path.join(dir, "sailed.polar.tmp"))
    assert File.exists?(Path.join(dir, "sailed.polar"))
  end

  test "load recovers from a corrupt file by returning :empty", %{dir: dir} do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "sailed.polar"), "not a term")
    assert :empty = Store.load(dir)
  end

  test "load ignores an unknown format version", %{dir: dir} do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "sailed.polar"), :erlang.term_to_binary({999, %{}}))
    assert :empty = Store.load(dir)
  end

  test "clear removes the persisted file", %{dir: dir} do
    assert :ok = Store.save(dir, cells())
    assert :ok = Store.clear(dir)
    assert :empty = Store.load(dir)
  end
end
