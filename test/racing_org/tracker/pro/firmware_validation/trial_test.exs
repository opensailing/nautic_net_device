defmodule RacingOrg.Tracker.Pro.FirmwareValidation.TrialTest do
  use ExUnit.Case, async: false

  alias RacingOrg.Tracker.Pro.FirmwareValidation.DiagnosticsStore
  alias RacingOrg.Tracker.Pro.FirmwareValidation.Trial

  @git_sha String.duplicate("c", 40)

  setup do
    dir = Path.join(System.tmp_dir!(), "firmware_trial_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  test "requires one continuous healthy soak before exact firmware validation succeeds", %{dir: dir} do
    clock = agent(0)
    health = agent(:healthy)
    parent = self()

    pid =
      start_trial(dir,
        clock: fn -> Agent.get(clock, & &1) end,
        snapshot_opts: healthy_snapshot_opts(health),
        status_fun: fn -> false end,
        validate_fun: fn ->
          send(parent, :validate)
          :ok
        end,
        target: target(deadline_at_ms: 500, soak_period_ms: 100)
      )

    assert :ok = Trial.check_now(pid)
    refute_receive :validate

    Agent.update(clock, fn _ -> 80 end)
    assert :ok = Trial.check_now(pid)
    refute_receive :validate
    assert %{healthy_for_ms: 80, phase: :monitoring} = Trial.status(pid)

    Agent.update(health, fn _ -> :unhealthy end)
    Agent.update(clock, fn _ -> 90 end)
    assert :ok = Trial.check_now(pid)
    assert %{healthy_for_ms: 0, phase: :monitoring} = Trial.status(pid)

    Agent.update(health, fn _ -> :healthy end)
    Agent.update(clock, fn _ -> 150 end)
    assert :ok = Trial.check_now(pid)
    refute_receive :validate

    Agent.update(clock, fn _ -> 250 end)
    assert :ok = Trial.check_now(pid)
    assert_receive :validate
    assert %{phase: :validated, result: :ready} = Trial.status(pid)
    assert {:ok, %{phase: :validated, result: :ready}} = DiagnosticsStore.load(dir)
  end

  test "non-exact validation success retries, then durably decides rollback before revert and reboot", %{dir: dir} do
    clock = agent(0)
    parent = self()

    pid =
      start_trial(dir,
        clock: fn -> Agent.get(clock, & &1) end,
        snapshot_opts: healthy_snapshot_opts(),
        status_fun: fn -> false end,
        validate_fun: fn ->
          send(parent, :validate_attempt)
          {:ok, :not_exact}
        end,
        revert_fun: fn ->
          assert {:ok, %{phase: :rollback_decided}} = DiagnosticsStore.load(dir)
          send(parent, :revert)
          :ok
        end,
        reboot_fun: fn ->
          assert {:ok, %{phase: :reboot_pending}} = DiagnosticsStore.load(dir)
          send(parent, :reboot)
          :ok
        end,
        target: target(deadline_at_ms: 100, soak_period_ms: 10)
      )

    Agent.update(clock, fn _ -> 10 end)
    assert :ok = Trial.check_now(pid)
    assert_receive :validate_attempt
    refute_receive :revert
    assert %{phase: :monitoring} = Trial.status(pid)

    Agent.update(clock, fn _ -> 100 end)
    assert :ok = Trial.check_now(pid)
    assert_receive :validate_attempt
    assert_receive :revert
    assert_receive :reboot
    assert %{phase: :reboot_pending} = Trial.status(pid)
  end

  test "default runtime passively reverts, persists reboot pending, and explicitly reboots without repeating revert after restart",
       %{
         dir: dir
       } do
    clock = agent(0)
    runtime = configure_runtime_spy(dir, reboot: {:error, :reboot_failed})

    first =
      start_trial(dir,
        clock: fn -> Agent.get(clock, & &1) end,
        snapshot_opts: healthy_snapshot_opts(),
        runtime_module: __MODULE__.RuntimeSpy,
        target: target(deadline_at_ms: 1, soak_period_ms: 1)
      )

    Agent.update(clock, fn _ -> 1 end)
    assert :ok = Trial.check_now(first)

    assert_receive {:runtime_call, :revert, [reboot: false], {:ok, %{phase: :rollback_decided}}}
    refute_receive {:runtime_call, :revert_zero, _args, _record}
    assert_receive {:runtime_call, :reboot, [], {:ok, %{phase: :reboot_pending}}}
    assert {:ok, %{phase: :reboot_pending}} = DiagnosticsStore.load(dir)

    GenServer.stop(first)
    Agent.update(runtime, &Map.put(&1, :reboot, :ok))
    Agent.update(clock, fn _ -> 0 end)

    _restarted =
      start_trial(dir,
        clock: fn -> Agent.get(clock, & &1) end,
        snapshot_opts: healthy_snapshot_opts(),
        runtime_module: __MODULE__.RuntimeSpy,
        target: target(deadline_at_ms: 1, soak_period_ms: 1)
      )

    assert_receive {:runtime_call, :reboot, [], {:ok, %{phase: :reboot_pending}}}
    refute_receive {:runtime_call, :revert, _args, _record}
    refute_receive {:runtime_call, :revert_zero, _args, _record}
  end

  test "default runtime requires exact :ok from passive revert before persisting reboot pending", %{
    dir: dir
  } do
    clock = agent(0)
    _runtime = configure_runtime_spy(dir, revert: {:ok, :not_exact})

    pid =
      start_trial(dir,
        clock: fn -> Agent.get(clock, & &1) end,
        snapshot_opts: healthy_snapshot_opts(),
        runtime_module: __MODULE__.RuntimeSpy,
        target: target(deadline_at_ms: 1, soak_period_ms: 1)
      )

    Agent.update(clock, fn _ -> 1 end)
    assert :ok = Trial.check_now(pid)

    assert_receive {:runtime_call, :revert, [reboot: false], {:ok, %{phase: :rollback_decided}}}
    refute_receive {:runtime_call, :reboot, _args, _record}

    assert %{phase: :rollback_decided, effect_status: :revert_failed} = Trial.status(pid)
    assert {:ok, %{phase: :rollback_decided}} = DiagnosticsStore.load(dir)
  end

  test "directory-sync uncertainty stops before rollback or reboot effects", %{dir: dir} do
    previous_trap_exit = Process.flag(:trap_exit, true)
    on_exit(fn -> Process.flag(:trap_exit, previous_trap_exit) end)

    clock = agent(0)
    armed = agent(false)
    parent = self()

    fault_injector = fn
      :renamed ->
        Agent.get_and_update(armed, fn
          true -> {{:error, :simulated_power_loss}, false}
          false -> {:ok, false}
        end)

      _other ->
        :ok
    end

    pid =
      start_trial(dir,
        clock: fn -> Agent.get(clock, & &1) end,
        snapshot_opts: healthy_snapshot_opts(),
        status_fun: fn -> false end,
        validate_fun: fn -> {:ok, :not_exact} end,
        revert_fun: fn ->
          send(parent, :unexpected_revert)
          :ok
        end,
        reboot_fun: fn ->
          send(parent, :unexpected_reboot)
          :ok
        end,
        store_opts: [fault_injector: fault_injector],
        target: target(deadline_at_ms: 100, soak_period_ms: 10)
      )

    Agent.update(armed, fn _ -> true end)
    Agent.update(clock, fn _ -> 100 end)

    assert {{:diagnostics_persist_failed, {:durability_uncertain, {:fault_injected, :renamed, :simulated_power_loss}}},
            {GenServer, :call, [^pid, :check_now, :infinity]}} =
             catch_exit(Trial.check_now(pid))

    refute_receive :unexpected_revert
    refute_receive :unexpected_reboot
  end

  test "restart recovers a conservative remaining budget and resets soak continuity", %{dir: dir} do
    clock = agent(0)
    parent = self()

    opts = [
      clock: fn -> Agent.get(clock, & &1) end,
      snapshot_opts: healthy_snapshot_opts(),
      status_fun: fn -> false end,
      validate_fun: fn ->
        send(parent, :validated_after_restart)
        :ok
      end,
      target: target(deadline_at_ms: 500, soak_period_ms: 100),
      retry_ms: 10
    ]

    pid = start_trial(dir, opts)
    assert :ok = Trial.check_now(pid)

    Agent.update(clock, fn _ -> 50 end)
    assert :ok = Trial.check_now(pid)
    assert %{healthy_for_ms: 50, remaining_deadline_ms: 450} = Trial.status(pid)
    assert {:ok, %{timing: %{remaining_deadline_ms: 440}}} = DiagnosticsStore.load(dir)
    GenServer.stop(pid)

    Agent.update(clock, fn _ -> 0 end)
    rebooted = start_trial(dir, opts)
    assert %{healthy_for_ms: 0, remaining_deadline_ms: 440} = Trial.status(rebooted)

    Agent.update(clock, fn _ -> 99 end)
    assert :ok = Trial.check_now(rebooted)
    refute_receive :validated_after_restart

    Agent.update(clock, fn _ -> 100 end)
    assert :ok = Trial.check_now(rebooted)
    assert_receive :validated_after_restart
    assert %{phase: :validated} = Trial.status(rebooted)
  end

  test "a reboot-pending terminal decision resumes reboot without repeating revert", %{dir: dir} do
    clock = agent(0)
    parent = self()

    first =
      start_trial(dir,
        clock: fn -> Agent.get(clock, & &1) end,
        snapshot_opts: healthy_snapshot_opts(),
        status_fun: fn -> false end,
        validate_fun: fn -> :error end,
        revert_fun: fn ->
          send(parent, :first_revert)
          :ok
        end,
        reboot_fun: fn ->
          send(parent, :first_reboot)
          {:error, :reboot_failed}
        end,
        target: target(deadline_at_ms: 1, soak_period_ms: 1)
      )

    Agent.update(clock, fn _ -> 1 end)
    assert :ok = Trial.check_now(first)
    assert_receive :first_revert
    assert_receive :first_reboot
    assert {:ok, %{phase: :reboot_pending}} = DiagnosticsStore.load(dir)
    GenServer.stop(first)

    Agent.update(clock, fn _ -> 0 end)

    _restarted =
      start_trial(dir,
        clock: fn -> Agent.get(clock, & &1) end,
        snapshot_opts: healthy_snapshot_opts(),
        status_fun: fn -> false end,
        validate_fun: fn -> :error end,
        revert_fun: fn ->
          send(parent, :unexpected_revert)
          :ok
        end,
        reboot_fun: fn ->
          send(parent, :resumed_reboot)
          :ok
        end,
        target: target(deadline_at_ms: 1, soak_period_ms: 1)
      )

    assert_receive :resumed_reboot
    refute_receive :unexpected_revert
  end

  test "default clock remains VM-boot-relative across fresh and recovered Trial processes", %{dir: dir} do
    initial_boot_ms = vm_boot_ms()
    deadline_at_ms = initial_boot_ms + 2_000

    first =
      start_trial(dir,
        snapshot_opts: healthy_snapshot_opts(),
        status_fun: fn -> false end,
        validate_fun: fn -> :error end,
        retry_ms: 100,
        target: target(deadline_at_ms: deadline_at_ms)
      )

    assert %{remaining_deadline_ms: first_remaining_ms} = Trial.status(first)
    assert first_remaining_ms in 0..2_000
    assert {:ok, %{timing: %{remaining_deadline_ms: recoverable_ms}}} = DiagnosticsStore.load(dir)
    assert recoverable_ms <= first_remaining_ms
    GenServer.stop(first)

    Process.sleep(25)

    recovered =
      start_trial(dir,
        snapshot_opts: healthy_snapshot_opts(),
        status_fun: fn -> false end,
        validate_fun: fn -> :error end,
        retry_ms: 100,
        target: target(deadline_at_ms: deadline_at_ms)
      )

    assert %{remaining_deadline_ms: recovered_ms} = Trial.status(recovered)
    assert recovered_ms <= recoverable_ms
    GenServer.stop(recovered)

    fresh_dir = dir <> "_fresh"
    on_exit(fn -> File.rm_rf(fresh_dir) end)

    fresh =
      start_trial(fresh_dir,
        snapshot_opts: healthy_snapshot_opts(),
        status_fun: fn -> false end,
        validate_fun: fn -> :error end,
        retry_ms: 100,
        target: target(deadline_at_ms: deadline_at_ms)
      )

    assert %{remaining_deadline_ms: fresh_remaining_ms} = Trial.status(fresh)
    assert fresh_remaining_ms < first_remaining_ms
  end

  test "host runtime unavailability start-gates the trial without consuming deadline or deciding rollback", %{
    dir: dir
  } do
    parent = self()
    previous_trap_exit = Process.flag(:trap_exit, true)

    assert {:error, :firmware_validation_unavailable} =
             Trial.start_link(
               name: nil,
               store_dir: dir,
               snapshot_opts: healthy_snapshot_opts(),
               target: target(deadline_at_ms: 1, soak_period_ms: 1),
               revert_fun: fn ->
                 send(parent, :unexpected_revert)
                 :ok
               end,
               reboot_fun: fn ->
                 send(parent, :unexpected_reboot)
                 :ok
               end
             )

    Process.flag(:trap_exit, previous_trap_exit)
    assert :empty = DiagnosticsStore.load(dir)
    refute_receive :unexpected_revert
    refute_receive :unexpected_reboot
  end

  test "a regressing injected clock fails closed into a durable rollback decision", %{dir: dir} do
    clock = agent(100)
    parent = self()

    pid =
      start_trial(dir,
        clock: fn -> Agent.get(clock, & &1) end,
        snapshot_opts: healthy_snapshot_opts(),
        status_fun: fn -> false end,
        validate_fun: fn -> :ok end,
        revert_fun: fn ->
          send(parent, :regression_revert)
          :ok
        end,
        reboot_fun: fn ->
          send(parent, :regression_reboot)
          :ok
        end,
        target: target(deadline_at_ms: 200, soak_period_ms: 50)
      )

    Agent.update(clock, fn _ -> 90 end)
    assert :ok = Trial.check_now(pid)
    assert_receive :regression_revert
    assert_receive :regression_reboot
    assert {:ok, %{phase: :reboot_pending, result: {:rollback_required, unmet}}} = DiagnosticsStore.load(dir)
    assert unmet == [%{criterion: :input, diagnostic_code: :invalid_snapshot}]
  end

  test "unreadable diagnostics prevent startup and every firmware effect", %{dir: dir} do
    parent = self()
    File.write!(DiagnosticsStore.path(dir), "corrupt")
    previous_trap_exit = Process.flag(:trap_exit, true)

    assert {:error, {:diagnostics_unavailable, :corrupt}} =
             Trial.start_link(
               name: nil,
               store_dir: dir,
               target: target(),
               snapshot_opts: healthy_snapshot_opts(),
               status_fun: fn ->
                 send(parent, :unexpected_status)
                 false
               end,
               validate_fun: fn ->
                 send(parent, :unexpected_validate)
                 :ok
               end,
               revert_fun: fn ->
                 send(parent, :unexpected_revert)
                 :ok
               end,
               reboot_fun: fn ->
                 send(parent, :unexpected_reboot)
                 :ok
               end
             )

    Process.flag(:trap_exit, previous_trap_exit)
    refute_receive _message
  end

  test "child supervision is transient and format_status exposes only the safe projection", %{dir: dir} do
    assert %{restart: :transient, type: :worker} = Trial.child_spec(store_dir: dir, target: target())

    status = %{
      state: %{
        phase: :monitoring,
        result: {:pending, []},
        remaining_deadline_ms: 10,
        healthy_since_ms: 0,
        last_now_ms: 0,
        target_identity: Map.put(target_identity(), :secret, "target-secret"),
        snapshot_opts: [session_reader: fn -> "session-secret" end],
        validate_fun: fn -> "validator-secret" end,
        store_dir: "/data/secret-path"
      },
      message: {:check, "message-secret"},
      reason: {:badmatch, "reason-secret"},
      log: [{:in, "log-secret"}]
    }

    rendered =
      status
      |> Trial.format_status()
      |> then(&:io_lib.format(~c"~0p", [&1]))
      |> IO.iodata_to_binary()

    for secret <- [
          "target-secret",
          "session-secret",
          "validator-secret",
          "secret-path",
          "message-secret",
          "reason-secret",
          "log-secret"
        ] do
      refute rendered =~ secret
    end

    assert rendered =~ "monitoring"
  end

  defp start_trial(dir, opts) do
    parent = self()

    scheduler = fn message, delay ->
      send(parent, {:scheduled, message, delay})
      make_ref()
    end

    defaults = [
      name: nil,
      store_dir: dir,
      target: target(),
      retry_ms: 10,
      schedule_fun: scheduler,
      cancel_timer_fun: fn _timer_ref -> :ok end
    ]

    {:ok, pid} = Trial.start_link(Keyword.merge(defaults, opts))
    pid
  end

  defp healthy_snapshot_opts(health_agent \\ nil) do
    telemetry_reader = fn ->
      case health_agent && Agent.get(health_agent, & &1) do
        :unhealthy -> :failed
        _other -> :succeeded
      end
    end

    [
      firmware_version_reader: fn -> "0.7.0" end,
      git_commit_reader: fn -> @git_sha end,
      session_reader: fn -> {:ok, %{credential_epoch: 4, out_key: "never-copy-this"}} end,
      manager_reader: fn ->
        %{
          active: Map.put(gate_binding(), :device_id, <<1::128>>),
          gate: {:open, gate_binding()},
          identity: nil,
          recovery_error: nil
        }
      end,
      applier_owners_reader: fn -> %{tracking: self()} end,
      owner_alive_reader: fn _owner -> true end,
      control_receipt_reader: fn -> :succeeded end,
      telemetry_receipt_reader: telemetry_reader,
      outbox_reader: fn -> %{corrupt: false, critical_pressure: false} end
    ]
  end

  defp gate_binding do
    %{
      credential_epoch: 4,
      storage_epoch: <<2::128>>,
      generation: 12,
      manifest_hash: <<3::256>>
    }
  end

  defp target(overrides \\ []) do
    Map.merge(
      Map.put(target_identity(), :deadline_at_ms, 500),
      Map.new(overrides)
    )
  end

  defp target_identity do
    %{
      firmware: %{version: "0.7.0", git_sha: @git_sha},
      credential_epoch: 4,
      desired_generation: 12,
      soak_period_ms: 100
    }
  end

  defp configure_runtime_spy(dir, overrides) do
    runtime =
      agent(
        Map.merge(
          %{
            owner: self(),
            dir: dir,
            firmware_valid?: false,
            validate_firmware: :error,
            revert: :ok,
            revert_zero: :ok,
            reboot: :ok
          },
          Map.new(overrides)
        )
      )

    Application.put_env(:racing_org_tracker_pro, __MODULE__.RuntimeSpy, runtime)
    on_exit(fn -> Application.delete_env(:racing_org_tracker_pro, __MODULE__.RuntimeSpy) end)
    runtime
  end

  defp vm_boot_ms do
    System.monotonic_time()
    |> Kernel.-(:erlang.system_info(:start_time))
    |> System.convert_time_unit(:native, :millisecond)
  end

  defp agent(initial) do
    start_supervised!(%{
      id: make_ref(),
      start: {Agent, :start_link, [fn -> initial end]}
    })
  end

  defmodule RuntimeSpy do
    alias RacingOrg.Tracker.Pro.FirmwareValidation.DiagnosticsStore

    def firmware_valid?, do: call(:firmware_valid?, [])
    def validate_firmware, do: call(:validate_firmware, [])
    def revert, do: call(:revert_zero, [])
    def revert(opts), do: call(:revert, opts)
    def reboot, do: call(:reboot, [])

    defp call(operation, args) do
      runtime = Application.fetch_env!(:racing_org_tracker_pro, __MODULE__)
      config = Agent.get(runtime, & &1)
      send(config.owner, {:runtime_call, operation, args, DiagnosticsStore.load(config.dir)})
      Map.fetch!(config, operation)
    end
  end
end
