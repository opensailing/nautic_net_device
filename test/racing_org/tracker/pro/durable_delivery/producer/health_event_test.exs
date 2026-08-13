defmodule RacingOrg.Tracker.Pro.DurableDelivery.Producer.HealthEventTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.DurableDelivery.HealthEvent.V1
  alias RacingOrg.Tracker.Pro.DurableDelivery.Outbox.Owner
  alias RacingOrg.Tracker.Pro.DurableDelivery.Producer.HealthEvent, as: Producer

  @device_id Base.decode16!("00112233445566778899aabbccddeeff", case: :lower)
  @storage_epoch Base.decode16!("ffeeddccbbaa99887766554433221100", case: :lower)
  @manifest_hash :binary.copy(<<0xA5>>, 32)
  @entry_id_domain "RacingOrg-TrackerHealthEventEntryId-v1"

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
    stream: :health,
    device_id: @device_id,
    credential_epoch: 7,
    storage_epoch: @storage_epoch,
    sequence: 11,
    payload_hash: <<3::256>>,
    cumulative_sequence: 0
  }

  test "accepts only after exact validated health-event bytes are durably admitted" do
    health_event = health_event(:outbox_unhealthy, %{reason_code: :outbox_not_writable})
    assert {:ok, payload} = V1.encode(health_event)
    receipt = %{@receipt | payload_hash: :crypto.hash(:sha256, payload)}
    outbox = %{test_pid: self(), result: {:ok, receipt}}

    assert {:ok, ^receipt} = Producer.admit(health_event, outbox: outbox, adapter: FakeOutbox)

    expected_entry_id =
      :crypto.hash(:sha256, [
        @entry_id_domain,
        :crypto.hash(:sha256, payload)
      ])

    assert_receive {:enqueue, :health, ^payload, [entry_id: ^expected_entry_id]}
  end

  test "the same exact event reaches the same idempotency boundary" do
    health_event = health_event(:receipt_progress, %{stream: :telemetry, cumulative_sequence: 91})
    assert {:ok, payload} = V1.encode(health_event)
    receipt = %{@receipt | payload_hash: :crypto.hash(:sha256, payload)}
    outbox = %{test_pid: self(), result: {:ok, receipt}}

    assert {:ok, ^receipt} = Producer.admit(health_event, outbox: outbox, adapter: FakeOutbox)
    assert_receive {:enqueue, :health, first_payload, [entry_id: first_entry_id]}

    assert {:ok, ^receipt} = Producer.admit(health_event, outbox: outbox, adapter: FakeOutbox)
    assert_receive {:enqueue, :health, ^first_payload, [entry_id: ^first_entry_id]}

    assert byte_size(first_entry_id) == 32
    refute first_entry_id =~ @manifest_hash
  end

  test "a changed occurrence or evidence selects a distinct event identity" do
    first = health_event(:receipt_progress, %{stream: :telemetry, cumulative_sequence: 91})
    second = %{first | occurred_at_ms: 124}
    third = %{first | cumulative_sequence: 92}

    for health_event <- [first, second, third] do
      assert {:ok, payload} = V1.encode(health_event)
      receipt = %{@receipt | payload_hash: :crypto.hash(:sha256, payload)}
      outbox = %{test_pid: self(), result: {:ok, receipt}}

      assert {:ok, ^receipt} = Producer.admit(health_event, outbox: outbox, adapter: FakeOutbox)
    end

    assert_receive {:enqueue, :health, _first_payload, [entry_id: first_entry_id]}
    assert_receive {:enqueue, :health, _second_payload, [entry_id: second_entry_id]}
    assert_receive {:enqueue, :health, _third_payload, [entry_id: third_entry_id]}
    assert MapSet.size(MapSet.new([first_entry_id, second_entry_id, third_entry_id])) == 3
  end

  test "the Outbox receipt hash binds the exact admitted payload bytes" do
    first = health_event(:receipt_progress, %{stream: :telemetry, cumulative_sequence: 91})
    second = %{first | cumulative_sequence: 92}
    assert {:ok, first_payload} = V1.encode(first)
    assert {:ok, second_payload} = V1.encode(second)

    for {health_event, payload} <- [{first, first_payload}, {second, second_payload}] do
      payload_hash = :crypto.hash(:sha256, payload)
      receipt = %{@receipt | payload_hash: payload_hash}
      outbox = %{test_pid: self(), result: {:ok, receipt}}

      assert {:ok, ^receipt} = Producer.admit(health_event, outbox: outbox, adapter: FakeOutbox)
      assert_receive {:enqueue, :health, ^payload, [entry_id: _entry_id]}
    end

    refute first_payload == second_payload
    refute :crypto.hash(:sha256, first_payload) == :crypto.hash(:sha256, second_payload)
  end

  test "a real Outbox preserves exact bytes across restart and rejects duplicate replay" do
    root = Path.join(System.tmp_dir!(), "health_event_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    identity = fn -> {:ok, durable_identity()} end

    assert {:ok, owner} = start_owner(root, identity)
    on_exit(fn -> stop_owner(owner) end)

    health_event = health_event(:validation_succeeded)
    assert {:ok, payload} = V1.encode(health_event)
    assert {:ok, receipt} = Producer.admit(health_event, outbox: owner)
    assert [%{stream: :health, payload: ^payload}] = Owner.pending(owner)

    assert :ok = stop_owner(owner)
    assert {:ok, reopened} = start_owner(root, identity)
    on_exit(fn -> stop_owner(reopened) end)

    assert [%{stream: :health, payload: ^payload, sequence: sequence}] = Owner.pending(reopened)
    assert sequence == receipt.sequence
    assert {:error, :duplicate_entry_id} = Producer.admit(health_event, outbox: reopened)
    assert [%{stream: :health, payload: ^payload, sequence: ^sequence}] = Owner.pending(reopened)
  end

  test "returns only the exact validated Outbox receipt" do
    health_event = health_event(:validation_succeeded)

    for invalid_success <- [
          :ok,
          {:ok, :socket_sent},
          {:ok, Map.delete(@receipt, :payload_hash)},
          {:ok, Map.put(@receipt, :transport, :sent)},
          {:ok, Map.put(@receipt, :stream, :telemetry)},
          {:ok, Map.put(@receipt, :device_id, <<0::128>>)},
          {:ok, Map.put(@receipt, :storage_epoch, <<0::128>>)},
          {:ok, Map.put(@receipt, :credential_epoch, 0x1_0000_0000)},
          {:ok, Map.put(@receipt, :payload_hash, <<4::256>>)},
          {:ok, Map.put(@receipt, :cumulative_sequence, 1)}
        ] do
      outbox = %{test_pid: self(), result: invalid_success}

      assert {:error, :invalid_outbox_response} =
               Producer.admit(health_event, outbox: outbox, adapter: FakeOutbox)

      assert_receive {:enqueue, :health, _payload, [entry_id: _entry_id]}
    end
  end

  test "propagates durable admission failures unchanged" do
    health_event = health_event(:validation_succeeded)

    for failure <- [
          {:error, :duplicate_entry_id},
          {:error, :identity_unbound},
          {:error, :storage_epoch_mismatch},
          {:error, {:backpressure, :entry_capacity}},
          {:error, {:durability_uncertain, {:file_sync, :eio}}}
        ] do
      outbox = %{test_pid: self(), result: failure}

      assert ^failure = Producer.admit(health_event, outbox: outbox, adapter: FakeOutbox)
      assert_receive {:enqueue, :health, _payload, [entry_id: _entry_id]}
    end
  end

  test "rejects invalid events and options before enqueue" do
    health_event = health_event(:validation_succeeded)
    outbox = %{test_pid: self(), result: {:ok, @receipt}}

    assert {:error, :invalid_health_event} =
             health_event
             |> Map.put(:metadata, %{})
             |> Producer.admit(outbox: outbox, adapter: FakeOutbox)

    assert {:error, :secret_bearing_health_event} =
             health_event
             |> Map.put(:access_token, "secret")
             |> Producer.admit(outbox: outbox, adapter: FakeOutbox)

    assert {:error, :invalid_health_event} = Producer.admit(:not_an_event, outbox: outbox)
    assert {:error, :invalid_options} = Producer.admit(health_event, :not_options)
    assert {:error, :outbox_required} = Producer.admit(health_event, adapter: FakeOutbox)
    assert {:error, :invalid_adapter} = Producer.admit(health_event, outbox: outbox, adapter: String)

    refute_receive {:enqueue, _stream, _payload, _opts}
  end

  test "fails closed when the injected adapter raises, throws, or exits" do
    health_event = health_event(:validation_succeeded)
    opts = [outbox: :outbox]

    assert {:error, :outbox_adapter_failure} =
             Producer.admit(health_event, Keyword.put(opts, :adapter, RaisingOutbox))

    assert {:error, :outbox_adapter_failure} =
             Producer.admit(health_event, Keyword.put(opts, :adapter, ThrowingOutbox))

    assert {:error, :outbox_adapter_failure} =
             Producer.admit(health_event, Keyword.put(opts, :adapter, ExitingOutbox))
  end

  defp health_event(event_type, extra \\ %{}) do
    Map.merge(
      %{
        event_type: event_type,
        occurred_at_ms: 123,
        firmware_version: "0.7.0-rc.1",
        firmware_git_sha: String.duplicate("a", 40),
        target: %{
          credential_epoch: 7,
          desired_generation: 42,
          manifest_hash: @manifest_hash
        }
      },
      extra
    )
  end

  defp durable_identity do
    %{device_id: @device_id, credential_epoch: 7, storage_epoch: @storage_epoch}
  end

  defp start_owner(root, identity) do
    Owner.start_link(
      root: root,
      identity: identity,
      streams: [:health],
      max_entries: 10,
      max_bytes: 10_000,
      segment_max_bytes: 4_096
    )
  end

  defp stop_owner(owner) do
    if Process.alive?(owner) do
      reference = Process.monitor(owner)
      Process.unlink(owner)
      Process.exit(owner, :shutdown)

      receive do
        {:DOWN, ^reference, :process, _pid, _reason} -> :ok
      after
        5_000 -> {:error, :timeout}
      end
    else
      :ok
    end
  end
end
