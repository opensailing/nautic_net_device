defmodule RacingOrg.Tracker.Pro.E2E.BlankToOperationalTest do
  @moduledoc """
  Blank-to-operational end-to-end chain.

  One chained scenario drives a single blank incarnation (fresh keystore base
  path, uninitialized bootstrap state, empty desired-state store, no durable
  outbox backlog) through, in order:

    1. v2 boot provisioning/enrollment — `BootstrapStateMachine.reconcile/1`
       challenges, registers, and persists verified registration authority for
       a fresh device, and the supervised `BootProvisioner` restarts over that
       durable state without any network activity;
    2. the secure-transport handshake and control_v1 negotiation — a live
       `ChannelClient` joins `device:<fp>`, completes the real `Handshake`
       cryptography against `Slipstream.SocketTest`'s conceptual server, marks
       the enrolled `BootProvisioner` authenticated through production wiring,
       verifies `control_accept`, and answers with a `readiness` bound to the
       enrolled identity (no effective generation yet);
    3. desired-state generation delivery and activation — sealed
       `manifest_delivery`/`section_chunk` control frames flow through the
       live client into the real `Manager`, which stages, activates, records
       output authority AT activation, commits the pointer, and opens the
       isolated `OperationalGate`;
    4. the operational gate and output fence — external output permission is
       read through `OperationalGate.output_permitted?/1`,
       `OutputFence.permitted?/1`, and the client's own injected output fence
       guarding a real `computed_values_data` push.

  Key frozen behavior: output authority is recorded at ACTIVATION. Before the
  first activation, output is permitted via the legacy carve-out (gate closed,
  no authority recorded). From the moment activation begins, output permission
  tracks the gate: fenced while the gate is closed during the apply, permitted
  once the gate opens, and fenced again when the lease dies after activation.

  Chain boundary: the chain runs contiguously from the blank bootstrap through
  enrollment, handshake, control negotiation, wire delivery, activation, gate
  opening, and output fencing in this one module. It stops at these injected
  edges: enrollment backend calls are injected challenge/register functions
  producing genuine signed v2 receipts verified against the pinned trust
  anchor (no HTTP); the websocket is `Slipstream.SocketTest`'s conceptual
  server (real frames and crypto, no network socket); the `Manager`'s applier
  callbacks, section owners (the test process), and ACK sink are the standard
  injected test collaborators, so section-owner runtimes and ACK transport
  back over the channel are outside the chain; the durable outbox is
  represented by injected empty pending callbacks; and every gate/fence read
  uses this test's isolated `OperationalGate` term key — the default
  persistent-term key of the shared test VM is never touched.
  """

  use Slipstream.SocketTest

  alias RacingOrg.Tracker.Pro.DesiredState.{Manager, OperationalGate, OutputFence, Store}
  alias RacingOrg.Tracker.Pro.DesiredStateTestSupport, as: DS
  alias RacingOrg.Tracker.Pro.RecoveryV2TestSupport, as: RecoverySupport
  alias RacingOrg.Tracker.Pro.SecureTransport.BootProvisioner
  alias RacingOrg.Tracker.Pro.SecureTransport.BootstrapState
  alias RacingOrg.Tracker.Pro.SecureTransport.BootstrapStateMachine
  alias RacingOrg.Tracker.Pro.SecureTransport.BootstrapStateStore
  alias RacingOrg.Tracker.Pro.SecureTransport.ChannelClient
  alias RacingOrg.Tracker.Pro.SecureTransport.Handshake
  alias RacingOrg.Tracker.Pro.SecureTransport.KeyStore
  alias RacingOrg.Tracker.Pro.SecureTransport.Primitives
  alias RacingOrg.Tracker.Pro.SecureTransport.ServerIdentity
  alias RacingOrg.Tracker.Pro.SecureTransport.SessionHolder
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1, as: Contract
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.{Control, Messages, Negotiation}

  @serial "000000001234abcd"
  # Synthetic, test-only key material (same convention as the transport suites).
  @device_seed :binary.copy(<<0x2B>>, 32)
  @server_seed :binary.copy(<<0xB2>>, 32)
  @boot_id <<0xE2::128>>
  @storage_epoch <<0xE3::128>>
  @credential_epoch 0
  @generation 1

  setup do
    root = Path.join(System.tmp_dir!(), "blank_to_operational_#{System.unique_integer([:positive])}")
    identity_base = Path.join(root, "identity")
    store_base = Path.join(root, "desired_state")

    # Fresh or concurrent BEAMs can reuse this suffix in the shared OS temp
    # directory, so remove interrupted-run artifacts before the chain starts.
    File.rm_rf!(root)
    on_exit(fn -> File.rm_rf(root) end)

    srv_pub = Primitives.ed25519_public_from_secret(@server_seed)
    prev_server = Application.get_env(:racing_org_tracker_pro, ServerIdentity)
    Application.put_env(:racing_org_tracker_pro, ServerIdentity, public_key: srv_pub)
    on_exit(fn -> restore_env(ServerIdentity, prev_server) end)

    %{
      root: root,
      identity_base: identity_base,
      store_base: store_base,
      srv_pub: srv_pub,
      srv_priv: @server_seed
    }
  end

  test "a blank incarnation enrolls, handshakes, activates a delivered generation, and only then fences output on the gate",
       ctx do
    test_pid = self()
    enrolled_device_id = RecoverySupport.device_id()

    # ------------------------------------------------------------------
    # 1. Blank incarnation: no identity, no bootstrap authority, no
    #    desired-state store — and therefore not connectable.
    # ------------------------------------------------------------------
    assert {:error, :not_provisioned} = KeyStore.load(base_path: ctx.identity_base)
    assert {:error, :candidate_not_staged} = KeyStore.load_candidate(base_path: ctx.identity_base)

    assert {:ok, %BootstrapState{phase: :uninitialized, authority: nil}} =
             BootstrapStateStore.load(base_path: ctx.identity_base)

    store = Store.new(base_dir: ctx.store_base, storage_epoch: @storage_epoch)
    assert Store.active(store) == :empty
    assert Store.pending_acks(store) == {:ok, []}
    assert Store.activation_journal(store) == :empty

    bootstrap_opts = [
      keystore_opts: [base_path: ctx.identity_base, seed_generator: fn -> @device_seed end],
      state_store_opts: [base_path: ctx.identity_base],
      hardware_identity_fun: fn -> {:ok, @serial} end,
      server_public_key: RecoverySupport.server_public_key()
    ]

    # The pinned transport server identity and the enrollment trust anchor are
    # the same authority in this chain.
    assert ctx.srv_pub == RecoverySupport.server_public_key()

    channel_opts = [keystore_opts: [base_path: ctx.identity_base], bootstrap_opts: bootstrap_opts]
    refute connectable_on_device?(channel_opts)

    # ------------------------------------------------------------------
    # 2. Boot provisioning/enrollment: fresh unknown hardware challenges
    #    first, then registers v2 and persists verified authority.
    # ------------------------------------------------------------------
    challenge_fun = fn identity, serial ->
      RecoverySupport.challenge_result(identity, serial, classification: :not_enrolled, reason: :none)
    end

    register_fun = fn identity, serial ->
      RecoverySupport.registration_result(identity, serial, device_id: enrolled_device_id)
    end

    assert {:ok, %BootstrapState{phase: :registered} = registered} =
             BootstrapStateMachine.reconcile(
               bootstrap_opts ++
                 [
                   challenge_fun: challenge_fun,
                   register_fun: register_fun,
                   commit_fun: fn _identity, _receipt -> flunk("fresh registration must not commit recovery") end
                 ]
             )

    assert registered.authority.kind == :registration
    assert registered.authority.logical_device_id == enrolled_device_id
    assert registered.authority.credential_epoch == @credential_epoch
    assert is_binary(registered.authority.receipt)

    assert {:ok, device_identity} = KeyStore.load(base_path: ctx.identity_base)
    assert {:error, :candidate_not_staged} = KeyStore.load_candidate(base_path: ctx.identity_base)
    assert connectable_on_device?(channel_opts)

    # The supervised coordinator restarts over the durable enrollment without
    # touching the network and exposes the verified epoch-zero authority.
    {:ok, holder} = start_supervised({SessionHolder, name: nil})

    provisioner =
      start_supervised!(
        {BootProvisioner,
         bootstrap_opts ++
           [
             name: nil,
             session_holder: holder,
             challenge_fun: fn _identity, _serial -> flunk("an enrolled restart must not challenge") end,
             register_fun: fn _identity, _serial -> flunk("an enrolled restart must not re-register") end,
             commit_fun: fn _identity, _receipt -> flunk("an enrolled restart must not commit recovery") end,
             status_fun: fn _identity, _receipt -> flunk("an enrolled restart must not query recovery status") end
           ]}
      )

    assert %BootstrapState{phase: :registered} = BootProvisioner.current_state(provisioner)
    assert {:ok, @credential_epoch} = BootProvisioner.credential_epoch(provisioner)

    # ------------------------------------------------------------------
    # 3. Isolated operational gate for this incarnation. Blank means: gate
    #    closed, no authority recorded, output PERMITTED (legacy carve-out).
    # ------------------------------------------------------------------
    term_key = {__MODULE__, make_ref()}
    gate_name = {:global, {__MODULE__, term_key}}
    manager_name = {:global, {__MODULE__, term_key, :manager}}
    controller_capability = make_ref()

    {:ok, _gate_pid} =
      OperationalGate.start_link(
        name: gate_name,
        term_key: term_key,
        controller: manager_name,
        controller_capability: controller_capability
      )

    on_exit(fn ->
      case :global.whereis_name({__MODULE__, term_key}) do
        pid when is_pid(pid) -> GenServer.stop(pid)
        :undefined -> :ok
      end

      OperationalGate.clear_authority_established(term_key)
      :persistent_term.erase(term_key)
    end)

    fence = fn -> OperationalGate.output_permitted?(term_key) end

    refute OperationalGate.open?(term_key)
    refute OperationalGate.operational?(@credential_epoch, @storage_epoch, term_key)
    refute OperationalGate.authority_established?(term_key)
    assert OperationalGate.status(gate_name) == :closed
    assert OperationalGate.output_permitted?(term_key)
    assert OutputFence.permitted?(fence)

    # ------------------------------------------------------------------
    # 4. Secure-transport handshake over the conceptual server, with the
    #    enrolled provisioner and the isolated fence wired into the client.
    # ------------------------------------------------------------------
    topic = "device:" <> device_identity.fingerprint

    client =
      start_supervised!(
        {ChannelClient,
         name: nil,
         auto_connect?: true,
         test_mode?: true,
         url: "wss://test.local/device_socket/websocket",
         session_holder: holder,
         boot_provisioner: {BootProvisioner, provisioner},
         firmware_validator: fn -> :ok end,
         output_fence: fence,
         desired_state_manager: manager_name,
         desired_state_manager_module: Manager,
         desired_state_identity: fn -> {:ok, desired_state_identity()} end,
         desired_state_compatibility: fn ->
           Map.put(compatibility(), :firmware_git_sha, "0123abc")
         end,
         desired_state_status: fn -> Manager.status(manager_name) end,
         checkpoint_pending: fn _outbox, _opts -> [] end,
         delivery_pending: fn _outbox, opts ->
           send(test_pid, {:delivery_pending, opts})
           []
         end,
         keystore_opts: [base_path: ctx.identity_base]}
      )

    connect_and_assert_join(client, ^topic, %{}, :ok)
    server_session = complete_handshake(client, topic, device_identity, ctx)
    assert_push(^topic, "wifi_status", _wifi_status)
    assert eventually(fn -> SessionHolder.live?(holder) end)

    # Production wiring marks the enrolled provisioner authenticated.
    assert eventually(fn -> BootProvisioner.current_state(provisioner).phase == :authenticated end)

    # BEFORE any activation the closed gate does not silence the device: the
    # client's real estimator publication flows through the injected fence.
    pre_activation_values = [%{id: "cv-pre", value: 1.5}]
    assert :ok = ChannelClient.send_computed_values_data(client, pre_activation_values)
    assert_push(^topic, "computed_values_data", pre_activation_payload, _pre_ref, 2_000)
    assert pre_activation_payload.values == pre_activation_values

    # ------------------------------------------------------------------
    # 5. Desired-state runtime comes up on the enrolled, authenticated
    #    incarnation. A blank store keeps the gate closed, records NO
    #    authority, and leaves the carve-out in force.
    # ------------------------------------------------------------------
    manager =
      start_supervised!(
        {Manager,
         name: manager_name,
         store: store,
         gate: gate_name,
         controller_capability: controller_capability,
         session_holder: holder,
         identity: desired_state_identity(),
         identity_refresh_ms: 1_000,
         lease_heartbeat_ms: 1_000,
         lease_timeout_ms: 5_000,
         owner_retry_base_ms: 25,
         owner_retry_max_ms: 5_000,
         owner_resolution_timeout_ms: 100,
         compatibility: compatibility(),
         applier: applier(term_key, store),
         ack_sink: ack_sink(term_key, store)},
        restart: :temporary
      )

    blank_status = Manager.status(manager)
    assert blank_status.active == nil
    assert blank_status.gate == :closed
    refute_received {:applier, _operation, _snapshot}

    refute OperationalGate.authority_established?(term_key)
    assert OperationalGate.output_permitted?(term_key)
    assert OutputFence.permitted?(fence)

    # ------------------------------------------------------------------
    # 6. control_v1 negotiation: the server's control_accept is verified and
    #    answered with a readiness bound to the enrolled identity, reporting
    #    no effective generation (read from the real Manager).
    # ------------------------------------------------------------------
    assert {:ok, server_control} = Control.new(:server, server_session)
    {server_control, _accept_frame} = push_control_accept(client, topic, server_control, enrolled_device_id)

    assert_push(^topic, "control_v1", readiness_carrier, _readiness_ref, 2_000)
    assert {:ok, readiness_frame} = Control.decode_carrier(readiness_carrier)
    assert {:ok, :readiness, readiness_bytes, server_control} = Control.open(server_control, readiness_frame)
    assert {:ok, readiness} = Messages.decode(:readiness, readiness_bytes)

    assert readiness.device_id == enrolled_device_id
    assert readiness.credential_epoch == @credential_epoch
    assert readiness.boot_id == @boot_id
    assert readiness.storage_epoch == @storage_epoch
    assert readiness.selected_control_version == 1
    assert readiness.selected_desired_version == 1
    assert readiness.effective == nil
    assert_receive {:delivery_pending, _pending_opts}, 2_000

    # ------------------------------------------------------------------
    # 7. A whole generation is delivered over the authenticated control
    #    carrier and activates through the real Manager.
    # ------------------------------------------------------------------
    fixture =
      DS.generation_fixture(
        device_id: enrolled_device_id,
        credential_epoch: @credential_epoch,
        boot_id: @boot_id,
        storage_epoch: @storage_epoch,
        generation: @generation
      )

    deliveries = [{:manifest_delivery, fixture.delivery} | Enum.map(DS.chunks(fixture), &{:section_chunk, &1})]

    _server_control =
      Enum.reduce(deliveries, server_control, fn {type, delivery}, control ->
        {:ok, bytes} = Messages.encode(type, delivery)
        {:ok, frame, next_control} = Control.seal(control, type, bytes)
        push(client, topic, "control_v1", Control.encode_carrier(frame))
        next_control
      end)

    # The staged ACK precedes activation: authority is still unrecorded, so
    # the legacy carve-out keeps output permitted even with the gate closed.
    staged = staged_ack(fixture)
    assert_receive {:ack, ^staged, staged_meta}, 2_000
    refute staged_meta.gate_open?
    refute staged_meta.authority_established?
    assert staged_meta.output_permitted?

    # Activation records output authority FIRST: from here on, permission
    # tracks the gate, which is closed throughout the apply.
    assert_receive {:applier, :validate, validate}, 2_000
    assert validate.pointer == pointer(fixture)
    assert validate.sections == Enum.sort(Contract.sections())
    refute validate.gate_open?
    assert validate.authority_established?
    refute validate.output_permitted?
    assert validate.active == nil

    assert_receive {:applier, :apply_non_network, non_network}, 2_000
    refute non_network.gate_open?
    refute non_network.output_permitted?
    assert non_network.active == nil

    assert_receive {:applier, :apply_wifi, wifi}, 2_000
    refute wifi.gate_open?
    refute wifi.output_permitted?
    assert wifi.active == pointer(fixture)

    effective = effective_ack(fixture)
    assert_receive {:ack, ^effective, effective_meta}, 2_000
    assert effective_meta.active == pointer(fixture)
    assert effective_meta.authority_established?

    # ------------------------------------------------------------------
    # 8. Operational: the gate is open for the exact activated binding and
    #    external output is permitted — now BECAUSE the gate is open.
    # ------------------------------------------------------------------
    # Synchronization barrier: the delivery call that activated the
    # generation has fully completed once this status call returns.
    operational_status = Manager.status(manager)
    assert operational_status.active == pointer(fixture)

    assert OperationalGate.status(gate_name) == {:open, gate_binding(fixture)}
    assert OperationalGate.open?(term_key)
    assert OperationalGate.operational?(@credential_epoch, @storage_epoch, term_key)
    assert OperationalGate.authority_established?(term_key)
    assert OperationalGate.output_permitted?(term_key)
    assert OutputFence.permitted?(fence)

    assert Store.active(store) == {:ok, pointer(fixture)}
    assert Store.activation_journal(store) == :empty
    assert {:ok, [^staged, ^effective]} = Store.pending_acks(store)

    assert {:ok, %BootstrapState{phase: :hydrating}} = BootProvisioner.hydrating(provisioner)
    assert {:ok, %BootstrapState{phase: :effective}} = BootProvisioner.effective(provisioner)

    operational_values = [%{id: "cv-live", value: 2.5}]
    assert :ok = ChannelClient.send_computed_values_data(client, operational_values)
    assert_push(^topic, "computed_values_data", operational_payload, _live_ref, 2_000)
    assert operational_payload.values == operational_values

    # ------------------------------------------------------------------
    # 9. AFTER activation the carve-out is gone for good: losing the lease
    #    (the desired-state controller dies) fails every read closed and
    #    fences real output — the recorded authority outlives the lease.
    # ------------------------------------------------------------------
    :ok = stop_supervised!(Manager)

    refute OperationalGate.open?(term_key)
    refute OperationalGate.operational?(@credential_epoch, @storage_epoch, term_key)
    assert OperationalGate.status(gate_name) == :closed
    assert OperationalGate.authority_established?(term_key)
    refute OperationalGate.output_permitted?(term_key)
    refute OutputFence.permitted?(fence)

    fenced_values = [%{id: "cv-fenced", value: 3.5}]
    assert :ok = ChannelClient.send_computed_values_data(client, fenced_values)
    refute_push(^topic, "computed_values_data", _fenced_payload, 100)
    assert Process.alive?(client)
  end

  # --- helpers ---

  defp restore_env(key, nil), do: Application.delete_env(:racing_org_tracker_pro, key)
  defp restore_env(key, prev), do: Application.put_env(:racing_org_tracker_pro, key, prev)

  # connectable?/1 requires a device target; scope the global :target override
  # to exactly this read so the rest of the chain runs with the test default.
  defp connectable_on_device?(channel_opts) do
    prev_target = Application.get_env(:racing_org_tracker_pro, :target)
    Application.put_env(:racing_org_tracker_pro, :target, :racing_org_rpi3)

    try do
      ChannelClient.connectable?(channel_opts)
    after
      restore_env(:target, prev_target)
    end
  end

  defp complete_handshake(client, topic, device_identity, ctx) do
    {:ok, hello_wire, responder_state} =
      Handshake.responder_hello(
        server_identity_private: ctx.srv_priv,
        server_identity_public: ctx.srv_pub,
        device_identity_public: device_identity.public_key,
        epoch: @credential_epoch
      )

    push(client, topic, "handshake_hello", %{"hello" => Base.encode64(hello_wire)})
    assert_push(^topic, "handshake_init", %{"init" => init_b64}, _init_ref, 2_000)
    {:ok, init_wire} = Base.decode64(init_b64)
    {:ok, server_session} = Handshake.responder_finalize(responder_state, init_wire)

    push(client, topic, "handshake_ok", %{"session_id" => Base.encode64(server_session.session_id)})
    server_session
  end

  defp push_control_accept(client, topic, server_control, device_id) do
    offer = %{control_versions: [1], desired_state_versions: [1]}
    {:ok, selection} = Negotiation.select(offer)

    attrs = %{
      device_id: device_id,
      credential_epoch: @credential_epoch,
      selected_control_version: selection.selected_control_version,
      selected_desired_version: selection.selected_desired_version,
      offer_hash: selection.offer_hash
    }

    {:ok, bytes} = Messages.encode(:control_accept, attrs)
    {:ok, frame, server_control} = Control.seal(server_control, :control_accept, bytes)
    push(client, topic, "control_v1", Control.encode_carrier(frame))
    {server_control, frame}
  end

  # The authoritative LOGICAL desired-state identity for this incarnation: the
  # enrolled logical device UUID at the verified registration epoch.
  defp desired_state_identity do
    %{
      device_id: RecoverySupport.device_id(),
      credential_epoch: @credential_epoch,
      boot_id: @boot_id,
      storage_epoch: @storage_epoch
    }
  end

  defp compatibility do
    %{
      firmware_version: "0.7.0",
      capabilities: Enum.map(Contract.capabilities(), fn {name, _id, version} -> {name, version} end)
    }
  end

  defp applier(term_key, store) do
    test_pid = self()

    %{
      validate: fn pointer, sections, secret, _owner_pid_map ->
        send(test_pid, {:applier, :validate, output_snapshot(term_key, store, pointer, sections, secret)})
        :ok
      end,
      apply_non_network: fn pointer, sections, _owner_pid_map ->
        send(test_pid, {:applier, :apply_non_network, output_snapshot(term_key, store, pointer, sections, nil)})
        :ok
      end,
      apply_wifi: fn pointer, secret, _owner_pid_map ->
        send(test_pid, {:applier, :apply_wifi, output_snapshot(term_key, store, pointer, [:wifi], secret)})
        :ok
      end,
      reset: fn _owner_pid_map ->
        send(test_pid, {:applier, :reset, output_snapshot(term_key, store, nil, nil, nil)})
        :ok
      end,
      reconcile: fn pointer, _owner_pid_map ->
        send(test_pid, {:applier, :reconcile, output_snapshot(term_key, store, pointer, nil, nil)})
        :ok
      end,
      owners: fn -> Map.new(Contract.sections(), &{&1, test_pid}) end
    }
  end

  defp ack_sink(term_key, store) do
    test_pid = self()

    fn ack ->
      send(test_pid, {:ack, ack, output_snapshot(term_key, store, nil, nil, nil)})
      :ok
    end
  end

  defp output_snapshot(term_key, store, pointer, sections, secret) do
    %{
      pointer: pointer,
      sections: sections && Enum.sort(sections),
      secret: inspect(secret),
      gate_open?: OperationalGate.open?(term_key),
      authority_established?: OperationalGate.authority_established?(term_key),
      output_permitted?: OperationalGate.output_permitted?(term_key),
      active: active_pointer(store)
    }
  end

  defp active_pointer(store) do
    case Store.active(store) do
      {:ok, pointer} -> pointer
      :empty -> nil
      {:error, reason} -> {:error, reason}
    end
  end

  defp pointer(fixture) do
    %{
      device_id: fixture.binding.device_id,
      storage_epoch: @storage_epoch,
      credential_epoch: fixture.binding.credential_epoch,
      generation: fixture.binding.generation,
      manifest_hash: fixture.manifest_hash
    }
  end

  defp gate_binding(fixture) do
    %{
      credential_epoch: fixture.binding.credential_epoch,
      storage_epoch: @storage_epoch,
      generation: fixture.binding.generation,
      manifest_hash: fixture.manifest_hash
    }
  end

  defp staged_ack(fixture) do
    summaries =
      Enum.map(fixture.sections, fn section ->
        %{
          section: section.name,
          section_schema_version: section.schema_version,
          tombstone: section.tombstone,
          section_hash: section.hash
        }
      end)

    Map.merge(desired_state_identity(), %{
      generation: fixture.binding.generation,
      manifest_hash: fixture.manifest_hash,
      status: :staged,
      sections: summaries
    })
  end

  defp effective_ack(fixture) do
    Map.merge(desired_state_identity(), %{
      generation: fixture.binding.generation,
      manifest_hash: fixture.manifest_hash,
      status: :effective
    })
  end

  defp eventually(fun, retries \\ 50) do
    cond do
      fun.() ->
        true

      retries <= 0 ->
        false

      true ->
        Process.sleep(10)
        eventually(fun, retries - 1)
    end
  end
end
