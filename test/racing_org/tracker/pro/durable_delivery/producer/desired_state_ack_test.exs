defmodule RacingOrg.Tracker.Pro.DurableDelivery.Producer.DesiredStateAckTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.DurableDelivery.Outbox.Owner
  alias RacingOrg.Tracker.Pro.DurableDelivery.Producer.DesiredStateAck, as: Producer
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.Messages

  @device_id Base.decode16!("00112233445566778899aabbccddeeff", case: :lower)
  @boot_id Base.decode16!("102132435465768798a9bacbdcedfe0f", case: :lower)
  @storage_epoch Base.decode16!("ffeeddccbbaa99887766554433221100", case: :lower)
  @credential_epoch 7
  @manifest_hash :binary.copy(<<0xA5>>, 32)
  @entry_id_domain "RacingOrg-DesiredStateAckEntryId-v1"

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
    stream: :desired_state_ack,
    device_id: @device_id,
    credential_epoch: @credential_epoch,
    storage_epoch: @storage_epoch,
    sequence: 11,
    payload_hash: <<3::256>>,
    cumulative_sequence: 0
  }

  test "encodes and durably admits the exact frozen ACK bytes" do
    ack = effective_ack()
    assert {:ok, encoded} = Messages.encode(:ack, ack)
    outbox = %{test_pid: self(), result: {:ok, @receipt}}

    assert {:ok, @receipt} =
             Producer.admit(ack, outbox: outbox, adapter: FakeOutbox)

    expected_entry_id =
      :crypto.hash(:sha256, [
        @entry_id_domain,
        :crypto.hash(:sha256, encoded)
      ])

    assert_receive {:enqueue, :desired_state_ack, ^encoded, [entry_id: ^expected_entry_id]}
  end

  test "same persisted ACK replay reaches the same opaque idempotency boundary" do
    ack = effective_ack()
    source_metadata = inspect(ack)
    outbox = %{test_pid: self(), result: {:ok, @receipt}}

    assert {:ok, @receipt} =
             Producer.admit(ack, outbox: outbox, adapter: FakeOutbox)

    assert_receive {:enqueue, :desired_state_ack, first_payload, [entry_id: first_entry_id]}

    assert {:ok, @receipt} =
             Producer.admit(ack, outbox: outbox, adapter: FakeOutbox)

    assert_receive {:enqueue, :desired_state_ack, ^first_payload, [entry_id: ^first_entry_id]}

    assert byte_size(first_entry_id) == 32
    refute first_entry_id =~ source_metadata
    refute first_entry_id =~ @device_id
    refute first_entry_id =~ @boot_id
    refute first_entry_id =~ @storage_epoch
  end

  test "boot-rebound ACK identity produces a distinct entry id" do
    ack = effective_ack()
    outbox = %{test_pid: self(), result: {:ok, @receipt}}
    other_boot_id = Base.decode16!("8899aabbccddeeff0011223344556677", case: :lower)

    assert {:ok, @receipt} =
             Producer.admit(ack, outbox: outbox, adapter: FakeOutbox)

    assert_receive {:enqueue, :desired_state_ack, _payload, [entry_id: first_entry_id]}

    assert {:ok, @receipt} =
             Producer.admit(%{ack | boot_id: other_boot_id},
               outbox: outbox,
               adapter: FakeOutbox
             )

    assert_receive {:enqueue, :desired_state_ack, _rebound_payload, [entry_id: rebound_entry_id]}

    refute rebound_entry_id == first_entry_id
  end

  test "a real Outbox keeps the exact ACK pending across restart and rejects duplicate replay" do
    root = Path.join(System.tmp_dir!(), "desired_state_ack_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    identity = fn -> {:ok, durable_identity()} end

    assert {:ok, owner} =
             Owner.start_link(
               root: root,
               identity: identity,
               streams: [:desired_state_ack],
               max_entries: 10,
               max_bytes: 10_000,
               segment_max_bytes: 4_096
             )

    on_exit(fn -> stop_owner(owner) end)

    ack = effective_ack()
    assert {:ok, encoded} = Messages.encode(:ack, ack)
    assert {:ok, receipt} = Producer.admit(ack, outbox: owner)
    assert [%{stream: :desired_state_ack, payload: ^encoded}] = Owner.pending(owner)

    assert :ok = stop_owner(owner)

    assert {:ok, reopened} =
             Owner.start_link(
               root: root,
               identity: identity,
               streams: [:desired_state_ack],
               max_entries: 10,
               max_bytes: 10_000,
               segment_max_bytes: 4_096
             )

    on_exit(fn -> stop_owner(reopened) end)

    assert [%{stream: :desired_state_ack, payload: ^encoded, sequence: sequence}] =
             Owner.pending(reopened)

    assert sequence == receipt.sequence
    assert {:error, :duplicate_entry_id} = Producer.admit(ack, outbox: reopened)
    assert [%{payload: ^encoded, sequence: ^sequence}] = Owner.pending(reopened)
  end

  test "rejects transport-like or malformed success without an Outbox receipt identity" do
    ack = effective_ack()

    for invalid_success <- [:ok, {:ok, :socket_sent}, {:ok, %{stream: :desired_state_ack}}] do
      outbox = %{test_pid: self(), result: invalid_success}

      assert {:error, :invalid_outbox_response} =
               Producer.admit(ack, outbox: outbox, adapter: FakeOutbox)

      assert_receive {:enqueue, :desired_state_ack, _encoded, [entry_id: _entry_id]}
    end
  end

  test "propagates durable admission failures unchanged" do
    ack = effective_ack()

    for failure <- [
          {:error, :duplicate_entry_id},
          {:error, :identity_unbound},
          {:error, :storage_epoch_mismatch},
          {:error, {:backpressure, :entry_capacity}},
          {:error, {:durability_uncertain, {:file_sync, :eio}}}
        ] do
      outbox = %{test_pid: self(), result: failure}

      assert ^failure = Producer.admit(ack, outbox: outbox, adapter: FakeOutbox)
      assert_receive {:enqueue, :desired_state_ack, _encoded, [entry_id: _entry_id]}
    end
  end

  test "rejects malformed ACKs and options before enqueue" do
    ack = effective_ack()
    outbox = %{test_pid: self(), result: {:ok, @receipt}}

    assert {:error, :invalid_ack} =
             Producer.admit(%{ack | manifest_hash: <<0>>},
               outbox: outbox,
               adapter: FakeOutbox
             )

    assert {:error, :invalid_ack} = Producer.admit(:not_an_ack, outbox: outbox)
    assert {:error, :invalid_options} = Producer.admit(ack, :not_options)
    assert {:error, :outbox_required} = Producer.admit(ack, adapter: FakeOutbox)

    assert {:error, :invalid_adapter} =
             Producer.admit(ack, outbox: outbox, adapter: String)

    refute_receive {:enqueue, _stream, _payload, _opts}
  end

  test "fails closed when the injected adapter raises, throws, or exits" do
    ack = effective_ack()
    opts = [outbox: :outbox]

    assert {:error, :outbox_adapter_failure} =
             Producer.admit(ack, Keyword.put(opts, :adapter, RaisingOutbox))

    assert {:error, :outbox_adapter_failure} =
             Producer.admit(ack, Keyword.put(opts, :adapter, ThrowingOutbox))

    assert {:error, :outbox_adapter_failure} =
             Producer.admit(ack, Keyword.put(opts, :adapter, ExitingOutbox))
  end

  defp effective_ack do
    Map.merge(durable_identity(), %{
      boot_id: @boot_id,
      generation: 42,
      manifest_hash: @manifest_hash,
      status: :effective
    })
  end

  defp durable_identity do
    %{
      device_id: @device_id,
      credential_epoch: @credential_epoch,
      storage_epoch: @storage_epoch
    }
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
