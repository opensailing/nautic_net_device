defmodule RacingOrg.Tracker.Pro.SecureTransport.BootProvisionerTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.RecoveryV2TestSupport, as: RecoverySupport
  alias RacingOrg.Tracker.Pro.SecureTransport.BootProvisioner
  alias RacingOrg.Tracker.Pro.SecureTransport.BootstrapState
  alias RacingOrg.Tracker.Pro.SecureTransport.BootstrapStateStore
  alias RacingOrg.Tracker.Pro.SecureTransport.IdentityProvider
  alias RacingOrg.Tracker.Pro.SecureTransport.KeyStore
  alias RacingOrg.Tracker.Pro.SecureTransport.Primitives
  alias RacingOrg.Tracker.Pro.SecureTransport.Session
  alias RacingOrg.Tracker.Pro.SecureTransport.SessionHolder

  @seed :binary.copy(<<0xB1>>, 32)
  @serial "000000001234abcd"

  setup do
    base = Path.join(System.tmp_dir!(), "boot_provisioner_#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf(base) end)
    %{base: base}
  end

  test "a legacy marker is never authority by existence alone", %{base: base} do
    marker_path = Path.join(base, "register_marker.json")
    File.write!(marker_path, Jason.encode!(%{"device_id" => "legacy", "fingerprint" => String.duplicate("0", 64)}))

    refute BootProvisioner.registered?(base_path: base)
    assert {:error, :not_provisioned} = KeyStore.load(base_path: base)
  end

  test "only a matching legacy marker and valid active key remains temporarily connectable for authenticated migration",
       %{
         base: base
       } do
    {:ok, identity} = KeyStore.load_or_generate(base_path: base, seed_generator: fn -> @seed end)
    marker_path = Path.join(base, "register_marker.json")

    File.write!(
      marker_path,
      Jason.encode!(%{
        "device_id" => "11111111-2222-3333-4444-555555555555",
        "fingerprint" => identity.fingerprint,
        "status" => "assigned"
      })
    )

    assert BootProvisioner.registered?(base_path: base)

    File.write!(
      marker_path,
      Jason.encode!(%{
        "device_id" => "11111111-2222-3333-4444-555555555555",
        "fingerprint" => String.duplicate("f", 64),
        "status" => "assigned"
      })
    )

    refute BootProvisioner.registered?(base_path: base)
  end

  test "provision preserves the legacy public error shape when trust is not configured", %{base: base} do
    assert {:error, :not_configured} =
             BootProvisioner.provision(
               server_public_key: nil,
               keystore_opts: [base_path: base],
               state_store_opts: [base_path: base],
               hardware_identity_fun: fn -> {:ok, "000000001234abcd"} end
             )
  end

  test "the supervised coordinator still accepts the legacy provision_fun injection" do
    parent = self()

    provision_fun = fn _opts ->
      send(parent, :provision_called)
      {:ok, :already_registered}
    end

    {:ok, pid} = BootProvisioner.start_link(name: nil, provision_fun: provision_fun)

    assert_receive :provision_called
    assert Process.alive?(pid)
    assert %BootstrapState{} = BootProvisioner.current_state(pid)
  end

  test "startup clears stale persisted authenticated readiness before reconciliation", %{base: base} do
    authority = %{
      kind: :registration,
      public_key: :binary.copy(<<0xA1>>, 32),
      client_nonce: :binary.copy(<<0xA2>>, 32),
      receipt: "signed-receipt",
      logical_device_id: :binary.copy(<<0xA3>>, 16),
      credential_epoch: 0
    }

    BootstrapStateStore.save!(
      %BootstrapState{phase: :authenticated, authority: authority},
      base_path: base
    )

    reconcile_fun = fn _opts ->
      {:ok, state} = BootstrapStateStore.load(base_path: base)
      {:ready, state}
    end

    {:ok, pid} =
      BootProvisioner.start_link(
        name: nil,
        state_store_opts: [base_path: base],
        reconcile_fun: reconcile_fun
      )

    assert %BootstrapState{phase: :registered} = BootProvisioner.current_state(pid)
    assert {:ok, %BootstrapState{phase: :registered}} = BootstrapStateStore.load(base_path: base)
  end

  test "status/1 reports the sanitized provisioning projection, never authority material" do
    authority = %{
      kind: :registration,
      public_key: :binary.copy(<<0xA1>>, 32),
      client_nonce: :binary.copy(<<0xA2>>, 32),
      receipt: "signed-receipt-secret",
      logical_device_id: :binary.copy(<<0xA3>>, 16),
      credential_epoch: 5
    }

    reconcile_fun = fn _opts ->
      {:ready,
       %BootstrapState{
         phase: :registered,
         authority: authority,
         verified_credential_epoch: 5,
         retry_count: 1
       }}
    end

    {:ok, pid} = BootProvisioner.start_link(name: nil, reconcile_fun: reconcile_fun)

    status = BootProvisioner.status(pid)

    assert status.phase == :registered
    assert status.credential_epoch == 5
    assert status.retry_count == 1
    refute inspect(status, limit: :infinity) =~ "signed-receipt-secret"
  end

  test "the supervised state machine stays alive once identity authority is ready" do
    reconcile_fun = fn _opts -> {:ready, %BootstrapState{phase: :registered}} end
    {:ok, pid} = BootProvisioner.start_link(name: nil, reconcile_fun: reconcile_fun)

    assert Process.alive?(pid)
    assert %BootstrapState{phase: :registered} = BootProvisioner.current_state(pid)
    refute_receive {:scheduled, _delay}, 50
  end

  test "credential_epoch exposes epoch zero from verified registration authority", %{base: base} do
    {:ok, identity} = KeyStore.load_or_generate(base_path: base, seed_generator: fn -> @seed end)
    {:ok, registration} = RecoverySupport.registration_result(identity, @serial)
    state = %BootstrapState{phase: :registered, authority: registration_authority(registration)}
    BootstrapStateStore.save!(state, base_path: base)

    pid = start_authority_provisioner(base)

    assert {:ok, 0} = BootProvisioner.credential_epoch(pid)
  end

  test "credential_epoch exposes a positive epoch from verified recovery authority", %{base: base} do
    {:ok, identity} = KeyStore.load_or_generate(base_path: base, seed_generator: fn -> @seed end)
    {:ok, challenge} = RecoverySupport.challenge_result(identity, @serial)
    {:ok, lifecycle} = RecoverySupport.lifecycle_result(identity, challenge.receipt, credential_epoch: 4)

    state = %BootstrapState{
      phase: :committed,
      authority: recovery_authority(identity, challenge, lifecycle)
    }

    BootstrapStateStore.save!(state, base_path: base)
    pid = start_authority_provisioner(base)

    assert {:ok, 4} = BootProvisioner.credential_epoch(pid)
  end

  test "credential_epoch fails closed when no verified authority exists" do
    reconcile_fun = fn _opts -> {:ready, %BootstrapState{phase: :uninitialized}} end
    {:ok, pid} = BootProvisioner.start_link(name: nil, reconcile_fun: reconcile_fun)

    assert {:error, :no_verified_authority} = BootProvisioner.credential_epoch(pid)
  end

  test "adopt_credential_epoch persists a monotonic signed-HELLO high-water mark", %{base: base} do
    {:ok, identity} = KeyStore.load_or_generate(base_path: base, seed_generator: fn -> @seed end)
    {:ok, registration} = RecoverySupport.registration_result(identity, @serial)
    state = %BootstrapState{phase: :registered, authority: registration_authority(registration)}
    BootstrapStateStore.save!(state, base_path: base)

    pid = start_authority_provisioner(base)

    assert {:ok, %BootstrapState{} = adopted} = BootProvisioner.adopt_credential_epoch(4, pid)
    assert Map.get(adopted, :verified_credential_epoch) == 4
    assert {:ok, 4} = BootProvisioner.credential_epoch(pid)
    assert {:ok, persisted} = BootstrapStateStore.load(base_path: base)
    assert Map.get(persisted, :verified_credential_epoch) == 4

    assert {:error, :epoch_downgrade} = BootProvisioner.adopt_credential_epoch(3, pid)
    assert {:ok, 4} = BootProvisioner.credential_epoch(pid)
  end

  test "advancing the durable credential epoch evicts a lower-epoch live session", %{base: base} do
    {:ok, identity} = KeyStore.load_or_generate(base_path: base, seed_generator: fn -> @seed end)
    {:ok, registration} = RecoverySupport.registration_result(identity, @serial)
    state = %BootstrapState{phase: :registered, authority: registration_authority(registration)}
    BootstrapStateStore.save!(state, base_path: base)

    holder = start_supervised!({SessionHolder, name: nil})

    old_session =
      Session.new(
        role: :initiator,
        session_id: :crypto.strong_rand_bytes(16),
        epoch: 0,
        credential_epoch: 0,
        identity_fingerprint: Base.decode16!(IdentityProvider.fingerprint(identity), case: :mixed),
        out_key: :crypto.strong_rand_bytes(32),
        in_key: :crypto.strong_rand_bytes(32)
      )

    assert {:ok, published} = SessionHolder.publish(holder, old_session)
    pid = start_authority_provisioner(base, session_holder: holder)

    assert {:ok, %BootstrapState{verified_credential_epoch: 4}} =
             BootProvisioner.adopt_credential_epoch(4, pid)

    assert {:error, :no_session} = SessionHolder.get_current_session(holder)
    assert SessionHolder.generation(holder) == published.generation + 1

    assert {:error, :stale_session} =
             SessionHolder.take_send_counter(holder, published.generation)
  end

  test "advancing the durable credential epoch clears authenticated readiness", %{base: base} do
    {:ok, identity} = KeyStore.load_or_generate(base_path: base, seed_generator: fn -> @seed end)
    {:ok, registration} = RecoverySupport.registration_result(identity, @serial)
    state = %BootstrapState{phase: :registered, authority: registration_authority(registration)}
    BootstrapStateStore.save!(state, base_path: base)

    holder = start_supervised!({SessionHolder, name: nil})

    session =
      Session.new(
        role: :initiator,
        session_id: :crypto.strong_rand_bytes(16),
        epoch: 0,
        credential_epoch: 0,
        identity_fingerprint: Base.decode16!(IdentityProvider.fingerprint(identity), case: :mixed),
        out_key: :crypto.strong_rand_bytes(32),
        in_key: :crypto.strong_rand_bytes(32)
      )

    assert {:ok, _published} = SessionHolder.publish(holder, session)
    pid = start_authority_provisioner(base, session_holder: holder)

    assert {:ok, %BootstrapState{phase: :authenticated}} = BootProvisioner.authenticated(pid)
    assert {:ok, %BootstrapState{phase: :hydrating}} = BootProvisioner.hydrating(pid)
    assert {:ok, %BootstrapState{phase: :effective}} = BootProvisioner.effective(pid)

    assert {:ok, %BootstrapState{phase: :registered, verified_credential_epoch: 4}} =
             BootProvisioner.adopt_credential_epoch(4, pid)

    assert %BootstrapState{phase: :registered, verified_credential_epoch: 4} =
             BootProvisioner.current_state(pid)

    assert {:ok, %BootstrapState{phase: :registered, verified_credential_epoch: 4}} =
             BootstrapStateStore.load(base_path: base)
  end

  test "a reconciled recovery epoch evicts a lower-epoch live session before readiness", %{base: base} do
    {:ok, identity} = KeyStore.load_or_generate(base_path: base, seed_generator: fn -> @seed end)
    {:ok, registration} = RecoverySupport.registration_result(identity, @serial)
    state = %BootstrapState{phase: :registered, authority: registration_authority(registration)}
    BootstrapStateStore.save!(state, base_path: base)

    holder = start_supervised!({SessionHolder, name: nil})

    old_session =
      Session.new(
        role: :initiator,
        session_id: :crypto.strong_rand_bytes(16),
        epoch: 0,
        credential_epoch: 0,
        identity_fingerprint: Base.decode16!(IdentityProvider.fingerprint(identity), case: :mixed),
        out_key: :crypto.strong_rand_bytes(32),
        in_key: :crypto.strong_rand_bytes(32)
      )

    assert {:ok, published} = SessionHolder.publish(holder, old_session)
    reconciled = %{state | verified_credential_epoch: 4}

    pid =
      start_authority_provisioner(base,
        session_holder: holder,
        reconcile_fun: fn _opts -> {:ready, reconciled} end
      )

    assert %BootstrapState{verified_credential_epoch: 4} = BootProvisioner.current_state(pid)
    assert {:error, :no_session} = SessionHolder.get_current_session(holder)
    assert SessionHolder.generation(holder) == published.generation + 1
  end

  test "startup reconciles a surviving lower-epoch session against the durable epoch", %{base: base} do
    {:ok, identity} = KeyStore.load_or_generate(base_path: base, seed_generator: fn -> @seed end)
    {:ok, registration} = RecoverySupport.registration_result(identity, @serial)

    durable_state = %BootstrapState{
      phase: :registered,
      authority: registration_authority(registration),
      verified_credential_epoch: 4
    }

    BootstrapStateStore.save!(durable_state, base_path: base)
    holder = start_supervised!({SessionHolder, name: nil})

    stale_session =
      Session.new(
        role: :initiator,
        session_id: :crypto.strong_rand_bytes(16),
        epoch: 3,
        credential_epoch: 3,
        identity_fingerprint: Base.decode16!(IdentityProvider.fingerprint(identity), case: :mixed),
        out_key: :crypto.strong_rand_bytes(32),
        in_key: :crypto.strong_rand_bytes(32)
      )

    assert {:ok, published} = SessionHolder.publish(holder, stale_session)
    pid = start_authority_provisioner(base, session_holder: holder)

    assert %BootstrapState{verified_credential_epoch: 4} = BootProvisioner.current_state(pid)
    assert {:error, :no_session} = SessionHolder.get_current_session(holder)
    assert SessionHolder.generation(holder) == published.generation + 1
  end

  test "a deferred recovery outcome still fences a newly durable credential epoch", %{base: base} do
    {:ok, identity} = KeyStore.load_or_generate(base_path: base, seed_generator: fn -> @seed end)
    {:ok, registration} = RecoverySupport.registration_result(identity, @serial)

    durable_state = %BootstrapState{
      phase: :registered,
      authority: registration_authority(registration),
      verified_credential_epoch: 4
    }

    BootstrapStateStore.save!(durable_state, base_path: base)
    holder = start_supervised!({SessionHolder, name: nil})

    stale_session =
      Session.new(
        role: :initiator,
        session_id: :crypto.strong_rand_bytes(16),
        epoch: 3,
        credential_epoch: 3,
        identity_fingerprint: Base.decode16!(IdentityProvider.fingerprint(identity), case: :mixed),
        out_key: :crypto.strong_rand_bytes(32),
        in_key: :crypto.strong_rand_bytes(32)
      )

    assert {:ok, published} = SessionHolder.publish(holder, stale_session)

    pid =
      start_authority_provisioner(base,
        session_holder: holder,
        reconcile_fun: fn _opts -> {:retry, durable_state, :candidate_promotion_failed} end,
        scheduler: fn _delay -> :ok end
      )

    assert %BootstrapState{verified_credential_epoch: 4} = BootProvisioner.current_state(pid)
    assert {:error, :no_session} = SessionHolder.get_current_session(holder)
    assert SessionHolder.generation(holder) == published.generation + 1
  end

  test "blocked and transient outcomes retry with bounded backoff and no hot loop" do
    parent = self()

    reconcile_fun = fn _opts ->
      send(parent, :attempted)
      {:retry, %BootstrapState{phase: :blocked, blocked_reason: :attempt_limit}, :attempt_limit}
    end

    scheduler = fn delay -> send(parent, {:scheduled, delay}) end

    {:ok, pid} =
      BootProvisioner.start_link(
        name: nil,
        reconcile_fun: reconcile_fun,
        scheduler: scheduler,
        retry_ms: 10,
        max_retry_ms: 25,
        retry_jitter: 0
      )

    assert_receive :attempted
    assert_receive {:scheduled, 10}
    refute_receive :attempted, 50

    send(pid, :attempt)
    assert_receive :attempted
    assert_receive {:scheduled, 20}

    send(pid, :attempt)
    assert_receive :attempted
    assert_receive {:scheduled, 25}

    send(pid, :attempt)
    assert_receive :attempted
    assert_receive {:scheduled, 25}
    assert Process.alive?(pid)
  end

  test "an unconfigured trust anchor is terminal and does not retry" do
    parent = self()

    reconcile_fun = fn _opts ->
      send(parent, :attempted)
      {:stop, :not_configured}
    end

    {:ok, pid} =
      BootProvisioner.start_link(
        name: nil,
        reconcile_fun: reconcile_fun,
        scheduler: fn delay -> send(parent, {:scheduled, delay}) end
      )

    ref = Process.monitor(pid)
    assert_receive :attempted
    assert_receive {:DOWN, ^ref, :process, ^pid, reason}
    assert reason in [:normal, :noproc]
    refute_receive {:scheduled, _delay}, 50
  end

  test "child spec remains transient for abnormal recovery crashes" do
    spec = BootProvisioner.child_spec([])
    assert spec.id == BootProvisioner
    assert spec.restart == :transient
  end

  defp start_authority_provisioner(base, extra \\ []) do
    opts =
      Keyword.merge(
        [
          name: nil,
          keystore_opts: [base_path: base],
          state_store_opts: [base_path: base],
          hardware_identity_fun: fn -> {:ok, @serial} end,
          server_public_key: RecoverySupport.server_public_key()
        ],
        extra
      )

    {:ok, pid} = BootProvisioner.start_link(opts)
    pid
  end

  defp registration_authority(%{request: request, receipt: receipt}) do
    %{
      kind: :registration,
      public_key: request.candidate_public_key,
      client_nonce: request.client_nonce,
      receipt: receipt.envelope,
      logical_device_id: receipt.payload.logical_device_id,
      credential_epoch: receipt.payload.credential_epoch
    }
  end

  defp recovery_authority(identity, challenge, lifecycle) do
    %{
      kind: :recovery,
      public_key: IdentityProvider.public_key(identity),
      challenge_client_nonce: challenge.request.client_nonce,
      challenge_receipt: challenge.receipt.envelope,
      commit_signing_bytes_hash: Primitives.sha256(lifecycle.request.assertion),
      lifecycle_receipt: lifecycle.receipt.envelope,
      logical_device_id: lifecycle.receipt.payload.logical_device_id,
      credential_epoch: lifecycle.receipt.payload.credential_epoch
    }
  end
end
