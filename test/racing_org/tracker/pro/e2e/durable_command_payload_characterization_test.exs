defmodule RacingOrg.Tracker.Pro.E2E.DurableCommandPayloadCharacterizationTest do
  @moduledoc """
  Characterizes the durable command-delivery payload divergence found during
  contract freezing — current behavior only, no redesign.

  The backend freezes protobuf `ServerReply` bytes as the durable
  `command_delivery` payload (the `race_assignment_server_reply` golden delivery
  vector), while the tracker ledger registry accepts only the canonical
  `{"type","args"}` envelope over `[:noop, :persist_checkpoints,
  :sync_checkpoints]` (the `canonical_noop` golden delivery vector). These tests
  push BOTH frozen payload shapes through the real client durable command path
  (`ChannelClient` -> `Commands.Ledger.Executor` -> ledger classification ->
  durable store -> exact `command_ack`) and pin what actually happens to each:

    * canonical envelope — classified `:execute`, applied by the registered
      `Noop` provider, durably retained, acked `:applied`/`:none` with the
      canonical `%{"outcome" => "applied"}` result, and replayed `:duplicate`
      on identical redelivery without re-executing.
    * protobuf `ServerReply` bytes — refused by the ledger payload fence
      (`Registry.decode_payload/1` cannot parse protobuf), durably retained as
      a `:rejected`/`:invalid_payload` terminal outcome with an empty result,
      acked exactly, replayed byte-identically on redelivery (still
      `:rejected`, never `:duplicate`), and the durable sequence advances past
      the rejected entry so the command stream is not wedged and later
      commands are not lost. No process crashes.

  Payload bytes come from the frozen priv/secure_transport/command_v1_vectors.json
  (never modified here) and are proven byte-identical to the vectors via the
  frozen payload hashes. The frozen delivery ENVELOPES pin command_epoch 9 with
  sequences 11-12, coordinates a fresh ledger can never admit (the epoch-reset
  fence requires sequence 1), so the exact frozen payload bytes are
  re-enveloped at admissible epoch/sequence coordinates under the same frozen
  vector identity (device, credential epoch, storage epoch, generation,
  manifest hash).
  """

  use Slipstream.SocketTest

  alias RacingOrg.Tracker.Pro.Commands.Ledger.Executor, as: CommandExecutor
  alias RacingOrg.Tracker.Pro.Commands.Ledger.Registry
  alias RacingOrg.Tracker.Pro.SecureTransport.ChannelClient
  alias RacingOrg.Tracker.Pro.SecureTransport.Handshake
  alias RacingOrg.Tracker.Pro.SecureTransport.KeyStore
  alias RacingOrg.Tracker.Pro.SecureTransport.Primitives
  alias RacingOrg.Tracker.Pro.SecureTransport.ServerIdentity
  alias RacingOrg.Tracker.Pro.SecureTransport.SessionHolder
  alias RacingOrg.Tracker.Protobuf.ServerReply

  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.{
    Canonical,
    Command,
    Control,
    Messages,
    Negotiation
  }

  @vectors_path Path.expand("../../../../../priv/secure_transport/command_v1_vectors.json", __DIR__)

  # The frozen delivery-vector identity (command_v1_vectors.json inputs). The
  # executor ledger, gate, and desired-state fences are all bound to it so the
  # frozen payload bytes travel over the same identity the vectors pin.
  @device_id Base.decode16!("00112233445566778899aabbccddeeff", case: :lower)
  @storage_epoch Base.decode16!("ffeeddccbbaa99887766554433221100", case: :lower)
  @manifest_hash :binary.copy(<<0xB2>>, 32)
  @credential_epoch 7
  @generation 42
  @boot_id <<0xE7::128>>
  @expires_at_ms 1_800_000_000_000
  @now_ms 1_700_000_000_000

  setup_all do
    %{document: @vectors_path |> File.read!() |> Jason.decode!()}
  end

  setup do
    base = Path.join(System.tmp_dir!(), "cmd_payload_char_#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf(base) end)

    {:ok, identity} = KeyStore.load_or_generate(base_path: base)
    server_private = :binary.copy(<<0xB6>>, 32)
    server_public = Primitives.ed25519_public_from_secret(server_private)

    previous = Application.get_env(:racing_org_tracker_pro, ServerIdentity)
    Application.put_env(:racing_org_tracker_pro, ServerIdentity, public_key: server_public)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:racing_org_tracker_pro, ServerIdentity)
        value -> Application.put_env(:racing_org_tracker_pro, ServerIdentity, value)
      end
    end)

    %{base: base, identity: identity, srv_pub: server_public, srv_priv: server_private}
  end

  # --- collaborators ---

  defmodule FakeBootstrap do
    alias RacingOrg.Tracker.Pro.SecureTransport.BootstrapState

    # 7 mirrors @credential_epoch (module attributes are not visible here).
    def credential_epoch(_server), do: {:ok, 7}

    def adopt_credential_epoch(epoch, _server),
      do: {:ok, %BootstrapState{phase: :registered, verified_credential_epoch: epoch}}

    def authenticated(_server),
      do: {:ok, %BootstrapState{phase: :authenticated, verified_credential_epoch: 7}}

    def session_lost(_server), do: {:error, :bootstrap_unavailable}
    def legacy_enrollment_request(_server), do: {:error, :bootstrap_unavailable}
  end

  defmodule FakeOutbox do
    def acknowledge(_server, _receipt, _opts), do: {:ok, []}
  end

  defmodule UnusedDesiredStateManager do
    def deliver_manifest(_server, _generation, _delivery), do: {:ok, :staged}
    def deliver_chunk(_server, _generation, _delivery), do: {:ok, :stored}
    def deliver_secret(_server, _generation, _delivery), do: {:ok, :accepted}
  end

  describe "frozen vector decode boundary" do
    test "the two frozen payload shapes split exactly at the ledger payload decoder", %{document: document} do
      canonical_payload = frozen_payload(document, "canonical_noop")
      protobuf_payload = frozen_payload(document, "race_assignment_server_reply")

      # The frozen delivery payload is byte-identical to the backend's frozen
      # protobuf ServerReply control envelope for the race assignment vector.
      assert protobuf_payload == hex(find_payload_vector(document, "race_assignment")["expected"]["server_reply_hex"])
      reply = ServerReply.decode(protobuf_payload)
      assert reply.protocol_version == 1
      assert reply.command.command_id == "01234567-89ab-cdef-fedc-ba9876543210"

      # The ledger registry accepts exactly the canonical envelope shape.
      assert Registry.decode_payload(canonical_payload) == {:ok, %{type: :noop, args: %{}}}

      # The protobuf bytes are not a canonical value at all: the leading
      # ServerReply field tag (0x08) reads as an oversized canonical list
      # header, so the registry refuses them before any envelope inspection.
      assert Registry.decode_payload(protobuf_payload) == {:error, :collection_too_large}
    end
  end

  describe "durable command delivery through the client" do
    test "the canonical envelope is accepted: executed, durably retained, acked :applied, replayed :duplicate", ctx do
      {client, topic, server_control, executor} = start_durable_client(ctx)
      canonical_payload = frozen_payload(ctx.document, "canonical_noop")

      delivery = delivery(command_id: command_id(1), command_sequence: 1, payload: canonical_payload)
      server_control = push_command(client, topic, server_control, delivery)
      {server_control, applied} = receive_ack(topic, server_control)

      # The full acceptance path: an exact ACK bound to every delivery fence
      # field, status :applied, and the Noop provider's canonical result as the
      # durable ledger entry's retained result bytes.
      assert_ack_binds(applied, delivery)
      assert applied.status == :applied
      assert applied.reason == :none
      assert {:ok, expected_result} = Canonical.encode(%{"outcome" => "applied"})
      assert applied.result == expected_result
      assert Canonical.decode(applied.result) == {:ok, %{"outcome" => "applied"}}

      assert {:ok, applied.result_hash} ==
               Command.result_hash(%{status: :applied, reason: :none, result: expected_result})

      # The identical redelivery is answered from the retained ledger entry as
      # :duplicate with the exact retained result bytes — nothing re-executes,
      # and only the status-bound fields differ from the original ACK.
      server_control = push_command(client, topic, server_control, delivery)
      {_server_control, duplicate} = receive_ack(topic, server_control)

      assert duplicate.status == :duplicate
      assert duplicate.reason == :none
      assert duplicate.result == applied.result

      assert {:ok, duplicate.result_hash} ==
               Command.result_hash(%{status: :duplicate, reason: :none, result: applied.result})

      assert Map.drop(duplicate, [:status, :result_hash]) == Map.drop(applied, [:status, :result_hash])
      assert Process.alive?(client)
      assert Process.alive?(executor)
    end

    test "protobuf ServerReply bytes are rejected :invalid_payload with an exact durable rejected ack", ctx do
      {client, topic, server_control, executor} = start_durable_client(ctx)
      protobuf_payload = frozen_payload(ctx.document, "race_assignment_server_reply")

      delivery = delivery(command_id: command_id(1), command_sequence: 1, payload: protobuf_payload)
      server_control = push_command(client, topic, server_control, delivery)
      {_server_control, rejected} = receive_ack(topic, server_control)

      # The chain stops at the ledger payload fence: no provider ever runs. The
      # store durably retains a terminal outcome and the client sends exactly
      # one rejected ACK bound to every delivery fence field.
      assert_ack_binds(rejected, delivery)
      assert rejected.status == :rejected
      assert rejected.reason == :invalid_payload
      assert rejected.result == <<>>

      assert {:ok, rejected.result_hash} ==
               Command.result_hash(%{status: :rejected, reason: :invalid_payload, result: <<>>})

      # The rejection is quiet and safe: exactly one control reply, no crash.
      refute_push(^topic, "control_v1", _extra, 50)
      assert Process.alive?(client)
      assert Process.alive?(executor)
    end

    test "the protobuf rejection is safe: retained, replayed identically, and the stream advances", ctx do
      {client, topic, server_control, executor} = start_durable_client(ctx)
      protobuf_payload = frozen_payload(ctx.document, "race_assignment_server_reply")
      canonical_payload = frozen_payload(ctx.document, "canonical_noop")

      rejected_delivery = delivery(command_id: command_id(1), command_sequence: 1, payload: protobuf_payload)
      server_control = push_command(client, topic, server_control, rejected_delivery)
      {server_control, rejected} = receive_ack(topic, server_control)
      assert rejected.status == :rejected
      assert rejected.reason == :invalid_payload

      # An identical redelivery replays the retained terminal outcome
      # byte-for-byte: still :rejected/:invalid_payload, never :duplicate.
      server_control = push_command(client, topic, server_control, rejected_delivery)
      {server_control, replayed} = receive_ack(topic, server_control)
      assert replayed == rejected

      # The rejected entry advanced the durable sequence, so the next command
      # (frozen canonical payload) is admitted and applied: the rejection
      # neither wedges the stream nor silently loses a later accepted entry.
      next_delivery = delivery(command_id: command_id(2), command_sequence: 2, payload: canonical_payload)
      server_control = push_command(client, topic, server_control, next_delivery)
      {_server_control, applied} = receive_ack(topic, server_control)

      assert_ack_binds(applied, next_delivery)
      assert applied.status == :applied
      assert applied.reason == :none

      assert Process.alive?(client)
      assert Process.alive?(executor)
    end
  end

  # --- harness (mirrors channel_client_command_test / channel_client_generic_delivery_test) ---

  defp start_durable_client(ctx) do
    executor =
      start_supervised!(
        {CommandExecutor,
         name: nil,
         path: Path.join(ctx.base, "commands.ledger"),
         device_id: @device_id,
         credential_epoch: @credential_epoch,
         storage_epoch: @storage_epoch,
         desired_state: fn -> {:ok, %{generation: @generation, manifest_hash: @manifest_hash}} end,
         gate: fn -> {:open, gate_binding()} end,
         trusted_now_ms: fn -> {:ok, @now_ms} end},
        id: make_ref()
      )

    {:ok, holder} = start_supervised({SessionHolder, name: nil}, id: make_ref())
    topic = "device:" <> ctx.identity.fingerprint

    client =
      start_supervised!(
        {ChannelClient,
         name: nil,
         auto_connect?: true,
         test_mode?: true,
         url: "wss://test.local/device_socket/websocket",
         session_holder: holder,
         boot_provisioner: {FakeBootstrap, :characterization_bootstrap},
         firmware_validator: fn -> :ok end,
         command_executor: executor,
         command_executor_module: CommandExecutor,
         outbox: :unused_outbox,
         outbox_module: FakeOutbox,
         checkpoint_pending: fn _outbox, _opts -> [] end,
         delivery_pending: fn _outbox, _opts -> [] end,
         receipt_evidence: fn _class -> :ok end,
         desired_state_manager: :unused_desired_state_manager,
         desired_state_manager_module: UnusedDesiredStateManager,
         desired_state_identity: fn -> {:ok, control_identity()} end,
         desired_state_compatibility: fn ->
           %{firmware_version: "0.7.0", firmware_git_sha: "0123abc", capabilities: []}
         end,
         desired_state_status: fn -> %{active: nil} end,
         keystore_opts: [base_path: ctx.base]},
        id: make_ref()
      )

    connect_and_assert_join(client, ^topic, %{}, :ok)
    server_session = complete_handshake(client, topic, ctx)
    assert_push(^topic, "wifi_status", _wifi_status)
    assert {:ok, server_control} = Control.new(:server, server_session)
    server_control = accept_control(client, topic, server_control)
    {client, topic, server_control, executor}
  end

  defp complete_handshake(client, topic, ctx) do
    {:ok, hello_wire, responder_state} =
      Handshake.responder_hello(
        server_identity_private: ctx.srv_priv,
        server_identity_public: ctx.srv_pub,
        device_identity_public: ctx.identity.public_key,
        epoch: @credential_epoch
      )

    push(client, topic, "handshake_hello", %{"hello" => Base.encode64(hello_wire)})
    assert_push(^topic, "handshake_init", %{"init" => init_b64})
    {:ok, init_wire} = Base.decode64(init_b64)
    {:ok, server_session} = Handshake.responder_finalize(responder_state, init_wire)
    push(client, topic, "handshake_ok", %{"session_id" => Base.encode64(server_session.session_id)})
    server_session
  end

  defp accept_control(client, topic, server_control) do
    {:ok, selection} = Negotiation.select(%{control_versions: [1], desired_state_versions: [1]})

    attrs = %{
      device_id: @device_id,
      credential_epoch: @credential_epoch,
      selected_control_version: selection.selected_control_version,
      selected_desired_version: selection.selected_desired_version,
      offer_hash: selection.offer_hash
    }

    {:ok, bytes} = Messages.encode(:control_accept, attrs)
    {:ok, frame, server_control} = Control.seal(server_control, :control_accept, bytes)
    push(client, topic, "control_v1", Control.encode_carrier(frame))

    assert_push(^topic, "control_v1", readiness_carrier, _ref, 2_000)
    assert {:ok, readiness_frame} = Control.decode_carrier(readiness_carrier)
    assert {:ok, :readiness, _readiness_bytes, server_control} = Control.open(server_control, readiness_frame)
    server_control
  end

  defp push_command(client, topic, server_control, delivery) do
    {:ok, bytes} = Messages.encode(:command_delivery, delivery)
    {:ok, frame, server_control} = Control.seal(server_control, :command_delivery, bytes)
    push(client, topic, "control_v1", Control.encode_carrier(frame))
    server_control
  end

  defp receive_ack(topic, server_control) do
    assert_push(^topic, "control_v1", carrier, _ref, 2_000)
    assert {:ok, frame} = Control.decode_carrier(carrier)
    assert {:ok, :command_ack, ack_bytes, server_control} = Control.open(server_control, frame)
    assert {:ok, ack} = Messages.decode(:command_ack, ack_bytes)
    {server_control, ack}
  end

  defp assert_ack_binds(ack, delivery) do
    assert ack.device_id == delivery.device_id
    assert ack.credential_epoch == delivery.credential_epoch
    assert ack.storage_epoch == delivery.storage_epoch
    assert ack.required_generation == delivery.required_generation
    assert ack.required_manifest_hash == delivery.required_manifest_hash
    assert ack.command_epoch == delivery.command_epoch
    assert ack.command_sequence == delivery.command_sequence
    assert ack.command_id == delivery.command_id
    assert ack.command_hash == delivery.command_hash
  end

  # Extract the exact frozen payload bytes by decoding the frozen delivery
  # envelope, then prove byte-fidelity against the frozen payload hash.
  defp frozen_payload(document, name) do
    vector =
      Enum.find(document["command_delivery"]["vectors"], &(&1["name"] == name)) ||
        flunk("frozen command_delivery vector #{inspect(name)} is missing")

    assert {:ok, frozen} = Messages.decode(:command_delivery, hex(vector["expected"]["command_delivery_hex"]))
    assert :crypto.hash(:sha256, frozen.payload) == hex(vector["expected"]["payload_hash_hex"])
    frozen.payload
  end

  defp find_payload_vector(document, name) do
    Enum.find(document["vectors"], &(&1["name"] == name)) ||
      flunk("frozen payload vector #{inspect(name)} is missing")
  end

  defp delivery(overrides) do
    payload = Keyword.fetch!(overrides, :payload)
    {:ok, payload_hash} = Command.payload_hash(payload)

    attrs = %{
      device_id: @device_id,
      credential_epoch: @credential_epoch,
      storage_epoch: @storage_epoch,
      required_generation: @generation,
      required_manifest_hash: @manifest_hash,
      command_epoch: 0,
      command_sequence: Keyword.fetch!(overrides, :command_sequence),
      command_id: Keyword.fetch!(overrides, :command_id),
      expires_at_ms: @expires_at_ms,
      payload_hash: payload_hash
    }

    {:ok, command_hash} = Command.hash(attrs)
    attrs |> Map.put(:command_hash, command_hash) |> Map.put(:payload, payload)
  end

  defp gate_binding do
    %{
      credential_epoch: @credential_epoch,
      storage_epoch: @storage_epoch,
      generation: @generation,
      manifest_hash: @manifest_hash
    }
  end

  defp control_identity do
    %{
      device_id: @device_id,
      credential_epoch: @credential_epoch,
      boot_id: @boot_id,
      storage_epoch: @storage_epoch
    }
  end

  defp command_id(n), do: <<n::128>>

  defp hex(value), do: Base.decode16!(value, case: :lower)
end
