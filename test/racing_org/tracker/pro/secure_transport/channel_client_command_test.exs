defmodule RacingOrg.Tracker.Pro.SecureTransport.ChannelClientCommandTest do
  @moduledoc """
  Authenticated `control_v1/:command_delivery` routing: classification, durable
  intent, fenced effect, durable terminal outcome, and exact ACK encoding, plus
  the legacy direct-command fence that keeps a negotiated durable session from
  applying an unfenced effect or emitting a legacy ACK.
  """
  use Slipstream.SocketTest

  alias RacingOrg.Tracker.Pro.DesiredStateTestSupport, as: DS
  alias RacingOrg.Tracker.Pro.SecureTransport.ChannelClient
  alias RacingOrg.Tracker.Pro.SecureTransport.Handshake
  alias RacingOrg.Tracker.Pro.SecureTransport.KeyStore
  alias RacingOrg.Tracker.Pro.SecureTransport.Primitives
  alias RacingOrg.Tracker.Pro.SecureTransport.ServerIdentity
  alias RacingOrg.Tracker.Pro.SecureTransport.SessionHolder
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1, as: DesiredStateV1

  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.{
    Canonical,
    Command,
    Control,
    Messages,
    Negotiation,
    Receipt
  }

  @logical_device_id <<0xD1::128>>
  @boot_id <<0xD2::128>>
  @storage_epoch <<0xD3::128>>
  @manifest_hash :binary.copy(<<0xB7>>, 32)
  @control_epoch 0
  @generation 5

  setup do
    base = Path.join(System.tmp_dir!(), "cc_command_#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf(base) end)

    {:ok, identity} = KeyStore.load_or_generate(base_path: base)
    seed = :binary.copy(<<0xB2>>, 32)
    srv_pub = Primitives.ed25519_public_from_secret(seed)

    prev = Application.get_env(:racing_org_tracker_pro, ServerIdentity)
    Application.put_env(:racing_org_tracker_pro, ServerIdentity, public_key: srv_pub)

    on_exit(fn ->
      case prev do
        nil -> Application.delete_env(:racing_org_tracker_pro, ServerIdentity)
        value -> Application.put_env(:racing_org_tracker_pro, ServerIdentity, value)
      end
    end)

    %{base: base, identity: identity, srv_pub: srv_pub, srv_priv: seed}
  end

  # --- collaborators ---

  defmodule FakeOutbox do
    def acknowledge(server, receipt, opts) do
      send(server, {:acknowledge, receipt, opts})
      {:ok, []}
    end
  end

  defmodule FakeDesiredStateManager do
    def deliver_manifest(server, generation, delivery) do
      send(server, {:desired_state_delivery, :manifest_delivery, generation, delivery})
      {:ok, :staged}
    end

    def deliver_chunk(server, generation, delivery) do
      send(server, {:desired_state_delivery, :section_chunk, generation, delivery})
      {:ok, :stored}
    end

    def deliver_secret(server, generation, delivery) do
      send(server, {:desired_state_delivery, :secret_delivery, generation, delivery})
      {:ok, :accepted}
    end
  end

  defmodule FailingDesiredStateManager do
    def deliver_manifest(_server, _generation, _delivery), do: raise("manager failed")
    def deliver_chunk(_server, _generation, _delivery), do: exit(:manager_failed)
    def deliver_secret(_server, _generation, _delivery), do: throw(:manager_failed)
  end

  # Stands in for the production executor: it records every delivery and, unless
  # scripted otherwise, produces a real encodable ACK — applied the first time a
  # command hash is seen and duplicate on every replay.
  defmodule FakeExecutor do
    use GenServer

    @ack_fence_keys [
      :device_id,
      :credential_epoch,
      :storage_epoch,
      :required_generation,
      :required_manifest_hash,
      :command_epoch,
      :command_sequence,
      :command_id,
      :command_hash
    ]

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    def deliver(server, delivery), do: GenServer.call(server, {:deliver, delivery})

    def observed(server), do: server |> GenServer.call(:observed) |> Enum.reverse()

    @impl true
    def init(opts), do: {:ok, %{result: Keyword.get(opts, :result), observed: [], applied: MapSet.new()}}

    @impl true
    def handle_call({:deliver, delivery}, _from, %{result: nil} = state) do
      {status, event} =
        if MapSet.member?(state.applied, delivery.command_hash),
          do: {:duplicate, :replay},
          else: {:applied, :execute}

      state = %{
        state
        | applied: MapSet.put(state.applied, delivery.command_hash),
          observed: [{event, delivery.command_id} | state.observed]
      }

      {:reply, {:ack, ack(delivery, status)}, state}
    end

    def handle_call({:deliver, delivery}, _from, state) do
      {:reply, state.result, %{state | observed: [{:deliver, delivery.command_id} | state.observed]}}
    end

    def handle_call(:observed, _from, state), do: {:reply, state.observed, state}

    defp ack(delivery, status) do
      {:ok, result} = Canonical.encode(%{"outcome" => "applied"})
      {:ok, result_hash} = Command.result_hash(%{status: status, reason: :none, result: result})

      delivery
      |> Map.take(@ack_fence_keys)
      |> Map.merge(%{status: status, reason: :none, result_hash: result_hash, result: result})
    end
  end

  describe "authenticated command delivery" do
    test "routes a delivery through the executor and sends the exact ACK on the control topic", ctx do
      {client, topic, server_control, executor} = start_command_client(ctx)

      delivery = delivery(command_id: command_id(1), payload: payload(:noop))
      {server_control, _frame} = push_command(client, topic, server_control, delivery)

      assert_push(^topic, "control_v1", ack_carrier)
      assert {:ok, ack_frame} = Control.decode_carrier(ack_carrier)
      assert {:ok, :command_ack, ack_bytes, _control} = Control.open(server_control, ack_frame)
      assert {:ok, ack} = Messages.decode(:command_ack, ack_bytes)

      assert ack.device_id == @logical_device_id
      assert ack.credential_epoch == @control_epoch
      assert ack.storage_epoch == @storage_epoch
      assert ack.required_generation == @generation
      assert ack.required_manifest_hash == @manifest_hash
      assert ack.command_epoch == delivery.command_epoch
      assert ack.command_sequence == delivery.command_sequence
      assert ack.command_id == delivery.command_id
      assert ack.command_hash == delivery.command_hash
      assert ack.status == :applied
      assert ack.reason == :none

      assert [{:execute, _id}] = FakeExecutor.observed(executor)
    end

    test "replays the exact retained ACK bytes for a duplicate delivery without re-executing", ctx do
      {client, topic, server_control, executor} = start_command_client(ctx)
      delivery = delivery(command_id: command_id(1), payload: payload(:noop))

      {server_control, _frame} = push_command(client, topic, server_control, delivery)
      assert_push(^topic, "control_v1", first_carrier)
      assert {:ok, first_frame} = Control.decode_carrier(first_carrier)
      assert {:ok, :command_ack, first_bytes, server_control} = Control.open(server_control, first_frame)

      {server_control, _frame} = push_command(client, topic, server_control, delivery)
      assert_push(^topic, "control_v1", second_carrier)
      assert {:ok, second_frame} = Control.decode_carrier(second_carrier)
      assert {:ok, :command_ack, second_bytes, _control} = Control.open(server_control, second_frame)

      assert {:ok, first} = Messages.decode(:command_ack, first_bytes)
      assert {:ok, second} = Messages.decode(:command_ack, second_bytes)
      assert first.status == :applied
      assert second.status == :duplicate
      # The retained result bytes replay exactly; the hash binds the status, so a
      # duplicate legitimately hashes differently from the original applied ACK.
      assert second.result == first.result

      assert {:ok, second.result_hash} ==
               Command.result_hash(%{status: :duplicate, reason: :none, result: first.result})

      # Exactly one effect for two identical authenticated deliveries; the second
      # was answered from retained state.
      assert [{:execute, id}, {:replay, id}] = FakeExecutor.observed(executor)
      assert id == delivery.command_id
    end

    test "a deferred classification sends no ACK and never wedges the control plane", ctx do
      {client, topic, server_control, executor} =
        start_command_client(ctx, executor_result: {:defer, :trusted_clock_unavailable})

      delivery = delivery(command_id: command_id(1), payload: payload(:noop))
      {_server_control, _frame} = push_command(client, topic, server_control, delivery)

      refute_push(^topic, "control_v1", _ack, 50)
      assert Process.alive?(client)
      assert [{:deliver, _}] = FakeExecutor.observed(executor)
    end

    test "a delivery arriving before control readiness is refused without an effect", ctx do
      {client, topic, server_control, executor} = start_command_client(ctx, accept_control?: false)

      delivery = delivery(command_id: command_id(1), payload: payload(:noop))
      {_server_control, _frame} = push_command(client, topic, server_control, delivery)

      refute_push(^topic, "control_v1", _ack, 50)
      assert FakeExecutor.observed(executor) == []
      assert Process.alive?(client)
    end

    test "an unavailable executor drops the delivery instead of acking or crashing", ctx do
      {client, topic, server_control, _executor} = start_command_client(ctx, executor: :no_such_executor)

      delivery = delivery(command_id: command_id(1), payload: payload(:noop))
      {_server_control, _frame} = push_command(client, topic, server_control, delivery)

      refute_push(^topic, "control_v1", _ack, 50)
      assert Process.alive?(client)
    end

    test "a command delivery on a foreign topic is ignored entirely", ctx do
      {client, topic, server_control, executor} = start_command_client(ctx)

      delivery = delivery(command_id: command_id(1), payload: payload(:noop))
      {:ok, bytes} = Messages.encode(:command_delivery, delivery)
      {:ok, frame, _control} = Control.seal(server_control, :command_delivery, bytes)
      push(client, topic <> ":other", "control_v1", Control.encode_carrier(frame))

      refute_push(_any_topic, "control_v1", _ack, 50)
      assert FakeExecutor.observed(executor) == []
    end
  end

  describe "authenticated desired-state deliveries" do
    test "dispatches manifest, chunk, and secret deliveries with the owning session generation", ctx do
      {client, topic, server_control, _executor} =
        start_command_client(ctx,
          desired_state_manager: self(),
          desired_state_manager_module: FakeDesiredStateManager
        )

      fixture =
        DS.generation_fixture(
          device_id: @logical_device_id,
          credential_epoch: @control_epoch,
          boot_id: @boot_id,
          storage_epoch: @storage_epoch,
          generation: @generation,
          wifi_secrets: [DS.secret_descriptor()]
        )

      deliveries = [
        {:manifest_delivery, fixture.delivery},
        {:section_chunk, fixture |> DS.chunks() |> hd()},
        {:secret_delivery, DS.secret_delivery(fixture)}
      ]

      expected_generation = :sys.get_state(client).assigns.session.generation

      server_control =
        Enum.reduce(deliveries, server_control, fn {type, delivery}, control ->
          {:ok, bytes} = Messages.encode(type, delivery)
          {:ok, frame, next_control} = Control.seal(control, type, bytes)
          push(client, topic, "control_v1", Control.encode_carrier(frame))

          assert_receive {:desired_state_delivery, ^type, ^expected_generation, ^delivery}, 1_000
          refute_push(^topic, "control_v1", _response, 20)
          next_control
        end)

      assert %Control{} = server_control
      assert Process.alive?(client)
    end

    test "refuses desired-state deliveries before control readiness", ctx do
      {client, topic, server_control, _executor} =
        start_command_client(ctx,
          accept_control?: false,
          desired_state_manager: self(),
          desired_state_manager_module: FakeDesiredStateManager
        )

      fixture =
        DS.generation_fixture(
          device_id: @logical_device_id,
          credential_epoch: @control_epoch,
          boot_id: @boot_id,
          storage_epoch: @storage_epoch,
          generation: @generation
        )

      {:ok, bytes} = Messages.encode(:manifest_delivery, fixture.delivery)
      {:ok, frame, _control} = Control.seal(server_control, :manifest_delivery, bytes)
      push(client, topic, "control_v1", Control.encode_carrier(frame))

      refute_receive {:desired_state_delivery, _, _, _}, 100
      refute_push(^topic, "control_v1", _response, 20)
      assert Process.alive?(client)
    end

    test "normalizes desired-state collaborator raises, exits, and throws", ctx do
      {client, topic, server_control, _executor} =
        start_command_client(ctx,
          desired_state_manager: :unavailable,
          desired_state_manager_module: FailingDesiredStateManager
        )

      fixture =
        DS.generation_fixture(
          device_id: @logical_device_id,
          credential_epoch: @control_epoch,
          boot_id: @boot_id,
          storage_epoch: @storage_epoch,
          generation: @generation,
          wifi_secrets: [DS.secret_descriptor()]
        )

      deliveries = [
        {:manifest_delivery, fixture.delivery},
        {:section_chunk, fixture |> DS.chunks() |> hd()},
        {:secret_delivery, DS.secret_delivery(fixture)}
      ]

      Enum.reduce(deliveries, server_control, fn {type, delivery}, control ->
        {:ok, bytes} = Messages.encode(type, delivery)
        {:ok, frame, next_control} = Control.seal(control, type, bytes)
        push(client, topic, "control_v1", Control.encode_carrier(frame))
        refute_push(^topic, "control_v1", _response, 20)
        assert Process.alive?(client)
        next_control
      end)
    end
  end

  describe "legacy direct command fence" do
    test "a negotiated durable session never applies a legacy command or emits a legacy ack", ctx do
      {client, topic, _server_control, _executor} = start_command_client(ctx)

      push(client, topic, "command", legacy_command_payload())

      refute_push(^topic, "ack", _payload, 50)
      assert Process.alive?(client)
    end

    test "an explicitly legacy negotiated session still applies and acks the direct command", ctx do
      {client, topic} = start_legacy_client(ctx)

      push(client, topic, "command", legacy_command_payload())

      assert_push(^topic, "ack", ack_payload)
      assert %{v: 1, acks: [%{command_id: "legacy-1"}]} = ack_payload
    end
  end

  describe "authenticated durable delivery receipts" do
    test "dispatches the exact authenticated receipt idempotently without a wire reply", ctx do
      {client, topic, server_control, _executor} =
        start_command_client(ctx, outbox: self(), outbox_module: FakeOutbox)

      receipt = %{
        device_id: @logical_device_id,
        credential_epoch: @control_epoch,
        storage_epoch: @storage_epoch,
        stream: :telemetry,
        sequence: 1,
        payload_hash: :binary.copy(<<0x21>>, 32),
        cumulative_sequence: 1
      }

      assert {:ok, receipt_hash} = Receipt.hash(receipt)
      wire_receipt = Map.put(receipt, :receipt_hash, receipt_hash)
      assert {:ok, bytes} = Messages.encode(:delivery_receipt, wire_receipt)
      assert {:ok, frame, _control} = Control.seal(server_control, :delivery_receipt, bytes)
      push(client, topic, "control_v1", Control.encode_carrier(frame))

      assert_receive {:acknowledge, ^receipt, [idempotent: true]}, 1_000
      refute_push(^topic, "control_v1", _response, 50)
      assert Process.alive?(client)
    end

    test "refuses a receipt before control readiness without mutating the outbox", ctx do
      {client, topic, server_control, _executor} =
        start_command_client(ctx,
          accept_control?: false,
          outbox: self(),
          outbox_module: FakeOutbox
        )

      receipt = %{
        device_id: @logical_device_id,
        credential_epoch: @control_epoch,
        storage_epoch: @storage_epoch,
        stream: :telemetry,
        sequence: 1,
        payload_hash: :binary.copy(<<0x22>>, 32),
        cumulative_sequence: 1
      }

      assert {:ok, receipt_hash} = Receipt.hash(receipt)
      wire_receipt = Map.put(receipt, :receipt_hash, receipt_hash)
      assert {:ok, bytes} = Messages.encode(:delivery_receipt, wire_receipt)
      assert {:ok, frame, _control} = Control.seal(server_control, :delivery_receipt, bytes)
      push(client, topic, "control_v1", Control.encode_carrier(frame))

      refute_receive {:acknowledge, _, _}, 100
      refute_push(^topic, "control_v1", _response, 20)
      assert Process.alive?(client)
    end
  end

  # --- helpers ---

  defp start_command_client(ctx, opts \\ []) do
    accept_control? = Keyword.get(opts, :accept_control?, true)

    executor =
      start_supervised!({FakeExecutor, [result: Keyword.get(opts, :executor_result)]},
        id: {FakeExecutor, System.unique_integer([:positive])}
      )

    {:ok, holder} = start_supervised({SessionHolder, name: nil})
    topic = "device:" <> ctx.identity.fingerprint

    client =
      start_supervised!(
        {ChannelClient,
         name: nil,
         auto_connect?: true,
         test_mode?: true,
         url: "wss://test.local/device_socket/websocket",
         session_holder: holder,
         firmware_validator: fn -> :ok end,
         command_executor: Keyword.get(opts, :executor, executor),
         command_executor_module: FakeExecutor,
         outbox: Keyword.get(opts, :outbox, :unused_outbox),
         outbox_module: Keyword.get(opts, :outbox_module, FakeOutbox),
         checkpoint_pending: fn _outbox, _opts -> [] end,
         delivery_pending: fn _outbox, _opts -> [] end,
         desired_state_manager: Keyword.get(opts, :desired_state_manager, :unused_desired_state_manager),
         desired_state_manager_module: Keyword.get(opts, :desired_state_manager_module, FakeDesiredStateManager),
         desired_state_identity: fn -> {:ok, control_identity()} end,
         desired_state_compatibility: fn ->
           %{
             firmware_version: "0.7.0",
             firmware_git_sha: "0123abc",
             capabilities: Enum.map(DesiredStateV1.capabilities(), fn {name, _id, version} -> {name, version} end)
           }
         end,
         desired_state_status: fn -> %{active: nil} end,
         keystore_opts: [base_path: ctx.base]}
      )

    connect_and_assert_join(client, ^topic, %{}, :ok)
    server_session = complete_handshake(client, topic, ctx)
    assert_push(^topic, "wifi_status", _wifi_status)
    assert {:ok, server_control} = Control.new(:server, server_session)

    server_control =
      if accept_control? do
        {control, _frame} = push_control_accept(client, topic, server_control)
        assert_push(^topic, "control_v1", _readiness)
        control
      else
        server_control
      end

    {client, topic, server_control, executor}
  end

  defp start_legacy_client(ctx) do
    commands = start_supervised!({RacingOrg.Tracker.Pro.Commands, name: nil, device_id: "dev-legacy"})
    {:ok, holder} = start_supervised({SessionHolder, name: nil})
    topic = "device:" <> ctx.identity.fingerprint

    client =
      start_supervised!(
        {ChannelClient,
         name: nil,
         auto_connect?: true,
         test_mode?: true,
         control_offer: :legacy,
         url: "wss://test.local/device_socket/websocket",
         session_holder: holder,
         firmware_validator: fn -> :ok end,
         commands: commands,
         keystore_opts: [base_path: ctx.base]}
      )

    connect_and_assert_join(client, ^topic, %{}, :ok)
    _server_session = complete_handshake(client, topic, ctx)
    assert_push(^topic, "wifi_status", _wifi_status)
    {client, topic}
  end

  defp complete_handshake(client, topic, ctx) do
    {:ok, hello_wire, responder_state} =
      Handshake.responder_hello(
        server_identity_private: ctx.srv_priv,
        server_identity_public: ctx.srv_pub,
        device_identity_public: ctx.identity.public_key,
        epoch: @control_epoch
      )

    push(client, topic, "handshake_hello", %{"hello" => Base.encode64(hello_wire)})
    assert_push(^topic, "handshake_init", %{"init" => init_b64})
    {:ok, init_wire} = Base.decode64(init_b64)
    {:ok, server_session} = Handshake.responder_finalize(responder_state, init_wire)
    push(client, topic, "handshake_ok", %{"session_id" => Base.encode64(server_session.session_id)})
    server_session
  end

  defp push_control_accept(client, topic, server_control) do
    offer = %{control_versions: [1], desired_state_versions: [1]}
    {:ok, selection} = Negotiation.select(offer)

    attrs = %{
      device_id: @logical_device_id,
      credential_epoch: @control_epoch,
      selected_control_version: selection.selected_control_version,
      selected_desired_version: selection.selected_desired_version,
      offer_hash: selection.offer_hash
    }

    {:ok, bytes} = Messages.encode(:control_accept, attrs)
    {:ok, frame, server_control} = Control.seal(server_control, :control_accept, bytes)
    push(client, topic, "control_v1", Control.encode_carrier(frame))
    {server_control, frame}
  end

  defp push_command(client, topic, server_control, delivery) do
    {:ok, bytes} = Messages.encode(:command_delivery, delivery)
    {:ok, frame, server_control} = Control.seal(server_control, :command_delivery, bytes)
    push(client, topic, "control_v1", Control.encode_carrier(frame))
    {server_control, frame}
  end

  defp legacy_command_payload do
    alias RacingOrg.Tracker.Protobuf.{DeviceCommand, RaceAssignment, ServerReply}

    command =
      struct(DeviceCommand,
        command_id: "legacy-1",
        assignment_id: "asg-1",
        assignment_version: 1,
        payload: {:race_assignment, struct(RaceAssignment, race_session_id: "rs-1")}
      )

    reply = struct(ServerReply, protocol_version: 1, device_id: "", command: command)
    %{"command_id" => "legacy-1", "reply" => Base.encode64(ServerReply.encode(reply))}
  end

  defp control_identity do
    %{
      device_id: @logical_device_id,
      credential_epoch: @control_epoch,
      boot_id: @boot_id,
      storage_epoch: @storage_epoch
    }
  end

  defp payload(type, args \\ %{}) do
    {:ok, bytes} = Canonical.encode(%{"type" => Atom.to_string(type), "args" => args})
    bytes
  end

  defp delivery(overrides) do
    body = Keyword.get(overrides, :payload, "command")

    attrs = %{
      device_id: @logical_device_id,
      credential_epoch: @control_epoch,
      storage_epoch: @storage_epoch,
      required_generation: @generation,
      required_manifest_hash: @manifest_hash,
      command_epoch: Keyword.get(overrides, :command_epoch, 0),
      command_sequence: Keyword.get(overrides, :command_sequence, 1),
      command_id: Keyword.get(overrides, :command_id, command_id(1)),
      expires_at_ms: Keyword.get(overrides, :expires_at_ms, 1_800_000_000_000),
      payload_hash: :crypto.hash(:sha256, body)
    }

    {:ok, command_hash} = Command.hash(attrs)
    attrs |> Map.put(:command_hash, command_hash) |> Map.put(:payload, body)
  end

  defp command_id(n), do: <<n::128>>
end
