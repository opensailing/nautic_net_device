defmodule RacingOrg.Tracker.Pro.DurableDelivery.Producer.DataSetTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.DurableDelivery.Producer.DataSet, as: Producer
  alias RacingOrg.Tracker.Protobuf.DataSet
  alias RacingOrg.Tracker.Protobuf.DataSet.DataPoint
  alias RacingOrg.Tracker.Protobuf.SpeedSample

  defmodule FakeOutbox do
    def enqueue(server, stream, payload, opts) do
      send(server.test_pid, {:enqueue, stream, payload, opts})
      server.result
    end
  end

  defmodule RaisingOutbox do
    def enqueue(_server, _stream, _payload, _opts), do: raise("simulated adapter failure")
  end

  defmodule ThrowingOutbox do
    def enqueue(_server, _stream, _payload, _opts), do: throw(:simulated_adapter_failure)
  end

  defmodule ExitingOutbox do
    def enqueue(_server, _stream, _payload, _opts), do: exit(:simulated_adapter_failure)
  end

  @receipt %{
    stream: :telemetry,
    device_id: <<1::128>>,
    credential_epoch: 7,
    storage_epoch: <<2::128>>,
    sequence: 11,
    payload_hash: <<3::256>>,
    cumulative_sequence: 0
  }

  test "accepts only after the exact existing DataSet protobuf bytes are durably admitted" do
    data_set =
      struct(DataSet,
        counter: 23,
        ref: "dataset-ref",
        boat_identifier: "logger-17",
        data_points: [
          struct(DataPoint,
            timestamp: %Google.Protobuf.Timestamp{seconds: 1_723_456_789, nanos: 123_000_000},
            hw_id: 42,
            sample: {:speed, %SpeedSample{speed_cm_s: 517}}
          )
        ]
      )

    encoded = DataSet.encode(data_set)
    outbox = %{test_pid: self(), result: {:ok, @receipt}}

    assert {:ok, @receipt} =
             Producer.admit(encoded,
               outbox: outbox,
               adapter: FakeOutbox,
               source_id: "legacy/datasets/dataset-ref"
             )

    expected_entry_id = :crypto.hash(:sha256, ["RacingOrg-DurableDataSet-v1", "legacy/datasets/dataset-ref"])
    assert_receive {:enqueue, :telemetry, ^encoded, [entry_id: ^expected_entry_id]}
  end

  test "the same opaque source identity produces the same idempotency key without exposing it" do
    encoded = DataSet.encode(struct(DataSet, counter: 24, ref: "dataset-ref-24"))
    source_id = "/data/datasets/private-device-dataset-ref"
    outbox = %{test_pid: self(), result: {:ok, @receipt}}

    assert {:ok, @receipt} =
             Producer.admit(encoded, outbox: outbox, adapter: FakeOutbox, source_id: source_id)

    assert_receive {:enqueue, :telemetry, ^encoded, [entry_id: first_entry_id]}
    refute first_entry_id =~ source_id

    assert {:ok, @receipt} =
             Producer.admit(encoded, outbox: outbox, adapter: FakeOutbox, source_id: source_id)

    assert_receive {:enqueue, :telemetry, ^encoded, [entry_id: ^first_entry_id]}
  end

  test "rejects transport-like or malformed success without an Outbox receipt identity" do
    encoded = DataSet.encode(struct(DataSet, counter: 24, ref: "dataset-ref-24"))

    for invalid_success <- [:ok, {:ok, :udp_sent}, {:ok, %{stream: :telemetry}}] do
      outbox = %{test_pid: self(), result: invalid_success}

      assert {:error, :invalid_outbox_response} =
               Producer.admit(encoded,
                 outbox: outbox,
                 adapter: FakeOutbox,
                 source_id: "legacy/datasets/dataset-ref-24"
               )

      assert_receive {:enqueue, :telemetry, ^encoded, [entry_id: _entry_id]}
    end
  end

  test "propagates identity, backpressure, and durability failures without accepting the DataSet" do
    encoded = DataSet.encode(struct(DataSet, counter: 24, ref: "dataset-ref-24"))

    failures = [
      {:error, :identity_unbound},
      {:error, :storage_epoch_mismatch},
      {:error, {:backpressure, :entry_capacity}},
      {:error, {:durability_uncertain, {:file_sync, :eio}}}
    ]

    for failure <- failures do
      outbox = %{test_pid: self(), result: failure}

      assert ^failure =
               Producer.admit(encoded,
                 outbox: outbox,
                 adapter: FakeOutbox,
                 source_id: "legacy/datasets/dataset-ref-24"
               )

      assert_receive {:enqueue, :telemetry, ^encoded, [entry_id: _entry_id]}
    end
  end

  test "rejects malformed admission inputs with explicit errors instead of raising" do
    encoded = DataSet.encode(struct(DataSet, counter: 25, ref: "dataset-ref-25"))
    outbox = %{test_pid: self(), result: {:ok, @receipt}}

    assert {:error, :invalid_encoded_data_set} =
             Producer.admit(<<>>, outbox: outbox, adapter: FakeOutbox, source_id: "source")

    assert {:error, :invalid_options} = Producer.admit(encoded, :not_options)
    assert {:error, :outbox_required} = Producer.admit(encoded, adapter: FakeOutbox, source_id: "source")
    assert {:error, :source_id_required} = Producer.admit(encoded, outbox: outbox, adapter: FakeOutbox)

    assert {:error, :invalid_source_id} =
             Producer.admit(encoded, outbox: outbox, adapter: FakeOutbox, source_id: <<>>)

    assert {:error, :invalid_source_id} =
             Producer.admit(encoded,
               outbox: outbox,
               adapter: FakeOutbox,
               source_id: String.duplicate("s", 65_536)
             )

    assert {:error, :invalid_adapter} =
             Producer.admit(encoded, outbox: outbox, adapter: String, source_id: "source")

    refute_receive {:enqueue, _stream, _payload, _opts}
  end

  test "fails closed when the injected adapter raises, throws, or exits" do
    encoded = DataSet.encode(struct(DataSet, counter: 26, ref: "dataset-ref-26"))
    opts = [outbox: :outbox, source_id: "source"]

    assert {:error, :outbox_adapter_failure} =
             Producer.admit(encoded, Keyword.put(opts, :adapter, RaisingOutbox))

    assert {:error, :outbox_adapter_failure} =
             Producer.admit(encoded, Keyword.put(opts, :adapter, ThrowingOutbox))

    assert {:error, :outbox_adapter_failure} =
             Producer.admit(encoded, Keyword.put(opts, :adapter, ExitingOutbox))
  end
end
