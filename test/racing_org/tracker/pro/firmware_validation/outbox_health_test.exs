defmodule RacingOrg.Tracker.Pro.FirmwareValidation.OutboxHealthTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.FirmwareValidation.OutboxHealth

  test "projects a healthy accepting owner below every critical pressure limit" do
    assert %{corrupt: false, critical_pressure: false} =
             OutboxHealth.read(status_reader: fn -> owner_status() end)
  end

  test "marks pressure critical when any bounded resource reaches the injected threshold" do
    status = %{owner_status() | pending_entries: 9, max_entries: 10}

    assert %{corrupt: false, critical_pressure: true} =
             OutboxHealth.read(
               status_reader: fn -> status end,
               critical_pressure_percent: 90
             )
  end

  test "unbound, quarantined, malformed, and exceptional owner status fail closed" do
    for status <- [
          %{owner_status() | storage_epoch_bound: false, accepting: false},
          %{owner_status() | quarantined: true, accepting: false},
          Map.delete(owner_status(), :disk_bytes),
          {:error, :outbox_owner_unavailable}
        ] do
      assert %{corrupt: true, critical_pressure: true} =
               OutboxHealth.read(status_reader: fn -> status end)
    end

    assert %{corrupt: true, critical_pressure: true} =
             OutboxHealth.read(status_reader: fn -> raise "status unavailable" end)
  end

  defp owner_status do
    %{
      accepting: true,
      quarantined: false,
      storage_epoch_bound: true,
      pending_entries: 2,
      pending_bytes: 200,
      disk_bytes: 300,
      max_entries: 10,
      max_bytes: 1_000,
      max_disk_bytes: 2_000,
      loss_authorizations: 0,
      streams: 6
    }
  end
end
