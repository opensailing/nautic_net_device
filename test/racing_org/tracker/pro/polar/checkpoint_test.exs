defmodule RacingOrg.Tracker.Pro.Polar.CheckpointTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.Polar.Checkpoint, as: PolarCheckpoint
  alias RacingOrg.Tracker.Pro.Polar.Observer.PSquare
  alias RacingOrg.Tracker.Pro.Polar.Observer.Store
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.Checkpoint, as: ContractCheckpoint

  setup do
    dir = Path.join(System.tmp_dir!(), "polar_checkpoint_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  test "projects a real observer store snapshot into deterministic closed polar content", %{dir: dir} do
    snapshot = snapshot()
    assert :ok = Store.save(dir, snapshot)
    assert {:ok, stored_snapshot} = Store.load(dir)

    assert {:ok, content} = PolarCheckpoint.project(stored_snapshot)
    assert content == expected_content(snapshot)

    assert Enum.map(content["cells"], &{&1["tws_bin"], &1["twa_bin"]}) == [
             {5, 9},
             {6, 18}
           ]

    [marker_cell, warmup_cell] = content["cells"]
    assert Enum.all?(~w(q n np dnp), &is_list(marker_cell["quantile"][&1]))
    assert Enum.all?(~w(q n np dnp), &is_nil(warmup_cell["quantile"][&1]))

    assert {:ok, bytes} = ContractCheckpoint.encode_content(:polar, 1, content)
    assert {:ok, ^content} = ContractCheckpoint.decode_content(:polar, 1, bytes)
  end

  test "hydrates decoded checkpoint content into the exact observer store restore shape", %{dir: dir} do
    snapshot = snapshot()
    assert {:ok, content} = PolarCheckpoint.project(snapshot)
    assert {:ok, bytes} = ContractCheckpoint.encode_content(:polar, 1, content)
    assert {:ok, decoded} = ContractCheckpoint.decode_content(:polar, 1, bytes)

    assert {:ok, hydrated} = PolarCheckpoint.hydrate(decoded)
    assert hydrated == snapshot

    assert :ok = Store.save(dir, hydrated)
    assert {:ok, ^snapshot} = Store.load(dir)
  end

  test "round-trips an empty sailed polar" do
    assert {:ok, %{"cells" => []} = content} = PolarCheckpoint.project(%{})
    assert {:ok, bytes} = ContractCheckpoint.encode_content(:polar, 1, content)
    assert {:ok, decoded} = ContractCheckpoint.decode_content(:polar, 1, bytes)
    assert {:ok, %{}} = PolarCheckpoint.hydrate(decoded)
  end

  test "rejects malformed observer snapshots without projecting partial content" do
    snapshot = snapshot()
    warmup = snapshot[{6, 18}]
    {warmup_count, warmup_quantile} = warmup

    malformed = [
      :not_a_cell_map,
      Map.put(snapshot, {-1, 18}, warmup),
      Map.put(snapshot, {7, 27}, {warmup_count + 1, warmup_quantile}),
      Map.put(snapshot, {7, 27}, {warmup_count, %{warmup_quantile | buffer: Enum.reverse(warmup_quantile.buffer)}}),
      Map.put(snapshot, {7, 27}, {warmup_count, %{warmup_quantile | q: [1.0, 2.0, 3.0, 4.0, 5.0]}}),
      Map.put(snapshot, {7, 27}, %{count: warmup_count, quantile: warmup_quantile})
    ]

    for invalid <- malformed do
      assert {:error, :invalid_checkpoint_content} = PolarCheckpoint.project(invalid)
    end
  end

  test "rejects malformed, noncanonical, secret-capable, and open hydration content" do
    assert {:ok, valid} = PolarCheckpoint.project(snapshot())
    [first, second] = valid["cells"]

    invalid = [
      Map.put(valid, "metadata", %{}),
      %{"cells" => [second, first]},
      %{"cells" => [first, first]},
      %{"cells" => [Map.put(first, "psk", "synthetic-noncredential"), second]},
      %{"cells" => [put_in(first, ["quantile", "q"], List.to_tuple(first["quantile"]["q"])), second]},
      %{"cells" => [put_in(first, ["quantile", "buffer"], [1.0]), second]},
      %{"cells" => [first, put_in(second, ["quantile", "q"], [1.0, 2.0, 3.0, 4.0, 5.0])]},
      %{"cells" => [Map.update!(first, "count", &(&1 + 1)), second]},
      %{cells: valid["cells"]}
    ]

    for content <- invalid do
      assert {:error, :invalid_checkpoint_content} = PolarCheckpoint.hydrate(content)
    end
  end

  defp snapshot do
    marker = feed([4.0, 4.2, 4.4, 4.6, 4.8, 5.0])
    warmup = feed([3.0, 1.0, 4.0, 2.0])

    Map.new([
      {{6, 18}, {PSquare.count(warmup), warmup}},
      {{5, 9}, {PSquare.count(marker), marker}}
    ])
  end

  defp feed(values) do
    Enum.reduce(values, PSquare.new(0.9), &PSquare.add(&2, &1))
  end

  defp expected_content(snapshot) do
    %{
      "cells" =>
        snapshot
        |> Enum.sort_by(fn {key, _cell} -> key end)
        |> Enum.map(fn {{tws_bin, twa_bin}, {count, quantile}} ->
          %{
            "count" => count,
            "quantile" => %{
              "buffer" => quantile.buffer,
              "count" => quantile.count,
              "dnp" => tuple_to_list_or_nil(quantile.dnp),
              "n" => tuple_to_list_or_nil(quantile.n),
              "np" => tuple_to_list_or_nil(quantile.np),
              "p" => quantile.p,
              "q" => tuple_to_list_or_nil(quantile.q)
            },
            "twa_bin" => twa_bin,
            "tws_bin" => tws_bin
          }
        end)
    }
  end

  defp tuple_to_list_or_nil(nil), do: nil
  defp tuple_to_list_or_nil(tuple), do: Tuple.to_list(tuple)
end
