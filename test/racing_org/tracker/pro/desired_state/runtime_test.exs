defmodule RacingOrg.Tracker.Pro.DesiredState.RuntimeTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro
  alias RacingOrg.Tracker.Pro.DesiredState.{Applier, Manager, OperationalGate, Runtime, RuntimeIdentity}
  alias RacingOrg.Tracker.Pro.DurableDelivery.Outbox.Owner
  alias RacingOrg.Tracker.Pro.DesiredState.OperationalGate.AuthorityRequest
  alias RacingOrg.Tracker.Pro.SecureTransport.BootstrapState
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1, as: Contract
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.Messages

  defmodule FakeAckProducer do
    def admit(ack, opts) do
      send(self(), {:admit_ack, ack, opts})

      case opts[:outbox] do
        %{result: result} -> result
        _outbox -> {:error, :invalid_outbox_response}
      end
    end
  end

  defmodule RaisingAckProducer do
    def admit(_ack, _opts), do: raise("simulated producer failure")
  end

  defmodule ThrowingAckProducer do
    def admit(_ack, _opts), do: throw(:simulated_producer_failure)
  end

  defmodule ExitingAckProducer do
    def admit(_ack, _opts), do: exit(:simulated_producer_failure)
  end

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

  test "advertises canonical firmware metadata and every desired-state capability" do
    git_sha = Pro.git_commit()
    assert is_binary(git_sha)
    assert byte_size(git_sha) in 7..40
    assert Regex.match?(~r/\A[0-9a-f]+\z/, git_sha)

    assert %{
             firmware_version: "0.7.0",
             firmware_git_sha: ^git_sha,
             capabilities: capabilities
           } = Runtime.compatibility(firmware_version: "0.7.0")

    assert capabilities == Enum.map(Contract.capabilities(), fn {name, _id, version} -> {name, version} end)

    assert {:ok, _bytes} =
             Messages.encode(:readiness, %{
               device_id: <<1::128>>,
               credential_epoch: 1,
               boot_id: <<2::128>>,
               storage_epoch: <<3::128>>,
               selected_control_version: 1,
               selected_desired_version: 1,
               offer_hash: :binary.copy(<<4>>, 32),
               firmware_version: "0.7.0",
               firmware_git_sha: git_sha,
               capabilities: capabilities,
               effective: nil
             })
  end

  test "production ACK sink accepts only after durable Outbox admission" do
    ack = %{status: :effective}

    receipt = %{
      stream: :desired_state_ack,
      device_id: <<1::128>>,
      credential_epoch: 7,
      storage_epoch: <<2::128>>,
      sequence: 11,
      payload_hash: <<3::256>>,
      cumulative_sequence: 0
    }

    outbox = %{test_pid: self(), result: {:ok, receipt}}
    sink = Runtime.ack_sink(outbox: outbox, producer: FakeAckProducer)

    assert :ok = sink.(ack)
    assert_receive {:admit_ack, ^ack, [outbox: ^outbox]}
  end

  test "production ACK sink fails closed with the exact durable admission error" do
    ack = %{status: :effective}

    for error <- [
          {:error, :duplicate_entry_id},
          {:error, :identity_unbound},
          {:error, {:backpressure, :entry_capacity}},
          {:error, {:durability_uncertain, {:file_sync, :eio}}}
        ] do
      outbox = %{test_pid: self(), result: error}
      sink = Runtime.ack_sink(outbox: outbox, producer: FakeAckProducer)

      assert ^error = sink.(ack)
      assert_receive {:admit_ack, ^ack, [outbox: ^outbox]}
    end
  end

  test "production ACK sink defaults to the supervised Outbox Owner" do
    ack = %{status: :effective}
    sink = Runtime.ack_sink(producer: FakeAckProducer)

    assert {:error, :invalid_outbox_response} = sink.(ack)
    assert_receive {:admit_ack, ^ack, [outbox: Owner]}
  end

  test "production ACK sink rejects invalid options and producer seams" do
    ack = %{status: :effective}

    assert {:error, :invalid_ack_sink_options} = Runtime.ack_sink(:not_options).(ack)
    assert {:error, :invalid_ack_sink_options} = Runtime.ack_sink([:not_a_keyword]).(ack)
    assert {:error, :invalid_ack_producer} = Runtime.ack_sink(producer: String).(ack)
  end

  test "production ACK sink traps producer failures" do
    ack = %{status: :effective}

    for producer <- [RaisingAckProducer, ThrowingAckProducer, ExitingAckProducer] do
      assert {:error, :ack_admission_failed} = Runtime.ack_sink(producer: producer).(ack)
    end
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
