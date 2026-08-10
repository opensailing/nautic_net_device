defmodule RacingOrg.Tracker.Pro.Polar.Observer.StoreTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias RacingOrg.Tracker.Pro.Polar.Observer.Bins
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

  defp runtime do
    %{
      authority: "boat-test",
      policy_hash: :binary.copy(<<0xCD>>, 32),
      source_generation: 77,
      seq: 23,
      last_restore_fingerprint: :binary.copy(<<0xAB>>, 32),
      p: 0.9,
      bins: Bins.new(twa_width_deg: 2.5, tws_width_mps: 1.0, max_tws_mps: 30.0),
      cells: cells()
    }
  end

  test "save then load round-trips the sailed cells", %{dir: dir} do
    assert :ok = Store.save(dir, cells())
    assert {:ok, loaded} = Store.load(dir)
    assert {6, %PSquare{} = ps} = loaded[{5, 9}]
    assert PSquare.count(ps) == 6
    assert {3, %PSquare{}} = loaded[{6, 18}]
  end

  test "runtime persistence binds revision, sync sequence, accepted fingerprint, probability, and geometry", %{
    dir: dir
  } do
    runtime = runtime()

    assert :ok = Store.save_runtime(dir, runtime)
    assert {:ok, ^runtime} = Store.load_runtime(dir)
    assert {:ok, runtime.cells} == Store.load(dir)
  end

  test "runtime persistence reports post-rename durability uncertainty", %{dir: dir} do
    fault_injector = fn
      :renamed -> {:error, :power_loss}
      _stage -> :ok
    end

    assert {:error, {:durability_uncertain, _reason}} =
             Store.save_runtime(dir, runtime(), fault_injector: fault_injector)

    assert File.exists?(Path.join(dir, "sailed.polar"))
  end

  test "invalid runtime persistence is logged instead of failing silently", %{dir: dir} do
    log =
      capture_log(fn ->
        assert {:error, :invalid_runtime} = Store.save_runtime(dir, %{})
      end)

    assert log =~ "invalid sailed-polar runtime"
  end

  test "legacy cell-only persistence loads as an upgrade requiring canonical rewrite", %{dir: dir} do
    assert :ok = Store.save(dir, cells())

    assert {:ok,
            %{
              authority: nil,
              policy_hash: nil,
              source_generation: 9,
              seq: 0,
              last_restore_fingerprint: nil,
              p: nil,
              bins: nil,
              cells: loaded,
              legacy?: true
            }} = Store.load_runtime(dir)

    assert loaded == cells()
  end

  test "legacy generation fails closed when any cell cannot contribute an authoritative revision", %{
    dir: dir
  } do
    legacy_cells = Map.put(cells(), {:bad, :key}, :malformed)
    assert :ok = Store.save(dir, legacy_cells)

    assert :invalid = Store.load_runtime(dir)
    assert :empty = Store.load(dir)
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

  test "load recovers from a corrupt file while the runtime loader marks it for scrub", %{dir: dir} do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "sailed.polar"), "not a term")
    assert :invalid = Store.load_runtime(dir)
    assert :empty = Store.load(dir)
  end

  test "load ignores an unknown format while the runtime loader marks it for scrub", %{dir: dir} do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "sailed.polar"), :erlang.term_to_binary({999, %{}}))
    assert :invalid = Store.load_runtime(dir)
    assert :empty = Store.load(dir)
  end

  test "clear removes the persisted file", %{dir: dir} do
    assert :ok = Store.save(dir, cells())
    assert :ok = Store.clear(dir)
    assert :empty = Store.load(dir)
  end
end
