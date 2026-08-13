defmodule RacingOrg.Tracker.Pro.ApplicationTest do
  @moduledoc """
  Boot test for the P9-job-6 supervision wiring: on host the application starts
  cleanly with the new secure-transport children present + idle.

  On host (the test target) the gating choice is:

    * `SessionHolder` runs EVERYWHERE (the UDP send path + tests read it). It must
      be present and IDLE (no live session).
    * `ChannelClient`, `BootProvisioner`, and the `BulkUploader` GenServer are gated
      to the real device target AND the pinned server public key being configured
      (`ServerIdentity.configured?`), so on host they are NOT in the tree at all —
      there is no connect attempt, no claim attempt, no crash loop.

  This test asserts the live tree the running application booted (the application is
  started for the suite via `mod: {RacingOrg.Tracker.Pro.Application, []}`).
  """
  use ExUnit.Case, async: false

  alias RacingOrg.Tracker.Pro.DesiredState.{
    Applier,
    Manager,
    OperationalGate,
    OperationalGate.AuthorityRegistry,
    OperationalGate.AuthorityRegistry.Root,
    OperationalGate.AuthorityRegistry.Store,
    RuntimeIdentity
  }

  alias RacingOrg.Tracker.Pro.Commands.Ledger.Executor, as: CommandExecutor
  alias RacingOrg.Tracker.Pro.DataSetRecorder
  alias RacingOrg.Tracker.Pro.DataSetUploader
  alias RacingOrg.Tracker.Pro.DurableDelivery.Outbox.Owner, as: OutboxOwner
  alias RacingOrg.Tracker.Pro.Race.BulkUploader
  alias RacingOrg.Tracker.Pro.SecureTransport.BootProvisioner
  alias RacingOrg.Tracker.Pro.SecureTransport.ChannelClient
  alias RacingOrg.Tracker.Pro.SecureTransport.ServerIdentity
  alias RacingOrg.Tracker.Pro.SecureTransport.SessionHolder
  alias RacingOrg.Tracker.Pro.Upstream.Config, as: UpstreamConfig

  @supervisor RacingOrg.Tracker.Pro.Supervisor

  defp child_ids do
    @supervisor
    |> Supervisor.which_children()
    |> Enum.map(fn {id, _pid, _type, _modules} -> id end)
  end

  defp child(id) do
    @supervisor
    |> Supervisor.which_children()
    |> Enum.find(fn {child_id, _pid, _type, _modules} -> child_id == id end)
  end

  defp spec_ids(children) do
    Enum.map(children, fn child -> Supervisor.child_spec(child, []).id end)
  end

  test "the application is running and its top supervisor is alive" do
    assert Process.whereis(@supervisor) |> is_pid()
  end

  test "the host test application leaves the global Upstream.Config name available" do
    assert {UpstreamConfig, pid, :worker, [UpstreamConfig]} = child(UpstreamConfig)
    assert is_pid(pid)
    refute Process.whereis(UpstreamConfig)
  end

  test "SessionHolder is supervised, alive, and idle (no live session) on host" do
    assert {SessionHolder, pid, :worker, [SessionHolder]} = child(SessionHolder)
    assert is_pid(pid)
    assert Process.alive?(pid)

    # Idle: no session has been published (no ChannelClient on host to publish one).
    refute SessionHolder.live?()
    assert {:error, :no_session} = SessionHolder.get_current_session()
    assert {:error, :no_session} = SessionHolder.take_send_counter()
  end

  test "the wind-shift Config + Observer are supervised, alive, and idle on host" do
    alias RacingOrg.Tracker.Pro.WindShift

    # The policy config runs in EVERY environment (the channel reads it); with no
    # persisted/pushed config it reports the safe defaults.
    assert {WindShift.Config, config_pid, :worker, [WindShift.Config]} = child(WindShift.Config)
    assert Process.alive?(config_pid)
    assert WindShift.Config.applied_version() == nil
    assert %{wally_mode: "off", status: "ok"} = WindShift.Config.status()

    # The Observer ticks off the compute engine; with no wind on host it stays
    # idle (its stats are readable and its session is unstarted or in-memory only).
    assert {WindShift.Observer, observer_pid, :worker, [WindShift.Observer]} = child(WindShift.Observer)
    assert Process.alive?(observer_pid)
    assert %{samples: _, accepted: _, rejected: _, reject_reasons: %{}} = WindShift.Observer.stats()

    # Config starts BEFORE the Observer (the Observer subscribes/reads it in init).
    ids = child_ids()
    config_index = Enum.find_index(ids, &(&1 == WindShift.Config))
    observer_index = Enum.find_index(ids, &(&1 == WindShift.Observer))
    # which_children returns children in REVERSE start order.
    assert observer_index < config_index
  end

  test "the WSS ChannelClient is NOT started on host (target + pinned-key gated)" do
    refute ChannelClient in child_ids()
    refute Process.whereis(ChannelClient)
  end

  test "the boot claim provisioner is NOT started on host (target + pinned-key gated)" do
    refute RacingOrg.Tracker.Pro.SecureTransport.BootProvisioner in child_ids()
    refute Process.whereis(RacingOrg.Tracker.Pro.SecureTransport.BootProvisioner)
  end

  test "the BulkUploader GenServer is NOT started on host (target + pinned-key gated)" do
    refute RacingOrg.Tracker.Pro.Race.BulkUploader in child_ids()
  end

  test "the desired-state runtime is not started on host" do
    ids = child_ids()

    refute RuntimeIdentity in ids
    refute Root in ids
    refute Store in ids
    refute AuthorityRegistry in ids
    refute OperationalGate in ids
    refute Applier in ids
    refute Manager in ids
    refute CommandExecutor in ids
    refute OutboxOwner in ids
  end

  describe "secure_transport_configured?/1 gate predicate" do
    setup do
      prev = Application.get_env(:racing_org_tracker_pro, ServerIdentity)

      on_exit(fn ->
        case prev do
          nil -> Application.delete_env(:racing_org_tracker_pro, ServerIdentity)
          value -> Application.put_env(:racing_org_tracker_pro, ServerIdentity, value)
        end
      end)

      :ok
    end

    test "host target is never configured, even with a pinned key set" do
      Application.put_env(:racing_org_tracker_pro, ServerIdentity, public_key: :crypto.strong_rand_bytes(32))

      refute RacingOrg.Tracker.Pro.Application.secure_transport_configured?(:host)
      refute RacingOrg.Tracker.Pro.Application.secure_transport_configured?(:"")
      refute RacingOrg.Tracker.Pro.Application.secure_transport_configured?(nil)
    end

    test "a real target with NO pinned key is not configured" do
      Application.delete_env(:racing_org_tracker_pro, ServerIdentity)
      refute RacingOrg.Tracker.Pro.Application.secure_transport_configured?(:racing_org_rpi3)
    end

    test "a real target WITH a pinned key is configured" do
      Application.put_env(:racing_org_tracker_pro, ServerIdentity, public_key: :crypto.strong_rand_bytes(32))

      assert RacingOrg.Tracker.Pro.Application.secure_transport_configured?(:racing_org_rpi3)
    end

    test "logger shares one private controller capability between the gate and manager" do
      Application.put_env(:racing_org_tracker_pro, ServerIdentity, public_key: :crypto.strong_rand_bytes(32))

      specs =
        :logger
        |> RacingOrg.Tracker.Pro.Application.child_specs(:racing_org_rpi3)
        |> Enum.map(&Supervisor.child_spec(&1, []))

      gate_spec = Enum.find(specs, &(&1.id == OperationalGate))
      manager_spec = Enum.find(specs, &(&1.id == Manager))

      assert {OperationalGate, :start_link, [gate_opts]} = gate_spec.start

      assert {RacingOrg.Tracker.Pro.DesiredState.Runtime, :start_manager, [manager_opts]} =
               manager_spec.start

      gate_capability = Keyword.fetch!(gate_opts, :controller_capability)
      manager_capability = Keyword.fetch!(manager_opts, :controller_capability)

      assert is_reference(gate_capability)
      assert manager_capability == gate_capability
      assert Keyword.fetch!(manager_opts, :checkpoint_hydration_startup_barrier)
    end

    test "logger starts the complete desired-state runtime before channel traffic" do
      Application.put_env(:racing_org_tracker_pro, ServerIdentity, public_key: :crypto.strong_rand_bytes(32))

      ids =
        :logger
        |> RacingOrg.Tracker.Pro.Application.child_specs(:racing_org_rpi3)
        |> spec_ids()

      ordered_ids = [
        SessionHolder,
        RuntimeIdentity,
        Root,
        Store,
        AuthorityRegistry,
        Applier,
        BootProvisioner,
        Manager,
        OperationalGate,
        CommandExecutor,
        OutboxOwner,
        ChannelClient,
        BulkUploader
      ]

      indices =
        Enum.map(ordered_ids, fn expected ->
          Enum.find_index(ids, &(&1 == expected))
        end)

      assert Enum.all?(indices, &is_integer/1)
      assert indices == Enum.sort(indices)
    end

    test "the command executor is bound to the persistent storage-epoch root, never boot_id" do
      Application.put_env(:racing_org_tracker_pro, ServerIdentity, public_key: :crypto.strong_rand_bytes(32))

      specs =
        :logger
        |> RacingOrg.Tracker.Pro.Application.child_specs(:racing_org_rpi3)
        |> Enum.map(&Supervisor.child_spec(&1, []))

      executor_spec = Enum.find(specs, &(&1.id == CommandExecutor))
      assert {CommandExecutor, :start_link, [opts]} = executor_spec.start
      assert executor_spec.restart == :permanent

      # The ledger path is derived from configuration, not from a transient boot
      # incarnation, so a reboot reopens the SAME durable ledger. Identity is
      # resolved at init from the verified authority rather than baked into the
      # child spec.
      path = Keyword.fetch!(opts, :path)
      assert is_binary(path)
      refute String.contains?(path, "boot")
      assert Keyword.fetch!(opts, :providers) == RacingOrg.Tracker.Pro.Commands.Ledger.Registry.recovery_verifiers()
      refute Keyword.has_key?(opts, :boot_id)
    end

    test "a relative command-ledger override stays inside persistent desired-state storage" do
      Application.put_env(:racing_org_tracker_pro, ServerIdentity, public_key: :crypto.strong_rand_bytes(32))
      previous = Application.get_env(:racing_org_tracker_pro, :command_ledger_path)
      Application.put_env(:racing_org_tracker_pro, :command_ledger_path, "custom/commands.ledger")

      on_exit(fn ->
        case previous do
          nil -> Application.delete_env(:racing_org_tracker_pro, :command_ledger_path)
          value -> Application.put_env(:racing_org_tracker_pro, :command_ledger_path, value)
        end
      end)

      specs =
        :logger
        |> RacingOrg.Tracker.Pro.Application.child_specs(:racing_org_rpi3)
        |> Enum.map(&Supervisor.child_spec(&1, []))

      executor_spec = Enum.find(specs, &(&1.id == CommandExecutor))
      assert {CommandExecutor, :start_link, [opts]} = executor_spec.start

      expected =
        RuntimeIdentity.storage_epoch_path()
        |> Path.dirname()
        |> Path.join("custom/commands.ledger")

      assert Keyword.fetch!(opts, :path) == expected
      assert Path.type(Keyword.fetch!(opts, :path)) == :absolute
    end

    test "the durable outbox is bound to persistent storage and starts before receipt dispatch" do
      Application.put_env(:racing_org_tracker_pro, ServerIdentity, public_key: :crypto.strong_rand_bytes(32))

      specs =
        :logger
        |> RacingOrg.Tracker.Pro.Application.child_specs(:racing_org_rpi3)
        |> Enum.map(&Supervisor.child_spec(&1, []))

      outbox_spec = Enum.find(specs, &(&1.id == OutboxOwner))
      assert {OutboxOwner, :start_link, [opts]} = outbox_spec.start
      assert outbox_spec.restart == :permanent
      assert Keyword.fetch!(opts, :name) == OutboxOwner

      root = Keyword.fetch!(opts, :root)
      assert Path.type(root) == :absolute
      refute String.contains?(root, "boot")
      assert is_function(Keyword.fetch!(opts, :identity), 0)

      ids = spec_ids(specs)
      assert Enum.find_index(ids, &(&1 == CommandExecutor)) < Enum.find_index(ids, &(&1 == OutboxOwner))
      assert Enum.find_index(ids, &(&1 == OutboxOwner)) < Enum.find_index(ids, &(&1 == ChannelClient))
    end

    test "the command executor starts before the channel that routes deliveries into it" do
      Application.put_env(:racing_org_tracker_pro, ServerIdentity, public_key: :crypto.strong_rand_bytes(32))

      ids =
        :logger
        |> RacingOrg.Tracker.Pro.Application.child_specs(:racing_org_rpi3)
        |> spec_ids()

      assert Enum.find_index(ids, &(&1 == CommandExecutor)) <
               Enum.find_index(ids, &(&1 == ChannelClient))
    end

    test "logger starts the durable legacy spool migration after the Outbox" do
      Application.put_env(:racing_org_tracker_pro, ServerIdentity, public_key: :crypto.strong_rand_bytes(32))

      specs =
        :logger
        |> RacingOrg.Tracker.Pro.Application.child_specs(:racing_org_rpi3)
        |> Enum.map(&Supervisor.child_spec(&1, []))

      ids = spec_ids(specs)
      assert Enum.find_index(ids, &(&1 == DataSetRecorder)) < Enum.find_index(ids, &(&1 == DataSetUploader))
      assert Enum.find_index(ids, &(&1 == OutboxOwner)) < Enum.find_index(ids, &(&1 == DataSetUploader))

      uploader_spec = Enum.find(specs, &(&1.id == DataSetUploader))
      assert {DataSetUploader, :start_link, [uploader_opts]} = uploader_spec.start
      assert Keyword.fetch!(uploader_opts, :delivery) == :durable
      assert Keyword.fetch!(uploader_opts, :outbox) == OutboxOwner
      refute Keyword.has_key?(uploader_opts, :via)
    end

    test "uplink retains legacy UDP DataSet delivery because it has no Outbox owner" do
      Application.put_env(:racing_org_tracker_pro, ServerIdentity, public_key: :crypto.strong_rand_bytes(32))

      specs =
        :uplink
        |> RacingOrg.Tracker.Pro.Application.child_specs(:racing_org_rpi3)
        |> Enum.map(&Supervisor.child_spec(&1, []))

      uploader_spec = Enum.find(specs, &(&1.id == DataSetUploader))
      assert {DataSetUploader, :start_link, [uploader_opts]} = uploader_spec.start
      assert Keyword.fetch!(uploader_opts, :delivery) == :legacy
      assert Keyword.fetch!(uploader_opts, :via) == :udp
      refute Keyword.has_key?(uploader_opts, :outbox)
    end

    test "uplink does not start the logger-only desired-state runtime" do
      Application.put_env(:racing_org_tracker_pro, ServerIdentity, public_key: :crypto.strong_rand_bytes(32))

      ids =
        :uplink
        |> RacingOrg.Tracker.Pro.Application.child_specs(:racing_org_rpi3)
        |> spec_ids()

      assert SessionHolder in ids
      assert BootProvisioner in ids
      assert ChannelClient in ids

      refute RuntimeIdentity in ids
      refute Root in ids
      refute Store in ids
      refute AuthorityRegistry in ids
      refute OperationalGate in ids
      refute Applier in ids
      refute Manager in ids
      refute CommandExecutor in ids
      refute OutboxOwner in ids
    end
  end

  test "ChannelClient is not connectable on host (so it would stay idle if started)" do
    base = Path.join(System.tmp_dir!(), "app_test_cc_#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf(base) end)

    # Host target + unclaimed + no pinned server key -> not connectable.
    refute ChannelClient.connectable?(keystore_opts: [base_path: base])
  end

  test "a directly-started ChannelClient stays idle on host and does not crash" do
    base = Path.join(System.tmp_dir!(), "app_test_idle_#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf(base) end)

    pid =
      start_supervised!({ChannelClient, name: nil, auto_connect?: false, keystore_opts: [base_path: base]})

    assert Process.alive?(pid)
    Process.sleep(50)
    assert Process.alive?(pid)
  end

  test "the secure-transport children carry correct child specs" do
    # SessionHolder spec (the only secure child started on host).
    assert {SessionHolder, _pid, :worker, [SessionHolder]} = child(SessionHolder)

    # ChannelClient exposes a permanent worker spec (used on target).
    cc_spec = ChannelClient.child_spec([])
    assert cc_spec.id == ChannelClient
    assert cc_spec.type == :worker
    assert cc_spec.restart == :permanent
    assert {ChannelClient, :start_link, [[]]} = cc_spec.start

    # BootProvisioner is a transient coordinator (normal terminal stop is not restarted).
    bp_spec = RacingOrg.Tracker.Pro.SecureTransport.BootProvisioner.child_spec([])
    assert bp_spec.id == RacingOrg.Tracker.Pro.SecureTransport.BootProvisioner
    assert bp_spec.restart == :transient
  end
end
