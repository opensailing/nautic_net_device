defmodule RacingOrg.Tracker.Pro.FirmwareValidation.CoordinatorTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.FirmwareValidation.Coordinator

  @git_sha String.duplicate("a", 40)

  test "waits for exact authority and starts one Trial with the original expired startup deadline" do
    clock = start_supervised!({Agent, fn -> 100 end}, id: {:clock, make_ref()})
    target = start_supervised!({Agent, fn -> :pending end}, id: {:target, make_ref()})
    parent = self()

    coordinator =
      start_supervised!(
        {Coordinator,
         name: nil,
         clock: fn -> Agent.get(clock, & &1) end,
         target_reader: fn -> Agent.get(target, & &1) end,
         trial_starter: fn opts ->
           send(parent, {:trial_started, opts})
           {:ok, self()}
         end,
         trial_opts: [store_dir: "/tmp/not-used-by-injected-starter"],
         rollback_after_ms: 50,
         retry_ms: 60_000}
      )

    assert %{phase: :target_pending, deadline_at_ms: 150} = Coordinator.status(coordinator)
    refute_received {:trial_started, _opts}

    Agent.update(clock, fn _current -> 200 end)
    Agent.update(target, fn _current -> {:ok, target_identity()} end)

    assert :ok = Coordinator.check_now(coordinator)

    assert_receive {:trial_started, opts}
    assert opts[:target] == Map.put(target_identity(), :deadline_at_ms, 150)
    assert opts[:clock].() == 200

    assert %{phase: :trial_started, deadline_at_ms: 150} = Coordinator.status(coordinator)

    assert :ok = Coordinator.check_now(coordinator)
    refute_receive {:trial_started, _opts}
  end

  test "invalid clocks fail startup closed" do
    Process.flag(:trap_exit, true)

    assert {:error, :invalid_clock} =
             Coordinator.start_link(
               name: nil,
               clock: fn -> :unknown end,
               target_reader: fn -> :pending end,
               trial_starter: fn _opts -> {:ok, self()} end,
               trial_opts: [],
               rollback_after_ms: 50
             )
  end

  defp target_identity do
    %{
      firmware: %{version: "1.2.3", git_sha: @git_sha},
      credential_epoch: 7,
      desired_generation: 12,
      soak_period_ms: 10
    }
  end
end
