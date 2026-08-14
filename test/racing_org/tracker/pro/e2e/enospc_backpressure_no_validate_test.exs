defmodule RacingOrg.Tracker.Pro.E2E.EnospcBackpressureNoValidateTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Chained ENOSPC-style scenario: the durable outbox admission path is driven
  into real disk-capacity backpressure (`{:error, {:backpressure,
  :disk_capacity}}`) and that unhealthy outbox is proven to block the
  firmware-validation health gate until the outbox recovers.

  The chain runs the production modules end to end on a real temporary
  filesystem root:

    Producer.DataSet / Producer.HealthEvent
      -> Outbox.Owner (single supervised writer, injected identity)
        -> Outbox.Store (real segments, run-state, and compaction on disk)
          -> OutboxHealth.read/1 over the live sanitized Owner status
            -> Snapshot.build/2 -> HealthCriteria.evaluate/2
              -> FirmwareValidation.Trial (real process; injected
                 validate_fun observes whether firmware validation runs)

  Process-boundary limits of this module:

    * Disk capacity is injected through the Store's `max_disk_bytes` limit —
      the same capacity injection the outbox suites use. No fault-injecting
      filesystem is installed and no real ENOSPC errno is raised by the OS.
    * The non-outbox legs of the health snapshot (session, desired-state
      manager, applier owners, receipt round-trips, firmware version and git
      SHA) are supplied as healthy fixture readers exactly as the
      firmware_validation harnesses supply them, because a real authenticated
      session and desired-state runtime cannot be constructed inside one test
      module. The outbox leg is the real Owner/Store chain.
    * Firmware validation effects are observed through an injected
      `validate_fun`; no Nerves runtime exists on the host, so partition
      validation itself is out of scope.
    * Trial timing uses an injected agent clock and an inert schedule
      function; every evaluation is driven synchronously by `check_now/1`,
      so no timer races exist.
    * Unlike the durable_delivery suites (written for `mix test --no-start`),
      this module runs under the started application: every Owner here is
      started explicitly on a unique temporary root with explicit options and
      never touches the production Owner or its root.
  """

  alias RacingOrg.Tracker.Pro.DurableDelivery.Outbox.Owner
  alias RacingOrg.Tracker.Pro.DurableDelivery.Producer.DataSet, as: DataSetProducer
  alias RacingOrg.Tracker.Pro.DurableDelivery.Producer.HealthEvent, as: HealthEventProducer
  alias RacingOrg.Tracker.Pro.DurableDelivery.HealthEvent.V1, as: HealthEventV1

  alias RacingOrg.Tracker.Pro.FirmwareValidation.{
    HealthCriteria,
    OutboxHealth,
    Snapshot,
    Trial
  }

  alias RacingOrg.Tracker.Protobuf.DataSet, as: DataSetProto

  @device_id Base.decode16!("0f1e2d3c4b5a69788796a5b4c3d2e1f0", case: :lower)
  @storage_epoch Base.decode16!("00112233445566778899aabbccddeeff", case: :lower)
  @credential_epoch 7
  @git_sha String.duplicate("c", 40)
  @manifest_hash :binary.copy(<<0xA5>>, 32)

  @roomy_limits [
    max_entries: 100,
    max_bytes: 100_000,
    segment_max_bytes: 4_096
  ]

  setup do
    unique = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "e2e_enospc_outbox_#{unique}")
    trial_dir = Path.join(System.tmp_dir!(), "e2e_enospc_trial_#{unique}")
    File.mkdir_p!(trial_dir)

    on_exit(fn ->
      File.rm_rf(root)
      File.rm_rf(trial_dir)
    end)

    %{root: root, trial_dir: trial_dir}
  end

  test "producers surface disk-capacity backpressure without crash or silent drop and accepted entries drain in place",
       %{root: root} do
    owner = start_owner!(root, max_disk_bytes: 6_000)

    {data_sets, rejected_payload, rejected_index} = fill_until_disk_backpressure(owner)

    assert length(data_sets) >= 2

    # 1. The producer surfaced the exact contract without crashing anything.
    assert Process.alive?(owner)

    assert %{accepting: true, quarantined: false, pending_entries: data_set_count} =
             Owner.status(owner)

    assert data_set_count == length(data_sets)

    # 2. Retrying the rejected admission is absorbed as the same clean error
    # without partially admitting anything.
    assert {:error, {:backpressure, :disk_capacity}} =
             DataSetProducer.admit(rejected_payload,
               outbox: owner,
               source_id: data_set_source_id(rejected_index)
             )

    assert %{pending_entries: ^data_set_count} = Owner.status(owner)

    # 3. The production health-event producer aimed at the same outbox keeps
    # admitting its smaller payloads durably until it too is rejected with the
    # same exact contract, absorbed without crash.
    health_events = fill_health_events_until_disk_backpressure(owner)
    assert health_events != []

    accepted = data_sets ++ health_events

    assert %{accepting: true, quarantined: false, pending_entries: pending_entries} =
             Owner.status(owner)

    assert pending_entries == length(accepted)

    # No silent drop: pending is exactly every accepted payload across both
    # streams, in admission order.
    assert Enum.map(Owner.pending(owner), & &1.payload) ==
             Enum.map(accepted, fn {payload, _receipt} -> payload end)

    # 4. Accepted entries remain drainable in place: acknowledging the two
    # oldest receipts compacts the store and frees disk capacity.
    [{first_payload, first_receipt}, {second_payload, second_receipt} | remaining] = accepted
    assert {:ok, [first_entry]} = Owner.acknowledge(owner, first_receipt)
    assert first_entry.payload == first_payload
    assert first_entry.payload_hash == :crypto.hash(:sha256, first_payload)

    assert {:ok, [second_entry]} = Owner.acknowledge(owner, second_receipt)
    assert second_entry.payload == second_payload

    # The previously rejected DataSet is now admitted durably.
    assert {:ok, late_receipt} =
             DataSetProducer.admit(rejected_payload,
               outbox: owner,
               source_id: data_set_source_id(rejected_index)
             )

    assert late_receipt.payload_hash == :crypto.hash(:sha256, rejected_payload)

    # Drain everything that was ever accepted; each receipt retires exactly
    # its own payload.
    for {payload, receipt} <- remaining ++ [{rejected_payload, late_receipt}] do
      assert {:ok, [entry]} = Owner.acknowledge(owner, receipt)
      assert entry.payload == payload
    end

    assert Owner.pending(owner) == []
    assert %{accepting: true, quarantined: false, pending_entries: 0} = Owner.status(owner)
  end

  test "the firmware-validation gate refuses to validate while the outbox is unhealthy and validates once it drains",
       %{root: root, trial_dir: trial_dir} do
    # Phase A: durably admit real DataSets through the production producer,
    # then measure the exact durable footprint.
    owner_a = start_owner!(root, max_disk_bytes: 60_000)

    accepted =
      for index <- 1..12 do
        payload = encoded_data_set(index)

        assert {:ok, receipt} =
                 DataSetProducer.admit(payload,
                   outbox: owner_a,
                   source_id: data_set_source_id(index)
                 )

        {payload, receipt}
      end

    assert %{pending_entries: 12, pending_bytes: live_bytes, disk_bytes: disk_bytes} =
             Owner.status(owner_a)

    stop_owner!(owner_a)

    # Phase B: reopen the same root under measured near-full limits — the
    # store replays every accepted entry and now sits above the gate's
    # default 90% critical-pressure threshold while a fresh admission is
    # rejected with the exact disk-capacity contract.
    byte_slack = max(div(live_bytes, 10), 1)
    disk_slack = max(div(disk_bytes, 10), 1)

    tight_limits = [
      max_bytes: live_bytes + byte_slack,
      max_disk_bytes: disk_bytes + disk_slack
    ]

    owner_b = start_owner!(root, tight_limits)

    assert %{pending_entries: 12, disk_bytes: reopened_disk_bytes} = Owner.status(owner_b)
    assert reopened_disk_bytes * 100 >= (disk_bytes + disk_slack) * 90

    assert {:error, {:backpressure, :disk_capacity}} =
             DataSetProducer.admit(encoded_data_set(13),
               outbox: owner_b,
               source_id: data_set_source_id(13)
             )

    assert %{accepting: true, quarantined: false} = Owner.status(owner_b)

    # The live Owner status feeds the real gate projection at its DEFAULT
    # critical-pressure threshold.
    owner_holder = agent(owner_b)

    outbox_reader = fn ->
      OutboxHealth.read(status_reader: fn -> Owner.status(Agent.get(owner_holder, & &1)) end)
    end

    assert %{corrupt: false, critical_pressure: true} = outbox_reader.()

    # The unhealthy outbox is the one and only unmet validation criterion.
    snapshot =
      Snapshot.build(
        %{observed_at_ms: 200, soak_started_at_ms: 0},
        snapshot_opts(outbox_reader)
      )

    assert {:pending, unmet} =
             HealthCriteria.evaluate(snapshot, Map.put(target_identity(), :deadline_at_ms, 1_000_000))

    assert unmet == [%{criterion: :outbox_pressure, diagnostic_code: :outbox_critical_pressure}]

    # A real Trial wired to the live outbox must not validate firmware while
    # the outbox is unhealthy.
    parent = self()
    clock = agent(0)
    events = agent([])

    {:ok, trial} =
      Trial.start_link(
        name: nil,
        store_dir: trial_dir,
        target: Map.put(target_identity(), :deadline_at_ms, 1_000_000),
        clock: fn -> Agent.get(clock, & &1) end,
        retry_ms: 60_000,
        snapshot_opts: snapshot_opts(outbox_reader),
        status_fun: fn -> false end,
        validate_fun: fn ->
          send(parent, :firmware_validation_attempted)
          :ok
        end,
        schedule_fun: fn message, delay ->
          send(parent, {:scheduled, message, delay})
          make_ref()
        end,
        cancel_timer_fun: fn _timer_ref -> :ok end,
        health_event_sink: fn event ->
          Agent.update(events, &(&1 ++ [event]))
          {:ok, :receipt}
        end,
        health_event_context: %{
          manifest_hash_reader: fn -> %{active: %{manifest_hash: @manifest_hash}} end
        }
      )

    on_exit(fn -> if Process.alive?(trial), do: GenServer.stop(trial) end)

    # Inside the trial the soak also restarts while the outbox is unhealthy,
    # so both criteria stay unmet on every check until the outbox recovers.
    outbox_blocked = [
      %{criterion: :outbox_pressure, diagnostic_code: :outbox_critical_pressure},
      %{criterion: :soak_period, diagnostic_code: :soak_period_incomplete}
    ]

    assert %{phase: :monitoring, result: {:pending, ^outbox_blocked}} = Trial.status(trial)
    refute_received :firmware_validation_attempted

    Agent.update(clock, fn _now -> 10 end)
    assert :ok = Trial.check_now(trial)
    assert %{phase: :monitoring, result: {:pending, ^outbox_blocked}} = Trial.status(trial)
    refute_received :firmware_validation_attempted

    # Recovery: restore capacity over the same root and drain every accepted
    # entry — the durable receipts from phase A retire their exact payloads.
    stop_owner!(owner_b)
    owner_c = start_owner!(root, max_disk_bytes: 60_000)
    Agent.update(owner_holder, fn _previous -> owner_c end)

    assert %{pending_entries: 12} = Owner.status(owner_c)

    for {payload, receipt} <- accepted do
      assert {:ok, [entry]} = Owner.acknowledge(owner_c, receipt)
      assert entry.payload == payload
    end

    assert Owner.pending(owner_c) == []
    assert %{corrupt: false, critical_pressure: false} = outbox_reader.()

    # The gate now admits health, soaks on the injected clock, and only then
    # validates firmware exactly once.
    Agent.update(clock, fn _now -> 20 end)
    assert :ok = Trial.check_now(trial)

    assert %{phase: :monitoring, result: {:pending, soaking}} = Trial.status(trial)
    assert soaking == [%{criterion: :soak_period, diagnostic_code: :soak_period_incomplete}]
    refute_received :firmware_validation_attempted

    Agent.update(clock, fn _now -> 150 end)
    assert :ok = Trial.check_now(trial)

    assert_received :firmware_validation_attempted
    refute_received :firmware_validation_attempted
    assert %{phase: :validated, result: :ready} = Trial.status(trial)

    # The durable health-evidence transitions name the outbox blocker first.
    transitions =
      events
      |> Agent.get(& &1)
      |> Enum.map(&{&1.event_type, Map.get(&1, :reason_code)})

    assert transitions == [
             {:validation_pending, :outbox_critical_pressure},
             {:validation_pending, :soak_period_incomplete},
             {:validation_succeeded, nil}
           ]

    for event <- Agent.get(events, & &1) do
      assert {:ok, _payload} = HealthEventV1.encode(event)
    end
  end

  defp fill_until_disk_backpressure(owner) do
    Enum.reduce_while(1..40, [], fn index, accepted ->
      payload = encoded_data_set(index)

      case DataSetProducer.admit(payload, outbox: owner, source_id: data_set_source_id(index)) do
        {:ok, receipt} ->
          {:cont, [{payload, receipt} | accepted]}

        {:error, {:backpressure, :disk_capacity}} ->
          {:halt, {Enum.reverse(accepted), payload, index}}

        {:error, reason} ->
          flunk("expected {:backpressure, :disk_capacity}, got: #{inspect(reason)}")
      end
    end)
    |> case do
      {_accepted, _payload, _index} = result -> result
      accepted when is_list(accepted) -> flunk("never reached disk-capacity backpressure")
    end
  end

  defp fill_health_events_until_disk_backpressure(owner) do
    Enum.reduce_while(1..40, [], fn index, accepted ->
      health_event = outbox_unhealthy_event(index)

      case HealthEventProducer.admit(health_event, outbox: owner) do
        {:ok, receipt} ->
          {:ok, payload} = HealthEventV1.encode(health_event)
          {:cont, accepted ++ [{payload, receipt}]}

        {:error, {:backpressure, :disk_capacity}} ->
          {:halt, {:rejected, accepted}}

        {:error, reason} ->
          flunk("expected {:backpressure, :disk_capacity}, got: #{inspect(reason)}")
      end
    end)
    |> case do
      {:rejected, accepted} -> accepted
      _all_admitted -> flunk("health events never reached disk-capacity backpressure")
    end
  end

  defp encoded_data_set(index) do
    DataSetProto.encode(
      struct(DataSetProto,
        counter: index,
        ref: "e2e-enospc-#{index}",
        boat_identifier: String.duplicate("x", 600)
      )
    )
  end

  defp data_set_source_id(index), do: "e2e/enospc/datasets/#{index}"

  # A distinct occurrence per index selects a distinct durable event identity.
  defp outbox_unhealthy_event(index) do
    %{
      event_type: :outbox_unhealthy,
      reason_code: :outbox_not_writable,
      occurred_at_ms: 1_000 + index,
      firmware_version: "0.7.0",
      firmware_git_sha: @git_sha,
      target: %{
        credential_epoch: 4,
        desired_generation: 12,
        manifest_hash: @manifest_hash
      }
    }
  end

  # Healthy fixture readers for every non-outbox leg, mirroring the
  # firmware_validation harnesses; the outbox leg is the real live chain.
  defp snapshot_opts(outbox_reader) do
    [
      firmware_version_reader: fn -> "0.7.0" end,
      git_commit_reader: fn -> @git_sha end,
      session_reader: fn -> {:ok, %{credential_epoch: 4}} end,
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
      telemetry_receipt_reader: fn -> :succeeded end,
      outbox_reader: outbox_reader
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

  defp target_identity do
    %{
      firmware: %{version: "0.7.0", git_sha: @git_sha},
      credential_epoch: 4,
      desired_generation: 12,
      soak_period_ms: 100
    }
  end

  defp identity do
    %{
      device_id: @device_id,
      credential_epoch: @credential_epoch,
      storage_epoch: @storage_epoch
    }
  end

  defp start_owner!(root, overrides) do
    defaults =
      [
        root: root,
        identity: fn -> {:ok, identity()} end,
        streams: [:telemetry, :health]
      ] ++ @roomy_limits

    {:ok, owner} = Owner.start_link(Keyword.merge(defaults, overrides))
    on_exit(fn -> if Process.alive?(owner), do: stop_owner!(owner) end)
    owner
  end

  defp stop_owner!(owner) do
    reference = Process.monitor(owner)
    Process.unlink(owner)
    Process.exit(owner, :shutdown)

    receive do
      {:DOWN, ^reference, :process, _pid, _reason} -> :ok
    after
      5_000 -> flunk("owner did not stop within 5s")
    end
  end

  defp agent(initial) do
    start_supervised!(%{
      id: make_ref(),
      start: {Agent, :start_link, [fn -> initial end]}
    })
  end
end
