defmodule RacingOrg.Tracker.Pro.FirmwareValidation.TargetTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.FirmwareValidation.Target

  @git_sha String.duplicate("a", 40)
  @device_id <<1::128>>
  @boot_id <<2::128>>
  @storage_epoch <<3::128>>
  @manifest_hash <<4::256>>

  test "reads an exact trial target only from one matching durable runtime authority" do
    assert {:ok,
            %{
              firmware: %{version: "1.2.3", git_sha: @git_sha},
              credential_epoch: 7,
              desired_generation: 12,
              soak_period_ms: 5_000
            }} = Target.read(authority_options())
  end

  test "remains pending unless runtime identity, active pointer, and open manifest authority match exactly" do
    mismatched_gate =
      authority_options(
        gate_reader: fn ->
          {:open, %{gate_binding() | manifest_hash: <<9::256>>}}
        end
      )

    mismatched_identity =
      authority_options(
        manager_reader: fn ->
          %{manager_status() | identity: %{runtime_identity() | boot_id: <<8::128>>}}
        end
      )

    malformed_compatibility =
      authority_options(
        compatibility_reader: fn ->
          %{firmware_version: "1.2.3", firmware_git_sha: "short", capabilities: []}
        end
      )

    for opts <- [mismatched_gate, mismatched_identity, malformed_compatibility] do
      assert :pending = Target.read(opts)
    end
  end

  test "accepts a ready checkpoint hydration bound to the same exact active authority" do
    ready_hydration = %{
      state: :ready,
      binding: Map.put(gate_binding(), :device_id, @device_id),
      coordinator_available?: true
    }

    assert {:ok, %{desired_generation: 12}} =
             Target.read(
               authority_options(manager_reader: fn -> %{manager_status() | checkpoint_hydration: ready_hydration} end)
             )
  end

  test "source exceptions and non-authoritative manager states fail closed" do
    assert :pending =
             Target.read(authority_options(identity_reader: fn -> raise "authority unavailable" end))

    assert :pending =
             Target.read(authority_options(manager_reader: fn -> %{manager_status() | recovery_error: :corrupt} end))

    assert :pending =
             Target.read(authority_options(manager_reader: fn -> %{manager_status() | active: nil} end))

    assert :pending =
             Target.read(
               authority_options(
                 manager_reader: fn ->
                   %{manager_status() | checkpoint_hydration: %{state: :blocked}}
                 end
               )
             )
  end

  defp authority_options(overrides \\ []) do
    Keyword.merge(
      [
        compatibility_reader: fn ->
          %{firmware_version: "1.2.3", firmware_git_sha: @git_sha, capabilities: [tracking: 1]}
        end,
        identity_reader: fn -> {:ok, runtime_identity()} end,
        manager_reader: fn -> manager_status() end,
        gate_reader: fn -> {:open, gate_binding()} end,
        soak_period_ms: 5_000
      ],
      overrides
    )
  end

  defp manager_status do
    %{
      active: Map.put(gate_binding(), :device_id, @device_id),
      gate: {:open, gate_binding()},
      identity: runtime_identity(),
      recovery_error: nil,
      checkpoint_hydration: nil
    }
  end

  defp runtime_identity do
    %{
      device_id: @device_id,
      credential_epoch: 7,
      boot_id: @boot_id,
      storage_epoch: @storage_epoch
    }
  end

  defp gate_binding do
    %{
      credential_epoch: 7,
      storage_epoch: @storage_epoch,
      generation: 12,
      manifest_hash: @manifest_hash
    }
  end
end
