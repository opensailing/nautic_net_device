defmodule RacingOrg.Tracker.Pro.Commands.Ledger.StoreReentryTest do
  use ExUnit.Case, async: false

  test "an admission callback cannot re-enter the same ledger path" do
    root = Path.join(System.tmp_dir!(), "command_ledger_reentry_#{System.unique_integer([:positive])}")
    script = Path.join(root, "reentry.exs")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    File.write!(script, reentry_script(Path.join(root, "ledger.snapshot")))

    {output, status} =
      System.cmd("mix", ["run", "--no-compile", "--no-start", script],
        cd: File.cwd!(),
        env: [
          {"API_ENDPOINT", Application.fetch_env!(:racing_org_tracker_pro, :api_endpoint)},
          {"UDP_ENDPOINT", Application.fetch_env!(:racing_org_tracker_pro, :udp_endpoint)},
          {"PRODUCT", to_string(Application.fetch_env!(:racing_org_tracker_pro, :product))},
          {"MIX_ENV", "test"}
        ],
        stderr_to_stdout: true
      )

    assert status == 0, "re-entrant ledger process exited with #{status}: #{output}"
  end

  defp reentry_script(path) do
    """
    alias RacingOrg.Tracker.Pro.Commands.Ledger.Provider.Noop
    alias RacingOrg.Tracker.Pro.Commands.Ledger.Store
    alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.Command

    defmodule ReentrantAdmissionAuthority do
      def authorize(plan, _snapshot, _limits, context) do
        context
        |> Agent.get(& &1)
        |> Store.begin_intent(plan)
      end
    end

    device_id = <<0x11::128>>
    storage_epoch = <<0x22::128>>
    manifest_hash = :binary.copy(<<0x33>>, 32)
    payload = "noop"
    payload_hash = :crypto.hash(:sha256, payload)

    attrs = %{
      device_id: device_id,
      credential_epoch: 7,
      storage_epoch: storage_epoch,
      required_generation: 42,
      required_manifest_hash: manifest_hash,
      command_epoch: 0,
      command_sequence: 1,
      command_id: <<0x44::128>>,
      expires_at_ms: 1_800_000_000_000,
      payload_hash: payload_hash
    }

    {:ok, command_hash} = Command.hash(attrs)
    delivery = attrs |> Map.put(:command_hash, command_hash) |> Map.put(:payload, payload)

    plan = %{
      action: :execute,
      delivery: delivery,
      command_type: :noop,
      reserved_result_bytes: 16,
      reset_epoch?: false
    }

    {:ok, context} = Agent.start_link(fn -> nil end)

    {:ok, store} =
      Store.open(#{inspect(path)},
        device_id: device_id,
        credential_epoch: 7,
        storage_epoch: storage_epoch,
        max_outcomes: 8,
        max_result_bytes: 1_024,
        admission_authority: {ReentrantAdmissionAuthority, context},
        recovery_verifiers: %{noop: {Noop, nil}}
      )

    Agent.update(context, fn _old -> store end)
    task = Task.async(fn -> Store.begin_intent(store, plan) end)

    case Task.yield(task, 500) do
      {:ok, {:error, :command_ledger_path_reentry}} ->
        System.halt(0)

      {:ok, other} ->
        IO.puts("unexpected result: " <> inspect(other))
        System.halt(2)

      nil ->
        IO.puts("same-path admission callback deadlocked")
        System.halt(3)
    end
    """
  end
end
