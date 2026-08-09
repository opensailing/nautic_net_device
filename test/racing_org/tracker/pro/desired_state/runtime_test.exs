defmodule RacingOrg.Tracker.Pro.DesiredState.RuntimeTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.DesiredState.{Applier, Manager, OperationalGate, Runtime, RuntimeIdentity}
  alias RacingOrg.Tracker.Pro.DesiredState.OperationalGate.AuthorityRequest
  alias RacingOrg.Tracker.Pro.SecureTransport.BootstrapState
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1, as: Contract

  defmodule ResetApplier do
    use GenServer

    def start_link(test_pid), do: GenServer.start_link(__MODULE__, test_pid)

    @impl true
    def init(test_pid), do: {:ok, test_pid}

    @impl true
    def handle_call(
          {:authority_request, manager_pid, request_token, {:reset_to_compile_default, owner_pid_map} = operation},
          _from,
          test_pid
        ) do
      if AuthorityRequest.valid?(request_token, manager_pid, operation) do
        send(test_pid, {:reset_to_compile_default, owner_pid_map})
        {:reply, :ok, test_pid}
      else
        {:reply, {:error, :invalid_applier_manager}, test_pid}
      end
    end
  end

  test "derives logical identity only from verified bootstrap authority and runtime incarnation" do
    device_id = <<0x44::128>>
    boot_id = <<0x45::128>>
    storage_epoch = <<0x46::128>>

    bootstrap_state = %BootstrapState{
      authority: %{logical_device_id: device_id, credential_epoch: 4},
      verified_credential_epoch: 5
    }

    assert {:ok,
            %{
              device_id: ^device_id,
              credential_epoch: 5,
              boot_id: ^boot_id,
              storage_epoch: ^storage_epoch
            }} =
             Runtime.identity_from(bootstrap_state, %{
               boot_id: boot_id,
               storage_epoch: storage_epoch
             })
  end

  test "refuses to invent a logical identity before signed authority exists" do
    assert {:error, :no_verified_authority} =
             Runtime.identity_from(%BootstrapState{}, %{
               boot_id: <<0x45::128>>,
               storage_epoch: <<0x46::128>>
             })
  end

  test "advertises the application version and every implemented desired-state capability" do
    assert %{
             firmware_version: "0.7.0",
             capabilities: capabilities
           } = Runtime.compatibility(firmware_version: "0.7.0")

    assert capabilities == Enum.map(Contract.capabilities(), fn {name, _id, version} -> {name, version} end)
  end

  test "runtime child specs retain the authoritative process IDs" do
    assert Supervisor.child_spec(Runtime.applier_child_spec(), []).id == Applier
    assert Supervisor.child_spec(Runtime.manager_child_spec(), []).id == Manager
  end

  test "production manager callbacks expose compile-default owner reset" do
    applier = start_supervised!({ResetApplier, self()})
    owner_pid_map = Map.new(Contract.sections(), &{&1, self()})

    assert :ok = Runtime.applier_callbacks(applier, make_ref()).reset.(owner_pid_map)
    assert_receive {:reset_to_compile_default, ^owner_pid_map}
  end

  test "forwards operational lease timing overrides to the Manager" do
    base = Path.join(System.tmp_dir!(), "desired_runtime_#{System.unique_integer([:positive])}")
    boot_term_key = {__MODULE__, make_ref()}
    gate_term_key = {__MODULE__, make_ref()}

    on_exit(fn ->
      :persistent_term.erase(boot_term_key)
      :persistent_term.erase(gate_term_key)
      File.rm_rf(base)
    end)

    runtime_identity =
      start_supervised!(
        {RuntimeIdentity, name: nil, base_dir: base, boot_term_key: boot_term_key, entropy: fn 16 -> <<0x51::128>> end}
      )

    manager_name = {:global, {__MODULE__, make_ref()}}
    controller_capability = make_ref()

    gate =
      start_supervised!(
        {OperationalGate,
         name: nil, term_key: gate_term_key, controller: manager_name, controller_capability: controller_capability}
      )

    manager =
      start_supervised!(
        Runtime.manager_child_spec(
          name: manager_name,
          base_dir: base,
          runtime_identity: runtime_identity,
          gate: gate,
          controller_capability: controller_capability,
          session_holder: self(),
          identity: fn -> {:error, :authority_unavailable} end,
          identity_refresh_ms: 10_000,
          lease_heartbeat_ms: 17,
          lease_timeout_ms: 43,
          applier_callbacks: %{owners: fn -> %{} end}
        )
      )

    state = :sys.get_state(manager)
    assert state.lease_heartbeat_ms == 17
    assert state.lease_timeout_ms == 43
  end
end
