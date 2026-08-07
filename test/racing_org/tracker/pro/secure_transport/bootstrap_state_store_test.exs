defmodule RacingOrg.Tracker.Pro.SecureTransport.BootstrapStateStoreTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.SecureTransport.BootstrapState
  alias RacingOrg.Tracker.Pro.SecureTransport.BootstrapStateStore

  defmodule TracingFileSystem do
    @behaviour RacingOrg.Tracker.Pro.SecureTransport.KeyStore.FileSystem

    alias RacingOrg.Tracker.Pro.SecureTransport.KeyStore.FileSystem, as: FileSystem

    def attach(owner), do: Process.put({__MODULE__, :owner}, owner)

    @impl true
    def read(path) do
      report({:read, path})
      FileSystem.read(path)
    end

    @impl true
    def mkdir_p(path) do
      report({:mkdir_p, path})
      FileSystem.mkdir_p(path)
    end

    @impl true
    def chmod(path, mode) do
      report({:chmod, path, mode})
      FileSystem.chmod(path, mode)
    end

    @impl true
    def open(path, modes) do
      report({:open, path, modes})

      case FileSystem.open(path, modes) do
        {:ok, device} = ok ->
          Process.put({__MODULE__, :path, device}, path)
          ok

        error ->
          error
      end
    end

    @impl true
    def write(device, contents) do
      report({:write, device_path(device), IO.iodata_length(contents)})
      FileSystem.write(device, contents)
    end

    @impl true
    def sync(device) do
      report({:sync, device_path(device)})
      FileSystem.sync(device)
    end

    @impl true
    def close(device) do
      path = device_path(device)
      report({:close, path})
      result = FileSystem.close(device)
      Process.delete({__MODULE__, :path, device})
      result
    end

    @impl true
    def rename(source, destination) do
      report({:rename, source, destination})
      FileSystem.rename(source, destination)
    end

    @impl true
    def remove(path) do
      report({:remove, path})
      FileSystem.remove(path)
    end

    defp device_path(device), do: Process.get({__MODULE__, :path, device})

    defp report(event) do
      if owner = Process.get({__MODULE__, :owner}) do
        send(owner, {:bootstrap_file_system, event})
      end
    end
  end

  setup do
    base = Path.join(System.tmp_dir!(), "bootstrap_state_store_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(base) end)
    %{base: base}
  end

  test "a missing file is the explicit uninitialized state", %{base: base} do
    assert {:ok, %BootstrapState{phase: :uninitialized, retry_count: 0}} =
             BootstrapStateStore.load(base_path: base)
  end

  test "round-trips every exact receipt/transcript byte without JSON re-encoding", %{base: base} do
    registration_receipt = <<0, 255, 1, 2, 3, 0, 128>>
    challenge_receipt = <<9, 0, 8, 0, 7, 0, 6>>
    lifecycle_receipt = <<5, 4, 0, 3, 2, 1, 0, 255>>

    previous_authority = %{
      kind: :registration,
      public_key: bytes(0x11, 32),
      client_nonce: bytes(0x22, 32),
      receipt: registration_receipt,
      logical_device_id: bytes(0x33, 16),
      credential_epoch: 0
    }

    authority = %{
      kind: :recovery,
      public_key: bytes(0x44, 32),
      challenge_client_nonce: bytes(0x55, 32),
      challenge_receipt: challenge_receipt,
      commit_signing_bytes_hash: bytes(0x66, 32),
      lifecycle_receipt: lifecycle_receipt,
      logical_device_id: bytes(0x33, 16),
      credential_epoch: 7
    }

    state = %BootstrapState{
      phase: :committed,
      hardware_identity_digest: bytes(0x77, 32),
      authority: authority,
      previous_authority: previous_authority,
      retry_count: 3
    }

    assert :ok = BootstrapStateStore.save(state, base_path: base)
    assert {:ok, loaded} = BootstrapStateStore.load(base_path: base)
    assert loaded == state
    assert loaded.authority.challenge_receipt === challenge_receipt
    assert loaded.authority.lifecycle_receipt === lifecycle_receipt
    assert loaded.previous_authority.receipt === registration_receipt
  end

  test "uses restrictive creation, file fsync, atomic rename, and directory fsync", %{base: base} do
    TracingFileSystem.attach(self())
    path = BootstrapStateStore.path(base_path: base)
    state = %BootstrapState{phase: :blocked, blocked_reason: :attempt_limit, retry_count: 1}

    assert :ok =
             BootstrapStateStore.save(state,
               base_path: base,
               file_system: TracingFileSystem
             )

    assert_receive {:bootstrap_file_system, {:mkdir_p, ^base}}
    assert_receive {:bootstrap_file_system, {:chmod, ^base, 0o700}}
    assert_receive {:bootstrap_file_system, {:open, temp_path, modes}}
    assert Path.dirname(temp_path) == base
    assert :exclusive in modes
    assert :binary in modes
    assert_receive {:bootstrap_file_system, {:chmod, ^temp_path, 0o600}}
    assert_receive {:bootstrap_file_system, {:write, ^temp_path, size}}
    assert size > 0
    assert_receive {:bootstrap_file_system, {:sync, ^temp_path}}
    assert_receive {:bootstrap_file_system, {:close, ^temp_path}}
    assert_receive {:bootstrap_file_system, {:rename, ^temp_path, ^path}}
    assert_receive {:bootstrap_file_system, {:open, ^base, directory_modes}}
    assert :directory in directory_modes
    assert_receive {:bootstrap_file_system, {:sync, ^base}}
    assert_receive {:bootstrap_file_system, {:close, ^base}}

    assert {:ok, stat} = File.stat(path)
    assert Bitwise.band(stat.mode, 0o777) == 0o600
  end

  test "a fault before rename leaves the previous authoritative bundle byte-identical", %{base: base} do
    first = %BootstrapState{phase: :registered, retry_count: 0}
    second = %BootstrapState{phase: :blocked, blocked_reason: :identity_conflict, retry_count: 1}

    assert :ok = BootstrapStateStore.save(first, base_path: base)
    path = BootstrapStateStore.path(base_path: base)
    before = File.read!(path)

    assert {:error, {:fault_injected, :before_rename, :power_loss}} =
             BootstrapStateStore.save(second,
               base_path: base,
               fault_injector: fail_at(:before_rename)
             )

    assert File.read!(path) === before
    assert {:ok, ^first} = BootstrapStateStore.load(base_path: base)
  end

  test "a fault after rename exposes one complete new state for restart recovery", %{base: base} do
    first = %BootstrapState{phase: :registered}
    second = %BootstrapState{phase: :challenged, retry_count: 2}

    assert :ok = BootstrapStateStore.save(first, base_path: base)

    assert {:error, {:fault_injected, :renamed, :power_loss}} =
             BootstrapStateStore.save(second,
               base_path: base,
               fault_injector: fail_at(:renamed)
             )

    assert {:ok, ^second} = BootstrapStateStore.load(base_path: base)
  end

  test "rejects corrupt, unknown-version, and structurally invalid state", %{base: base} do
    path = BootstrapStateStore.path(base_path: base)
    File.mkdir_p!(base)

    File.write!(path, "not-an-erlang-term")
    assert {:error, :corrupt_state} = BootstrapStateStore.load(base_path: base)

    File.write!(path, :erlang.term_to_binary({999, %BootstrapState{}}))
    assert {:error, :unsupported_state_version} = BootstrapStateStore.load(base_path: base)

    File.write!(path, :erlang.term_to_binary({1, %BootstrapState{phase: :unknown}}))
    assert {:error, :invalid_state} = BootstrapStateStore.load(base_path: base)
  end

  test "durably removes a legacy marker only after a replacement receipt exists", %{base: base} do
    marker = Path.join(base, "register_marker.json")
    File.mkdir_p!(base)
    File.write!(marker, ~s({"device_id":"legacy"}))

    assert :ok = BootstrapStateStore.remove_legacy_marker(base_path: base)
    refute File.exists?(marker)
    assert :ok = BootstrapStateStore.remove_legacy_marker(base_path: base)
  end

  defp bytes(byte, count), do: :binary.copy(<<byte>>, count)

  defp fail_at(stage) do
    fn
      ^stage -> {:error, :power_loss}
      _other -> :ok
    end
  end
end
