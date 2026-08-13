defmodule RacingOrg.Tracker.Pro.FirmwareValidation.RequiredProcessesTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.FirmwareValidation.RequiredProcesses

  test "reports healthy only when every required supervisor and owner resolves to a live process" do
    assert %{supervisor: :healthy, owner: :healthy} =
             RequiredProcesses.status(
               supervisors: [:session, :manager, :gate],
               owners_reader: fn -> %{tracking: :tracking_owner, wifi: :wifi_owner} end,
               process_resolver: &{:ok, {:resolved, &1}},
               alive_reader: fn {:resolved, _reference} -> true end
             )
  end

  test "empty, missing, malformed, dead, and exceptional sources fail closed" do
    base = [
      supervisors: [:session],
      owners_reader: fn -> %{tracking: :tracking_owner} end,
      process_resolver: &{:ok, {:resolved, &1}},
      alive_reader: fn {:resolved, _reference} -> true end
    ]

    assert %{supervisor: :unhealthy, owner: :healthy} =
             RequiredProcesses.status(Keyword.put(base, :supervisors, []))

    assert %{supervisor: :unhealthy, owner: :healthy} =
             RequiredProcesses.status(
               Keyword.put(base, :process_resolver, fn
                 :session -> :error
                 reference -> {:ok, {:resolved, reference}}
               end)
             )

    assert %{supervisor: :healthy, owner: :unhealthy} =
             RequiredProcesses.status(Keyword.put(base, :owners_reader, fn -> %{} end))

    assert %{supervisor: :healthy, owner: :unhealthy} =
             RequiredProcesses.status(
               Keyword.put(base, :alive_reader, fn
                 {:resolved, :tracking_owner} -> false
                 {:resolved, _reference} -> true
               end)
             )

    assert %{supervisor: :unhealthy, owner: :unhealthy} =
             RequiredProcesses.status(
               supervisors: [:session],
               owners_reader: fn -> raise "owners unavailable" end,
               process_resolver: fn _reference -> raise "resolver unavailable" end,
               alive_reader: fn _pid -> true end
             )
  end
end
