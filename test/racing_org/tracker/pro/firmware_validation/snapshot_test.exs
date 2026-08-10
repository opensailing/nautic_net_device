defmodule RacingOrg.Tracker.Pro.FirmwareValidation.SnapshotTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.FirmwareValidation.HealthCriteria
  alias RacingOrg.Tracker.Pro.FirmwareValidation.Snapshot

  @git_sha String.duplicate("a", 40)

  test "builds the exact health-criteria snapshot from sanitized source projections" do
    secret = "session-secret-material"
    owner = self()

    snapshot =
      Snapshot.build(
        %{observed_at_ms: 1_250, soak_started_at_ms: 1_000},
        firmware_version_reader: fn -> "0.7.0" end,
        git_commit_reader: fn -> @git_sha end,
        session_reader: fn ->
          {:ok,
           %{
             credential_epoch: 7,
             out_key: secret,
             in_key: secret,
             session_id: "sensitive-session-id"
           }}
        end,
        manager_reader: fn ->
          %{
            active: active_pointer(12),
            gate: {:open, gate_binding(12)},
            identity: %{credential_epoch: 7, device_id: "private-device-id"},
            recovery_error: nil
          }
        end,
        applier_owners_reader: fn -> %{tracking: owner} end,
        owner_alive_reader: &Process.alive?/1,
        control_receipt_reader: fn -> :succeeded end,
        telemetry_receipt_reader: fn -> :succeeded end,
        outbox_reader: fn -> %{corrupt: false, critical_pressure: false, entries: [secret]} end
      )

    assert snapshot == %{
             firmware: %{version: "0.7.0", git_sha: @git_sha},
             session: %{authenticated: true, credential_epoch: 7},
             desired_state: %{generation: 12, effective: true, compatible: true},
             process_health: %{supervisor: :healthy, owner: :healthy},
             receipts: %{control: :succeeded, telemetry: :succeeded},
             outbox: %{corrupt: false, critical_pressure: false},
             timing: %{observed_at_ms: 1_250, soak_started_at_ms: 1_000}
           }

    assert :ready =
             HealthCriteria.evaluate(snapshot, %{
               firmware: %{version: "0.7.0", git_sha: @git_sha},
               credential_epoch: 7,
               desired_generation: 12,
               soak_period_ms: 250,
               deadline_at_ms: 2_000
             })

    rendered = inspect(snapshot)
    refute rendered =~ secret
    refute rendered =~ "sensitive-session-id"
    refute rendered =~ "private-device-id"
    refute rendered =~ inspect(owner)
  end

  test "receipt and outbox sources fail closed when no integration readers are installed" do
    snapshot =
      Snapshot.build(
        %{observed_at_ms: 10, soak_started_at_ms: 10},
        healthy_core_readers()
      )

    assert snapshot.receipts == %{control: :pending, telemetry: :pending}
    assert snapshot.outbox == %{corrupt: true, critical_pressure: true}
  end

  test "unavailable or malformed readers produce an exact unhealthy snapshot instead of raising" do
    snapshot =
      Snapshot.build(
        %{observed_at_ms: -50, soak_started_at_ms: 500},
        firmware_version_reader: fn -> raise "firmware reader failed" end,
        git_commit_reader: fn -> @git_sha end,
        session_reader: fn -> {:ok, %{credential_epoch: -1, out_key: "do-not-copy"}} end,
        manager_reader: fn -> exit(:manager_unavailable) end,
        applier_owners_reader: fn -> :invalid_owner_set end,
        control_receipt_reader: fn -> :unexpected end,
        telemetry_receipt_reader: fn -> raise "receipt reader failed" end,
        outbox_reader: fn -> %{corrupt: false, critical_pressure: :unknown} end
      )

    assert snapshot == %{
             firmware: %{version: "", git_sha: @git_sha},
             session: %{authenticated: false, credential_epoch: 0},
             desired_state: %{generation: 1, effective: false, compatible: false},
             process_health: %{supervisor: :unhealthy, owner: :unhealthy},
             receipts: %{control: :pending, telemetry: :pending},
             outbox: %{corrupt: true, critical_pressure: true},
             timing: %{observed_at_ms: 0, soak_started_at_ms: 0}
           }

    assert {:pending, unmet} =
             HealthCriteria.evaluate(snapshot, %{
               firmware: %{version: "0.7.0", git_sha: @git_sha},
               credential_epoch: 7,
               desired_generation: 12,
               soak_period_ms: 250,
               deadline_at_ms: 2_000
             })

    assert %{criterion: :input, diagnostic_code: :invalid_snapshot} in unmet
  end

  test "a live SessionHolder with no session is unhealthy authentication but not a crashed supervisor" do
    snapshot =
      Snapshot.build(
        %{observed_at_ms: 10, soak_started_at_ms: 10},
        firmware_version_reader: fn -> "0.7.0" end,
        git_commit_reader: fn -> @git_sha end,
        session_reader: fn -> {:error, :no_session} end,
        manager_reader: fn ->
          %{active: active_pointer(3), gate: :closed, identity: nil, recovery_error: nil}
        end,
        applier_owners_reader: fn -> %{tracking: self()} end,
        owner_alive_reader: fn _owner -> true end
      )

    assert snapshot.session == %{authenticated: false, credential_epoch: 0}
    assert snapshot.desired_state == %{generation: 3, effective: false, compatible: true}
    assert snapshot.process_health == %{supervisor: :healthy, owner: :healthy}
  end

  test "owner health requires a nonempty set of live configured owners" do
    base_opts = healthy_core_readers()

    empty =
      Snapshot.build(
        %{observed_at_ms: 10, soak_started_at_ms: 10},
        Keyword.put(base_opts, :applier_owners_reader, fn -> %{} end)
      )

    dead =
      Snapshot.build(
        %{observed_at_ms: 10, soak_started_at_ms: 10},
        base_opts
        |> Keyword.put(:applier_owners_reader, fn -> %{tracking: :dead_owner} end)
        |> Keyword.put(:owner_alive_reader, fn :dead_owner -> false end)
      )

    assert empty.process_health.owner == :unhealthy
    assert dead.process_health.owner == :unhealthy
  end

  defp healthy_core_readers do
    [
      firmware_version_reader: fn -> "0.7.0" end,
      git_commit_reader: fn -> @git_sha end,
      session_reader: fn -> {:ok, %{credential_epoch: 7}} end,
      manager_reader: fn ->
        %{
          active: active_pointer(12),
          gate: {:open, gate_binding(12)},
          identity: nil,
          recovery_error: nil
        }
      end,
      applier_owners_reader: fn -> %{tracking: self()} end,
      owner_alive_reader: fn _owner -> true end
    ]
  end

  defp active_pointer(generation) do
    Map.put(gate_binding(generation), :device_id, <<1::128>>)
  end

  defp gate_binding(generation) do
    %{
      credential_epoch: 7,
      storage_epoch: <<2::128>>,
      generation: generation,
      manifest_hash: <<3::256>>
    }
  end
end
