defmodule RacingOrg.Tracker.Pro.Race.RetentionTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.DurableDelivery.Producer.RaceRecording, as: RaceRecordingProducer
  alias RacingOrg.Tracker.Pro.Race.Recording
  alias RacingOrg.Tracker.Pro.Race.Retention

  setup do
    base = Path.join(System.tmp_dir!(), "nn_ret_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(base) end)
    %{base: base}
  end

  test "keeps the most recent 10 recordings and prunes the rest, with numeric N ordering", %{base: base} do
    for n <- 1..12, do: Recording.open(base, %{recording_id: "2026-06-03-#{n}"})

    dropped = Retention.prune(base, 10, pending: fn -> [] end)

    assert Enum.sort(dropped) == ["2026-06-03-1", "2026-06-03-2"]
    remaining = Recording.list(base)
    assert length(remaining) == 10
    assert "2026-06-03-12" in remaining
    assert "2026-06-03-3" in remaining
    refute "2026-06-03-1" in remaining
  end

  test "prunes across dates by recency", %{base: base} do
    Recording.open(base, %{recording_id: "2026-06-01-1"})
    Recording.open(base, %{recording_id: "2026-06-02-1"})
    Recording.open(base, %{recording_id: "2026-06-03-1"})

    assert ["2026-06-01-1"] = Retention.prune(base, 2, pending: fn -> [] end)
    remaining = Recording.list(base)
    assert "2026-06-03-1" in remaining
    assert "2026-06-02-1" in remaining
    refute "2026-06-01-1" in remaining
  end

  test "protects recordings with pending durable chunk or manifest entries", %{base: base} do
    for n <- 1..3 do
      base
      |> Recording.open(%{recording_id: "2026-06-03-#{n}"})
      |> Recording.append("sample")
      |> Recording.finalize()
    end

    chunk_entry_id =
      capture_entry_id(fn enqueue ->
        RaceRecordingProducer.admit_chunk(enqueue, "2026-06-03-1", "0001", "chunk")
      end)

    manifest_entry_id =
      capture_entry_id(fn enqueue ->
        manifest = struct(RacingOrg.Tracker.Protobuf.RaceManifest, race_recording_id: "2026-06-03-2")
        RaceRecordingProducer.admit_manifest(enqueue, "2026-06-03-2", manifest)
      end)

    pending = fn ->
      [
        %{stream: :race_recording_chunk, entry_id: chunk_entry_id},
        %{stream: :race_recording_manifest, entry_id: manifest_entry_id}
      ]
    end

    assert [] = Retention.prune(base, 1, pending: pending)
    assert Enum.sort(Recording.list(base)) == ["2026-06-03-1", "2026-06-03-2", "2026-06-03-3"]
  end

  test "fails closed when pending eligibility cannot be established", %{base: base} do
    for n <- 1..2, do: Recording.open(base, %{recording_id: "2026-06-03-#{n}"})

    assert [] = Retention.prune(base, 1)
    assert [] = Retention.prune(base, 1, pending: fn -> {:error, :outbox_owner_unavailable} end)
    assert Enum.sort(Recording.list(base)) == ["2026-06-03-1", "2026-06-03-2"]
  end

  test "requires explicit audited loss authorization to override pending protection", %{base: base} do
    for n <- 1..2, do: Recording.open(base, %{recording_id: "2026-06-03-#{n}"})

    pending_entry = pending_entry(:race_recording_manifest, "2026-06-03-1")

    assert [] = Retention.prune(base, 1, pending: fn -> [pending_entry] end)

    authorize_loss = fn entries, reason ->
      send(self(), {:authorized_loss, entries, reason})
      :ok
    end

    reason = "operator approved race artifact loss ticket RMA-96"

    assert ["2026-06-03-1"] =
             Retention.prune(base, 1,
               pending: fn -> [pending_entry] end,
               loss_reason: reason,
               authorize_loss: authorize_loss
             )

    assert_receive {:authorized_loss, [^pending_entry], ^reason}
    refute "2026-06-03-1" in Recording.list(base)
  end

  test "is a no-op when under the limit", %{base: base} do
    Recording.open(base, %{recording_id: "2026-06-03-1"})
    assert [] = Retention.prune(base, 10, pending: fn -> [] end)
    assert Recording.list(base) == ["2026-06-03-1"]
  end

  defp pending_entry(stream, recording_id) do
    entry_id =
      case stream do
        :race_recording_chunk ->
          capture_entry_id(fn enqueue ->
            RaceRecordingProducer.admit_chunk(enqueue, recording_id, "0001", "chunk")
          end)

        :race_recording_manifest ->
          manifest = struct(RacingOrg.Tracker.Protobuf.RaceManifest, race_recording_id: recording_id)
          capture_entry_id(fn enqueue -> RaceRecordingProducer.admit_manifest(enqueue, recording_id, manifest) end)
      end

    %{stream: stream, entry_id: entry_id}
  end

  defp capture_entry_id(admit) do
    {:ok, entry_id} = admit.(fn _stream, _payload, entry_id: entry_id -> {:ok, entry_id} end)
    entry_id
  end
end
