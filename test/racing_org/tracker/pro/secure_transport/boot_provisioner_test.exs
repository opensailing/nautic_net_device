defmodule RacingOrg.Tracker.Pro.SecureTransport.BootProvisionerTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.SecureTransport.BootProvisioner
  alias RacingOrg.Tracker.Pro.SecureTransport.BootstrapState
  alias RacingOrg.Tracker.Pro.SecureTransport.BootstrapStateStore
  alias RacingOrg.Tracker.Pro.SecureTransport.KeyStore

  @seed :binary.copy(<<0xB1>>, 32)

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

  test "the supervised state machine stays alive once identity authority is ready" do
    reconcile_fun = fn _opts -> {:ready, %BootstrapState{phase: :registered}} end
    {:ok, pid} = BootProvisioner.start_link(name: nil, reconcile_fun: reconcile_fun)

    assert Process.alive?(pid)
    assert %BootstrapState{phase: :registered} = BootProvisioner.current_state(pid)
    refute_receive {:scheduled, _delay}, 50
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
end
