defmodule RacingOrg.Tracker.Pro.FirmwareValidation.DiagnosticsStoreTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.FirmwareValidation.DiagnosticsStore

  @git_sha String.duplicate("b", 40)
  @fault_stages [
    :temp_opened,
    :temp_chmodded,
    :temp_written,
    :temp_synced,
    :temp_closed,
    :before_rename,
    :renamed,
    :parent_synced
  ]

  setup do
    dir = Path.join(System.tmp_dir!(), "firmware_diagnostics_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  test "round-trips only the closed sanitized diagnostic record", %{dir: dir} do
    record = pending_record()

    assert :ok = DiagnosticsStore.save(dir, record)
    assert {:ok, ^record} = DiagnosticsStore.load(dir)

    assert {:ok, durable_bytes} = File.read(DiagnosticsStore.path(dir))
    refute durable_bytes =~ "snapshot-secret"
    refute durable_bytes =~ "session-key"
    refute durable_bytes =~ inspect(self())

    decoded = :erlang.binary_to_term(durable_bytes, [:safe])
    assert {1, ^record} = decoded
    refute Map.has_key?(record.target, :deadline_at_ms)

    assert {:ok, stat} = File.stat(DiagnosticsStore.path(dir))
    assert Bitwise.band(stat.mode, 0o777) == 0o600
    assert {:ok, dir_stat} = File.stat(dir)
    assert Bitwise.band(dir_stat.mode, 0o777) == 0o700
  end

  test "accepts the closed validation-decided phase only for a ready result", %{dir: dir} do
    decision = %{pending_record() | phase: :validation_decided, result: :ready}

    assert :ok = DiagnosticsStore.save(dir, decision)
    assert {:ok, ^decision} = DiagnosticsStore.load(dir)

    invalid_decision = %{decision | result: pending_record().result}
    assert {:error, :invalid_record} = DiagnosticsStore.save(dir, invalid_decision)
    assert {:ok, ^decision} = DiagnosticsStore.load(dir)
  end

  test "rejects snapshots, pids, session keys, secrets, unknown fields, and nonregistry atoms", %{dir: dir} do
    secret = "snapshot-secret"

    invalid_records = [
      Map.put(pending_record(), :snapshot, %{session: %{out_key: secret}}),
      put_in(pending_record(), [:target, :session_key], "session-key"),
      put_in(pending_record(), [:timing, :timer_pid], self()),
      put_in(
        pending_record(),
        [:result],
        {:pending, [%{criterion: :input, diagnostic_code: :password}]}
      )
    ]

    for invalid <- invalid_records do
      assert {:error, :invalid_record} = DiagnosticsStore.save(dir, invalid)
      assert :empty = DiagnosticsStore.load(dir)
    end
  end

  test "strictly distinguishes absent, corrupt, unrecognized, and unreadable records", %{dir: dir} do
    assert :empty = DiagnosticsStore.load(dir)

    File.mkdir_p!(dir)
    File.write!(DiagnosticsStore.path(dir), "not-an-erlang-term")
    assert {:error, :corrupt} = DiagnosticsStore.load(dir)

    File.write!(DiagnosticsStore.path(dir), :erlang.term_to_binary({99, pending_record()}))
    assert {:error, :unrecognized_format} = DiagnosticsStore.load(dir)

    assert {:error, {:read, :eacces}} =
             DiagnosticsStore.load(dir, file_system: __MODULE__.UnreadableFileSystem)
  end

  test "never treats post-rename visibility as durable diagnostic persistence", %{dir: dir} do
    for stage <- @fault_stages do
      File.rm_rf!(dir)

      opts = [fault_injector: fail_at(stage), temp_suffix: fn -> Atom.to_string(stage) end]
      result = DiagnosticsStore.save(dir, pending_record(), opts)

      case stage do
        :renamed ->
          assert {:error, {:durability_uncertain, {:fault_injected, :renamed, :simulated_power_loss}}} = result
          assert {:ok, record} = DiagnosticsStore.load(dir)
          assert record == pending_record()

        :parent_synced ->
          assert :ok = result
          assert {:ok, record} = DiagnosticsStore.load(dir)
          assert record == pending_record()

        pre_rename_stage ->
          assert {:error, {:pre_rename, {:fault_injected, ^pre_rename_stage, :simulated_power_loss}}} = result

          assert :empty = DiagnosticsStore.load(dir)
      end
    end
  end

  test "clear durably removes a trial record and is idempotent", %{dir: dir} do
    assert :ok = DiagnosticsStore.save(dir, pending_record())
    assert :ok = DiagnosticsStore.clear(dir)
    assert :empty = DiagnosticsStore.load(dir)
    assert :ok = DiagnosticsStore.clear(dir)
  end

  defp pending_record do
    %{
      phase: :monitoring,
      result:
        {:pending,
         [
           %{criterion: :control_receipt_round_trip, diagnostic_code: :control_receipt_incomplete},
           %{criterion: :soak_period, diagnostic_code: :soak_period_incomplete}
         ]},
      timing: %{remaining_deadline_ms: 4_000, healthy_for_ms: 0},
      target: %{
        firmware: %{version: "0.7.0", git_sha: @git_sha},
        credential_epoch: 4,
        desired_generation: 12,
        soak_period_ms: 1_000
      }
    }
  end

  defp fail_at(failed_stage) do
    fn
      ^failed_stage -> {:error, :simulated_power_loss}
      _other -> :ok
    end
  end

  defmodule UnreadableFileSystem do
    @behaviour RacingOrg.Tracker.Pro.SecureTransport.KeyStore.FileSystem

    def read(_path), do: {:error, :eacces}
    def mkdir_p(path), do: File.mkdir_p(path)
    def chmod(path, mode), do: File.chmod(path, mode)
    def open(path, modes), do: File.open(path, modes)
    def write(device, contents), do: :file.write(device, contents)
    def sync(device), do: :file.sync(device)
    def close(device), do: :file.close(device)
    def rename(source, destination), do: File.rename(source, destination)
    def remove(path), do: File.rm(path)
  end
end
