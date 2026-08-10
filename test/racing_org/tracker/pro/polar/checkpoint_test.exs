defmodule RacingOrg.Tracker.Pro.Polar.CheckpointTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.Polar.Checkpoint, as: PolarCheckpoint
  alias RacingOrg.Tracker.Pro.Polar.Observer.Bins
  alias RacingOrg.Tracker.Pro.Polar.Observer.PSquare
  alias RacingOrg.Tracker.Pro.Polar.Observer.Store
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.Canonical
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.Checkpoint, as: ContractCheckpoint

  # The planned chunked-transport ceiling for one checkpoint's canonical content.
  # Chunk framing itself is NOT part of this milestone; this is the budget the
  # bounded sailed-polar domain must provably fit inside before it is added.
  @planned_content_ceiling 1_048_576

  @p 0.9

  setup do
    dir = Path.join(System.tmp_dir!(), "polar_checkpoint_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  describe "schema identity" do
    test "projects under the bumped polar checkpoint schema the registry declares" do
      assert PolarCheckpoint.schema_version() == 2
      assert {:ok, 0x02, 2} = RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.checkpoint_kind(:polar)
    end
  end

  describe "project/3" do
    test "binds one global p and the exact bin geometry beside bare cell indices", %{dir: dir} do
      snapshot = snapshot()
      assert :ok = Store.save(dir, snapshot)
      assert {:ok, stored_snapshot} = Store.load(dir)

      assert {:ok, content} = PolarCheckpoint.project(bins(), @p, stored_snapshot)

      assert Enum.sort(Map.keys(content)) == ~w(cells max_tws_mps p twa_width_deg tws_width_mps)

      assert content["p"] == @p
      assert content["twa_width_deg"] == bins().twa_width_deg
      assert content["tws_width_mps"] == bins().tws_width_mps
      assert content["max_tws_mps"] == bins().max_tws_mps

      assert Enum.map(content["cells"], &{&1["tws_bin"], &1["twa_bin"]}) == [{5, 9}, {6, 18}]
    end

    test "compacts every per-cell field the global p and cell count already determine" do
      assert {:ok, content} = PolarCheckpoint.project(bins(), @p, snapshot())
      [marker_cell, warmup_cell] = content["cells"]

      assert Enum.sort(Map.keys(marker_cell)) == ~w(count quantile twa_bin tws_bin)
      assert Enum.sort(Map.keys(marker_cell["quantile"])) == ~w(buffer n np q)
      assert Enum.sort(Map.keys(warmup_cell["quantile"])) == ~w(buffer n np q)

      # dnp, the per-cell p, and the per-cell quantile count are all derivable.
      for field <- ~w(count dnp p) do
        refute Map.has_key?(marker_cell["quantile"], field)
      end

      # Only the three INTERIOR actual positions survive: n[0] is always 1 and
      # n[4] is always the cell count, so both endpoints are reconstructible.
      {_count, marker} = snapshot()[{5, 9}]
      assert Tuple.to_list(marker.n) == [1, 2, 3, 5, 6]
      assert marker_cell["quantile"]["n"] == [2, 3, 5]

      # np is NOT exactly reconstructible from p and count, so it is preserved.
      assert marker_cell["quantile"]["np"] == Tuple.to_list(marker.np)
      assert marker_cell["quantile"]["q"] == Tuple.to_list(marker.q)

      # A warmup cell has no markers at all, only its sorted buffer.
      assert warmup_cell["quantile"]["buffer"] == [1.0, 2.0, 3.0, 4.0]
      assert is_nil(warmup_cell["quantile"]["n"])
      assert is_nil(warmup_cell["quantile"]["np"])
      assert is_nil(warmup_cell["quantile"]["q"])
    end

    test "rejects mixed per-cell quantile probabilities against the one declared p" do
      {count, other_p} = {6, feed(0.75, [4.0, 4.2, 4.4, 4.6, 4.8, 5.0])}
      mixed = Map.put(snapshot(), {7, 27}, {count, other_p})

      assert {:error, :invalid_checkpoint_content} = PolarCheckpoint.project(bins(), @p, mixed)
      assert {:error, :invalid_checkpoint_content} = PolarCheckpoint.project(bins(), 0.75, mixed)
    end

    test "rejects every cell key outside the declared finite grid" do
      {max_tws_bin, max_twa_bin} = Bins.max_key(bins())
      assert {max_tws_bin, max_twa_bin} == {99, 35}

      {count, quantile} = snapshot()[{6, 18}]

      for key <- [{max_tws_bin + 1, 0}, {0, max_twa_bin + 1}, {-1, 0}, {0, -1}] do
        out_of_grid = Map.put(snapshot(), key, {count, quantile})

        assert {:error, :invalid_checkpoint_content} =
                 PolarCheckpoint.project(bins(), @p, out_of_grid)
      end

      # The SAME key is in-grid under a coarser grid and out-of-grid under a finer one.
      coarse = Bins.new(twa_width_deg: 5.0, tws_width_mps: 0.514444, max_tws_mps: 100.0)
      assert {:ok, _content} = PolarCheckpoint.project(coarse, @p, Map.put(snapshot(), {150, 0}, {count, quantile}))

      assert {:error, :invalid_checkpoint_content} =
               PolarCheckpoint.project(bins(), @p, Map.put(snapshot(), {150, 0}, {count, quantile}))
    end

    test "rejects malformed observer snapshots without projecting partial content" do
      snapshot = snapshot()
      {warmup_count, warmup_quantile} = snapshot[{6, 18}]

      malformed = [
        :not_a_cell_map,
        Map.put(snapshot, {7, 27}, {warmup_count + 1, warmup_quantile}),
        Map.put(snapshot, {7, 27}, {warmup_count, %{warmup_quantile | buffer: Enum.reverse(warmup_quantile.buffer)}}),
        Map.put(snapshot, {7, 27}, {warmup_count, %{warmup_quantile | q: [1.0, 2.0, 3.0, 4.0, 5.0]}}),
        Map.put(snapshot, {7, 27}, {warmup_count, %{warmup_quantile | dnp: {0.0, 0.0, 0.0, 0.0, 0.0}}}),
        Map.put(snapshot, {7, 27}, %{count: warmup_count, quantile: warmup_quantile})
      ]

      for invalid <- malformed do
        assert {:error, :invalid_checkpoint_content} = PolarCheckpoint.project(bins(), @p, invalid)
      end

      assert {:error, :invalid_checkpoint_content} = PolarCheckpoint.project(bins(), 0.0, snapshot)
      assert {:error, :invalid_checkpoint_content} = PolarCheckpoint.project(bins(), 1.0, snapshot)
      assert {:error, :invalid_checkpoint_content} = PolarCheckpoint.project(:not_bins, @p, snapshot)
    end

    test "fails closed on a runtime grid too fine to index, without raising" do
      # `Bins.new/1` now refuses these outright, but the struct can still be built
      # directly — including by a term decoded from persisted state written before
      # the constructor guard existed. Projection must report that as invalid
      # content rather than crash the observer that owns the grid.
      for width <- [1.0e-320, 5.0e-324, 1.0e-8] do
        assert_raise ArgumentError, fn -> Bins.new(tws_width_mps: width) end

        overflowing = %Bins{twa_width_deg: 5.0, tws_width_mps: width, max_tws_mps: 51.4444}

        assert {:error, :invalid_checkpoint_content} = PolarCheckpoint.project(overflowing, @p, %{}),
               "tws_width_mps #{width} must fail closed"

        assert {:error, :invalid_checkpoint_content} =
                 PolarCheckpoint.project(overflowing, @p, snapshot())
      end
    end
  end

  describe "hydrate/1" do
    test "restores the exact runtime Bins and P-square configuration losslessly", %{dir: dir} do
      snapshot = snapshot()
      assert {:ok, content} = PolarCheckpoint.project(bins(), @p, snapshot)
      assert {:ok, bytes} = ContractCheckpoint.encode_content(:polar, 2, content)
      assert {:ok, decoded} = ContractCheckpoint.decode_content(:polar, 2, bytes)
      assert decoded == content

      assert {:ok, hydrated} = PolarCheckpoint.hydrate(decoded)
      assert hydrated.cells == snapshot
      assert hydrated.p === @p
      assert hydrated.bins == bins()

      # Every dropped P-square field is reconstructed bit-exactly.
      for {key, {count, quantile}} <- snapshot do
        {^count, restored} = hydrated.cells[key]
        assert restored == quantile
        assert restored.dnp === quantile.dnp
        assert restored.n === quantile.n
        assert restored.count === quantile.count
        assert restored.p === quantile.p
      end

      assert :ok = Store.save(dir, hydrated.cells)
      assert {:ok, ^snapshot} = Store.load(dir)
    end

    test "never reinterprets bare indices under caller default bin geometry" do
      # A grid that still ADMITS both fixture keys but assigns them different wind.
      custom = Bins.new(twa_width_deg: 2.5, tws_width_mps: 1.0, max_tws_mps: 30.0)
      refute custom == bins()
      assert Bins.valid_key?(custom, {5, 9})
      assert Bins.valid_key?(custom, {6, 18})

      snapshot = snapshot()
      assert {:ok, content} = PolarCheckpoint.project(custom, @p, snapshot)
      assert {:ok, bytes} = ContractCheckpoint.encode_content(:polar, 2, content)
      assert {:ok, decoded} = ContractCheckpoint.decode_content(:polar, 2, bytes)
      assert {:ok, hydrated} = PolarCheckpoint.hydrate(decoded)

      assert hydrated.bins == custom
      assert hydrated.cells == snapshot

      # The identical index pair means DIFFERENT wind under the two geometries;
      # hydration must carry the producing geometry rather than the default.
      assert Bins.center(hydrated.bins, {5, 9}) == Bins.center(custom, {5, 9})
      refute Bins.center(hydrated.bins, {5, 9}) == Bins.center(bins(), {5, 9})
    end

    test "round-trips an empty sailed polar" do
      assert {:ok, content} = PolarCheckpoint.project(bins(), @p, %{})
      assert content["cells"] == []
      assert {:ok, bytes} = ContractCheckpoint.encode_content(:polar, 2, content)
      assert {:ok, decoded} = ContractCheckpoint.decode_content(:polar, 2, bytes)
      assert {:ok, %{cells: cells, bins: hydrated_bins, p: @p}} = PolarCheckpoint.hydrate(decoded)
      assert cells == %{}
      assert hydrated_bins == bins()
    end

    test "rejects redundant, noncanonical, secret-capable, and open hydration content" do
      assert {:ok, valid} = PolarCheckpoint.project(bins(), @p, snapshot())
      [first, second] = valid["cells"]

      invalid = [
        Map.put(valid, "arbitrary_numeric_tree", [1, 2, 3]),
        Map.delete(valid, "p"),
        Map.delete(valid, "tws_width_mps"),
        Map.delete(valid, "twa_width_deg"),
        Map.delete(valid, "max_tws_mps"),
        %{valid | "cells" => [second, first]},
        %{valid | "cells" => [first, first]},
        # Redundant per-cell fields that the compact schema derives.
        %{valid | "cells" => [put_in(first, ["quantile", "p"], @p), second]},
        %{valid | "cells" => [put_in(first, ["quantile", "count"], first["count"]), second]},
        %{valid | "cells" => [put_in(first, ["quantile", "dnp"], [0.0, 0.45, 0.9, 0.95, 1.0]), second]},
        # n must carry exactly the three interior positions, never its endpoints.
        %{valid | "cells" => [put_in(first, ["quantile", "n"], [1, 2, 3, 5, 6]), second]},
        %{valid | "cells" => [put_in(first, ["quantile", "n"], [1, 3, 5]), second]},
        %{valid | "cells" => [put_in(first, ["quantile", "n"], [2, 3, 6]), second]},
        %{valid | "cells" => [put_in(first, ["quantile", "n"], [2, 3]), second]},
        %{valid | "cells" => [put_in(first, ["quantile", "n"], [5, 3, 2]), second]},
        # Noncanonical containers and out-of-grid indices.
        %{valid | "cells" => [put_in(first, ["quantile", "q"], List.to_tuple(first["quantile"]["q"])), second]},
        %{valid | "cells" => [put_in(first, ["quantile", "buffer"], [1.0]), second]},
        %{valid | "cells" => [first, put_in(second, ["quantile", "q"], [1.0, 2.0, 3.0, 4.0, 5.0])]},
        %{valid | "cells" => [Map.update!(first, "count", &(&1 + 1)), second]},
        %{valid | "cells" => [%{first | "tws_bin" => 100}, second]},
        %{valid | "cells" => [%{first | "twa_bin" => 36}, second]},
        %{valid | "p" => 1.0},
        %{valid | "p" => 0.0},
        %{valid | "tws_width_mps" => 0.0},
        %{valid | "twa_width_deg" => 0.0},
        %{valid | "max_tws_mps" => 0.0},
        %{valid | "tws_width_mps" => 1},
        Map.new(valid, fn {key, value} -> {String.to_atom(key), value} end)
      ]

      for content <- invalid do
        assert {:error, :invalid_checkpoint_content} = PolarCheckpoint.hydrate(content),
               "expected #{inspect(content)} to be rejected"
      end

      # The secret boundary keeps its own verdict rather than collapsing into
      # generic invalidity, at both the cell and the top level.
      assert {:error, :checkpoint_secret_forbidden} =
               PolarCheckpoint.hydrate(%{valid | "cells" => [Map.put(first, "psk", "synthetic-noncredential"), second]})

      assert {:error, :checkpoint_secret_forbidden} = PolarCheckpoint.hydrate(Map.put(valid, "metadata", %{}))

      assert {:error, :invalid_checkpoint_content} = PolarCheckpoint.hydrate(:not_content)
    end

    test "fails closed rather than raising on a finite but unboundedly small width" do
      assert {:ok, valid} = PolarCheckpoint.project(bins(), @p, snapshot())

      # Content whose declared width would overflow `extent / width` must be
      # refused with the documented error, never by raising out of hydration —
      # this content arrives from the network.
      for width <- [1.0e-320, 5.0e-324, 1.0e-300, 1.0e-8] do
        assert {:error, :invalid_checkpoint_content} =
                 PolarCheckpoint.hydrate(%{valid | "tws_width_mps" => width}),
               "tws_width_mps #{width} must fail closed"

        assert {:error, :invalid_checkpoint_content} =
                 PolarCheckpoint.hydrate(%{valid | "twa_width_deg" => width})
      end

      assert {:error, :invalid_checkpoint_content} =
               PolarCheckpoint.hydrate(%{valid | "max_tws_mps" => 1.7976931348623157e308})
    end

    test "rejects a declared grid that shifts the meaning of a persisted index" do
      assert {:ok, valid} = PolarCheckpoint.project(bins(), @p, snapshot())

      # Narrowing max_tws_mps drops the top of the TWS axis, orphaning cell {6, 18}.
      narrowed = %{valid | "max_tws_mps" => 3.0}
      assert {:error, :invalid_checkpoint_content} = PolarCheckpoint.hydrate(narrowed)

      # Widening the TWA bin shrinks the TWA axis, orphaning index 18.
      widened = %{valid | "twa_width_deg" => 20.0}
      assert {:error, :invalid_checkpoint_content} = PolarCheckpoint.hydrate(widened)
    end
  end

  describe "bounded domain size" do
    test "keeps a saturated 3600-cell sailed polar under the planned content ceiling" do
      bins = bins()
      {max_tws_bin, max_twa_bin} = Bins.max_key(bins)
      marker = feed(@p, [4.0, 4.2, 4.4, 4.6, 4.8, 5.0])

      # Every float and integer occupies a fixed 9 canonical bytes, so a grid of
      # marker-phase cells (buffer empty, all five markers live) is the exact
      # WORST CASE for the bounded domain rather than a sample of it.
      saturated =
        for tws_bin <- 0..max_tws_bin, twa_bin <- 0..max_twa_bin, into: %{} do
          {{tws_bin, twa_bin}, {marker.count, marker}}
        end

      assert map_size(saturated) == 3600

      assert {:ok, content} = PolarCheckpoint.project(bins, @p, saturated)
      assert length(content["cells"]) == 3600

      assert {:ok, bytes} = Canonical.encode(content)
      assert byte_size(bytes) < @planned_content_ceiling

      # Capacity is a TRANSPORT verdict and must never be laundered into a
      # content-validity verdict: the same content is schema-valid but does not
      # fit one un-chunked frame.
      assert {:error, :checkpoint_too_large} = ContractCheckpoint.encode_content(:polar, 2, content)
      assert {:ok, ^bytes} = ContractCheckpoint.canonical_content(:polar, 2, content)

      # No cell is ever truncated or dropped to fit.
      assert {:ok, hydrated} = PolarCheckpoint.hydrate(content)
      assert map_size(hydrated.cells) == 3600
      assert hydrated.cells == saturated
    end
  end

  defp bins, do: Bins.new()

  defp snapshot do
    marker = feed(@p, [4.0, 4.2, 4.4, 4.6, 4.8, 5.0])
    warmup = feed(@p, [3.0, 1.0, 4.0, 2.0])

    Map.new([
      {{6, 18}, {PSquare.count(warmup), warmup}},
      {{5, 9}, {PSquare.count(marker), marker}}
    ])
  end

  defp feed(p, values), do: Enum.reduce(values, PSquare.new(p), &PSquare.add(&2, &1))
end
