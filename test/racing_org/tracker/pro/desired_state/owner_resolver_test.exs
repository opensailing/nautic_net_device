defmodule RacingOrg.Tracker.Pro.DesiredState.OwnerResolverTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.DesiredState.OwnerResolver

  test "a resolver cannot outlive an unexpectedly terminated guardian" do
    test_pid = self()

    caller =
      Task.async(fn ->
        OwnerResolver.run(
          fn ->
            Process.flag(:trap_exit, true)
            send(test_pid, {:resolver_blocked, self()})

            receive do
              :release -> :ok
            end
          end,
          timeout_ms: 5_000
        )
      end)

    assert_receive {:resolver_blocked, resolver_pid}

    on_exit(fn ->
      if Process.alive?(resolver_pid), do: Process.exit(resolver_pid, :kill)
    end)

    resolver_ref = Process.monitor(resolver_pid)
    guardian_pid = await_guardian_pid(caller.pid, resolver_pid)
    Process.exit(guardian_pid, :kill)

    assert {:error, :owner_resolution_failed} = Task.await(caller, 500)
    assert_receive {:DOWN, ^resolver_ref, :process, ^resolver_pid, :killed}, 250
    refute Process.alive?(resolver_pid)
  end

  defp await_guardian_pid(caller_pid, resolver_pid, attempts \\ 100)

  defp await_guardian_pid(_caller_pid, _resolver_pid, 0),
    do: flunk("caller did not monitor the resolver guardian")

  defp await_guardian_pid(caller_pid, resolver_pid, attempts) do
    guardian_pid =
      caller_pid
      |> Process.info(:monitors)
      |> elem(1)
      |> Enum.find_value(fn
        {:process, pid} when pid != resolver_pid -> pid
        _other -> nil
      end)

    if is_pid(guardian_pid) and Process.alive?(guardian_pid) do
      guardian_pid
    else
      Process.sleep(1)
      await_guardian_pid(caller_pid, resolver_pid, attempts - 1)
    end
  end
end
