defmodule RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.CheckpointRuntime.PolarTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.Polar.Observer.Bins
  alias RacingOrg.Tracker.Pro.Polar.Observer.Gate
  alias RacingOrg.Tracker.Pro.Polar.Observer.PSquare
  alias RacingOrg.Tracker.Pro.Polar.Observer.RuntimeSnapshot
  alias RacingOrg.Tracker.Pro.Polar.Observer.Snapshot
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.Canonical
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.Checkpoint
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.CheckpointRuntime.Polar

  @canonical_size 1_893
  @canonical_sha256 "e993927cc5e8f215128d6993e554ede6a7ec55c8250c6ca32fe7e3973270905f"
  @content_hash_sha256 "4a0d6f2c35a06161d3753199be9e5fa7024af5272affc1ee8f396deb25fcf2f7"

  test "projects and hydrates the complete exact runtime snapshot" do
    snapshot = internal_snapshot()

    assert {:ok, wire} = Polar.project(snapshot)
    assert :ok = Polar.validate(wire)
    assert {:ok, ^snapshot} = Polar.hydrate(wire)

    assert wire["runtime_schema_version"] == 3
    assert wire["policy"]["gate"]["angle_band_deg"] == [25.0, 165.0]
    assert wire["policy"]["gate"]["heel_band_deg"] == [-45.0, 45.0]
    assert wire["policy"]["gate"]["angle_key"] == "twa_deg"
    assert %Canonical.Bytes{data: <<_::256>>} = wire["policy"]["admission_hash"]
    assert %Canonical.Bytes{data: <<_::256>>} = wire["learner"]["content"]["content_hash"]
    assert %Canonical.Bytes{} = wire["learner"]["content"]["content"]
    assert wire["window"]["count"] == 2
    assert length(wire["window"]["chunks"]) == 1
    assert hd(hd(wire["window"]["chunks"])) == [2_000, 5.0, 45.0, 4.0, 90.0, nil, nil, nil]

    assert {:ok, raw_canonical} = Canonical.encode(wire)
    assert {:ok, ^wire} = Canonical.decode(raw_canonical)
    assert byte_size(raw_canonical) == @canonical_size
    assert Base.encode16(:crypto.hash(:sha256, raw_canonical), case: :lower) == @canonical_sha256

    assert {:ok, canonical} = Checkpoint.canonical_content(:polar, 3, wire)
    assert canonical == raw_canonical
    assert {:ok, content_hash} = Checkpoint.content_hash(:polar, 3, canonical)
    assert Base.encode16(content_hash, case: :lower) == @content_hash_sha256
    assert {:ok, ^wire} = Checkpoint.decode_canonical_content(:polar, 3, canonical)
  end

  test "preserves authoritative equal-age and identical window-row semantics" do
    rows = [window_row(2_000), Map.put(window_row(2_000), :stw_mps, 4.1)]
    snapshot = internal_snapshot(rows)

    assert :ok = RuntimeSnapshot.preflight(snapshot)
    assert {:ok, wire} = Polar.project(snapshot)
    assert {:ok, ^snapshot} = Polar.hydrate(wire)

    duplicate_snapshot = internal_snapshot([window_row(2_000), window_row(2_000)])

    assert :ok = RuntimeSnapshot.preflight(duplicate_snapshot)
    assert {:ok, duplicate_wire} = Polar.project(duplicate_snapshot)
    assert {:ok, ^duplicate_snapshot} = Polar.hydrate(duplicate_wire)
  end

  test "fails closed for unknown fields, secret-capable fields, invalid enums, and malformed bands" do
    assert {:ok, wire} = Polar.project(internal_snapshot())

    invalid = [
      Map.put(wire, "unknown", true),
      put_in(wire, ["policy", "unknown"], true),
      put_in(wire, ["policy", "gate", "secret"], "forbidden"),
      put_in(wire, ["policy", "gate", "angle_key"], "made_up"),
      put_in(wire, ["policy", "gate", "angle_band_deg"], [25.0]),
      put_in(wire, ["window", "chunks", Access.at(0), Access.at(0)], [2_000, 5.0]),
      put_in(
        wire,
        ["policy", "admission_hash"],
        Map.put(wire["policy"]["admission_hash"], "unknown", true)
      )
    ]

    for candidate <- invalid do
      assert {:error, :invalid_checkpoint_content} = Polar.validate(candidate)
      assert {:error, :invalid_checkpoint_content} = Polar.hydrate(candidate)
    end
  end

  test "rejects noncanonical text and values outside agreed u64 or database bounds" do
    assert {:ok, wire} = Polar.project(internal_snapshot())
    decomposed = "boaté"

    invalid = [
      put_in(wire, ["authority", "boat_identifier"], decomposed),
      put_in(wire, ["learner", "content", "authority"], decomposed),
      put_in(wire, ["captured_at_utc_ms"], 0x1_0000_0000_0000_0000),
      put_in(wire, ["upstream_seq"], 9_223_372_036_854_775_808),
      put_in(wire, ["learner", "source_generation"], 9_223_372_036_854_775_808),
      put_in(wire, ["learner", "content", "source_generation"], 9_223_372_036_854_775_808)
    ]

    for candidate <- invalid do
      assert {:error, :invalid_checkpoint_content} = Polar.validate(candidate)
    end
  end

  test "canonical encode and decode cannot change authoritative negative-zero bits" do
    assert {:ok, wire} = Polar.project(internal_snapshot())

    negative_zero =
      <<0x8000_0000_0000_0000::64>>
      |> then(fn bits ->
        <<value::float-64>> = bits
        value
      end)

    for path <- [
          ["policy", "min_stw_mps"],
          ["policy", "gate", "max_accel_mps2"],
          ["window", "chunks", Access.at(0), Access.at(0), Access.at(1)]
        ] do
      candidate = put_in(wire, path, negative_zero)
      assert {:ok, bytes} = Canonical.encode(candidate)
      assert {:ok, decoded} = Canonical.decode(bytes)
      assert {:error, :invalid_checkpoint_content} = Polar.validate(candidate)
      refute negative_zero_wire_at_path?(decoded, path)

      case Polar.hydrate(decoded) do
        {:ok, hydrated} -> refute negative_zero_at_path?(hydrated, path)
        {:error, :invalid_checkpoint_content} -> :ok
      end
    end
  end

  test "enforces the 8 MiB cap on semantic canonical content with simultaneous large structures" do
    rows = for age_ms <- 99_999..0//-1, do: window_row(age_ms)

    snapshot = internal_snapshot(rows, 100_000)
    bins = Bins.new()
    marker = feed([3.5, 3.7, 3.9, 4.1, 4.3, 4.5])

    cells =
      for tws_bin <- 0..99, twa_bin <- 0..5, into: %{} do
        {{tws_bin, twa_bin}, {6, marker}}
      end

    dirty_keys =
      cells
      |> Map.keys()
      |> Enum.sort()
      |> Enum.map(fn {tws_bin, twa_bin} -> %{tws_bin: tws_bin, twa_bin: twa_bin} end)

    {:ok, learner_content} =
      Snapshot.capture(
        "boat-runtime",
        snapshot.policy.admission_hash,
        bins,
        0.9,
        600,
        cells
      )

    snapshot =
      snapshot
      |> put_in([:learner], %{source_generation: 600, content: learner_content})
      |> put_in([:sync, :dirty_keys], dirty_keys)
      |> put_in([:persistence_phase, :dirty_keys], dirty_keys)

    assert :ok = RuntimeSnapshot.preflight(snapshot)
    assert {:ok, wire} = Polar.project(snapshot)
    assert {:ok, bytes} = Checkpoint.canonical_content(:polar, 3, wire)
    assert byte_size(bytes) <= 8_388_608
    assert byte_size(:erlang.term_to_binary(snapshot, [:deterministic])) > byte_size(bytes)
  end

  @tag timeout: 120_000
  test "rejects a legal exact runtime whose canonical projection exceeds the semantic cap" do
    snapshot = oversized_runtime_snapshot()

    assert :ok = RuntimeSnapshot.preflight(snapshot)

    case Polar.project(snapshot) do
      {:error, :invalid_checkpoint_content} ->
        :ok

      {:ok, wire} ->
        assert {:ok, canonical} = Canonical.encode(wire)

        flunk(
          "project accepted #{byte_size(canonical)} canonical bytes, " <>
            "#{byte_size(canonical) - 8_388_608} over cap"
        )
    end
  end

  test "normalizes existing decomposed persisted authority at the schema-v3 projection boundary" do
    snapshot = internal_snapshot()
    decomposed = "boaté"
    normalized = String.normalize(decomposed, :nfc)

    snapshot =
      snapshot
      |> put_in([:authority, :boat_identifier], decomposed)
      |> put_in([:learner, :content, :authority], decomposed)

    assert :ok = RuntimeSnapshot.preflight(snapshot)
    assert {:ok, wire} = Polar.project(snapshot)
    assert wire["authority"]["boat_identifier"] == normalized
    assert wire["learner"]["content"]["authority"] == normalized
    assert {:ok, hydrated} = Polar.hydrate(wire)
    assert hydrated.authority.boat_identifier == normalized
    assert hydrated.learner.content.authority == normalized
  end

  test "binds the embedded legacy learner to polar schema v2, content hash, policy, and source generation" do
    assert {:ok, wire} = Polar.project(internal_snapshot())
    learner = wire["learner"]["content"]

    invalid = [
      put_in(wire, ["learner", "content", "kind"], "wind_shift"),
      put_in(wire, ["learner", "content", "schema_version"], 3),
      put_in(wire, ["learner", "content", "source_generation"], learner["source_generation"] + 1),
      put_in(wire, ["learner", "source_generation"], wire["learner"]["source_generation"] + 1),
      put_in(wire, ["learner", "content", "authority"], "other-boat"),
      put_in(wire, ["learner", "content", "policy_hash"], Canonical.bytes(:binary.copy(<<0xAA>>, 32))),
      put_in(wire, ["learner", "content", "content_hash"], Canonical.bytes(:binary.copy(<<0xBB>>, 32)))
    ]

    for candidate <- invalid do
      assert {:error, :invalid_checkpoint_content} = Polar.validate(candidate)
    end
  end

  @tag timeout: 120_000
  test "preserves a legal 100,000-row window without truncation and validates reversed chunk boundaries" do
    rows =
      for age_ms <- 99_999..0//-1 do
        window_row(age_ms)
      end

    snapshot = internal_snapshot(rows, 100_000)
    assert :ok = RuntimeSnapshot.preflight(snapshot)
    assert {:ok, wire} = Polar.project(snapshot)
    assert wire["window"]["count"] == 100_000
    assert Enum.map(wire["window"]["chunks"], &length/1) == [65_535, 34_465]
    assert {:ok, ^snapshot} = Polar.hydrate(wire)
    assert {:ok, bytes} = Checkpoint.canonical_content(:polar, 3, wire)
    assert byte_size(bytes) == 5_301_792

    previous = List.last(hd(wire["window"]["chunks"]))
    reversed = List.replace_at(hd(tl(wire["window"]["chunks"])), 0, hd(previous) + 1)
    reversed_boundary = put_in(wire, ["window", "chunks", Access.at(1), Access.at(0)], reversed)

    assert {:error, :invalid_checkpoint_content} = Polar.validate(reversed_boundary)
  end

  test "normalizes integer-valued bin geometry through the tracker runtime" do
    snapshot = internal_snapshot()

    bins = %{twa_width_deg: 5, tws_width_mps: 1, max_tws_mps: 50}

    {:ok, learner_content} =
      Snapshot.capture(
        "boat-runtime",
        snapshot.policy.admission_hash,
        Bins.new(twa_width_deg: 5, tws_width_mps: 1, max_tws_mps: 50),
        0.9,
        10,
        %{}
      )

    snapshot =
      snapshot
      |> put_in([:policy, :bins], bins)
      |> put_in([:learner, :content], learner_content)
      |> put_in([:sync, :dirty_keys], [])
      |> put_in([:persistence_phase, :dirty_keys], [])

    assert :ok = RuntimeSnapshot.preflight(snapshot)
    assert {:ok, wire} = Polar.project(snapshot)
    assert {:ok, hydrated} = Polar.hydrate(wire)
    assert hydrated.policy.bins == %{twa_width_deg: 5.0, tws_width_mps: 1.0, max_tws_mps: 50.0}
  end

  test "maps the closed angle enum without creating atoms from input" do
    snapshot = put_in(internal_snapshot(), [:policy, :gate, :angle_key], :awa_deg)
    {:ok, admission_hash} = policy_hash(snapshot.policy)
    snapshot = put_in(snapshot, [:policy, :admission_hash], admission_hash)
    snapshot = put_in(snapshot, [:learner, :content, :policy_hash], admission_hash)
    assert :ok = RuntimeSnapshot.preflight(snapshot)

    assert {:ok, wire} = Polar.project(snapshot)
    assert wire["policy"]["gate"]["angle_key"] == "awa_deg"
    assert {:ok, ^snapshot} = Polar.hydrate(wire)

    before = :erlang.system_info(:atom_count)
    invalid = put_in(wire, ["policy", "gate", "angle_key"], "never_an_existing_polar_angle_atom")
    assert {:error, :invalid_checkpoint_content} = Polar.hydrate(invalid)
    assert :erlang.system_info(:atom_count) == before
  end

  defp internal_snapshot(window \\ [window_row(2_000), window_row(1_000)], window_size \\ 3) do
    bins = Bins.new()
    gate = Gate.new(min_dwell: min(3, window_size))
    {:ok, admission_hash} = Snapshot.policy_hash(gate, 0.3, window_size, 0.9)

    cells = %{
      {5, 9} => {6, feed([3.5, 3.7, 3.9, 4.1, 4.3, 4.5])},
      {6, 18} => {4, feed([2.0, 2.2, 2.4, 2.6])}
    }

    {:ok, learner_content} = Snapshot.capture("boat-runtime", admission_hash, bins, 0.9, 10, cells)

    snapshot = %{
      version: 1,
      captured_at_utc_ms: 1_786_536_000_000,
      authority: %{boat_identifier: "boat-runtime"},
      policy: %{
        admission_hash: admission_hash,
        gate: Map.from_struct(gate),
        min_stw_mps: 0.3,
        window_size: window_size,
        p: 0.9,
        sample_ms: 60_000,
        sync_ms: 60_000,
        persist_ms: 60_000,
        persistence_enabled: true,
        bins: Map.from_struct(bins)
      },
      learner: %{source_generation: 10, content: learner_content},
      upstream_seq: 41,
      window: window,
      sync: %{dirty_keys: [%{tws_bin: 5, twa_bin: 9}], last_sync_age_ms: 45_000},
      persistence_phase: %{
        dirty_keys: [%{tws_bin: 6, twa_bin: 18}],
        force: true,
        last_persist_age_ms: 30_000
      },
      tick: %{remaining_ms: 45_000}
    }

    assert :ok = RuntimeSnapshot.preflight(snapshot)
    snapshot
  end

  defp oversized_runtime_snapshot do
    boat_identifier = :binary.copy(<<0x61>>, 65_535)
    rows = for age_ms <- 99_999..0//-1, do: maximum_window_row(age_ms)
    bins = Bins.new(tws_width_mps: 0.01)
    gate = Gate.new(min_dwell: 3)
    marker = feed([3.5, 3.7, 3.9, 4.1, 4.3, 4.5])
    cells = for tws_bin <- 0..4_389, into: %{}, do: {{tws_bin, 0}, {6, marker}}

    dirty_keys =
      for tws_bin <- 0..4_389 do
        %{tws_bin: tws_bin, twa_bin: 0}
      end

    {:ok, admission_hash} = Snapshot.policy_hash(gate, 0.3, 100_000, 0.9)

    {:ok, learner_content} =
      Snapshot.capture(
        boat_identifier,
        admission_hash,
        bins,
        0.9,
        4_390,
        cells
      )

    %{
      version: 1,
      captured_at_utc_ms: 1_786_536_000_000,
      authority: %{boat_identifier: boat_identifier},
      policy: %{
        admission_hash: admission_hash,
        gate: Map.from_struct(gate),
        min_stw_mps: 0.3,
        window_size: 100_000,
        p: 0.9,
        sample_ms: 60_000,
        sync_ms: 60_000,
        persist_ms: 60_000,
        persistence_enabled: true,
        bins: Map.from_struct(bins)
      },
      learner: %{source_generation: 4_390, content: learner_content},
      upstream_seq: 41,
      window: rows,
      sync: %{dirty_keys: dirty_keys, last_sync_age_ms: 45_000},
      persistence_phase: %{
        dirty_keys: dirty_keys,
        force: true,
        last_persist_age_ms: 30_000
      },
      tick: %{remaining_ms: 45_000}
    }
  end

  defp maximum_window_row(age_ms) do
    %{
      age_ms: age_ms,
      tws_mps: 1_310.64,
      twa_deg: 360.0,
      stw_mps: 1_310.64,
      heading_deg: 360.0,
      heel_deg: 180.0,
      under_power?: true,
      engine_rpm: 10_000_000.0
    }
  end

  defp window_row(age_ms) do
    %{
      age_ms: age_ms,
      tws_mps: 5.0,
      twa_deg: 45.0,
      stw_mps: 4.0,
      heading_deg: 90.0,
      heel_deg: nil,
      under_power?: nil,
      engine_rpm: nil
    }
  end

  defp feed(values), do: Enum.reduce(values, PSquare.new(0.9), &PSquare.add(&2, &1))

  defp negative_zero_wire_at_path?(wire, ["policy", "min_stw_mps"]),
    do: negative_zero?(wire["policy"]["min_stw_mps"])

  defp negative_zero_wire_at_path?(wire, ["policy", "gate", "max_accel_mps2"]),
    do: negative_zero?(wire["policy"]["gate"]["max_accel_mps2"])

  defp negative_zero_wire_at_path?(wire, ["window" | _rest]),
    do: negative_zero?(wire["window"]["chunks"] |> hd() |> hd() |> Enum.at(1))

  defp negative_zero_at_path?(snapshot, ["policy", "min_stw_mps"]),
    do: negative_zero?(snapshot.policy.min_stw_mps)

  defp negative_zero_at_path?(snapshot, ["policy", "gate", "max_accel_mps2"]),
    do: negative_zero?(snapshot.policy.gate.max_accel_mps2)

  defp negative_zero_at_path?(snapshot, ["window" | _rest]),
    do: negative_zero?(hd(snapshot.window).tws_mps)

  defp negative_zero?(value) do
    <<bits::unsigned-big-64>> = <<value::float-big-64>>
    bits == 0x8000_0000_0000_0000
  end

  defp policy_hash(policy) do
    gate = struct!(Gate, policy.gate)
    Snapshot.policy_hash(gate, policy.min_stw_mps, policy.window_size, policy.p)
  end
end
