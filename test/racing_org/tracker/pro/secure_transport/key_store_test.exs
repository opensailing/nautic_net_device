defmodule RacingOrg.Tracker.Pro.SecureTransport.KeyStoreTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.SecureTransport.IdentityProvider
  alias RacingOrg.Tracker.Pro.SecureTransport.KeyStore
  alias RacingOrg.Tracker.Pro.SecureTransport.Primitives

  @active_seed :binary.copy(<<0x11>>, 32)
  @candidate_seed :binary.copy(<<0x22>>, 32)

  defmodule TracingFileSystem do
    @behaviour KeyStore.FileSystem

    alias RacingOrg.Tracker.Pro.SecureTransport.KeyStore.FileSystem, as: RealFileSystem

    def attach(owner), do: Process.put({__MODULE__, :owner}, owner)

    @impl true
    def read(path) do
      report({:read, path})
      RealFileSystem.read(path)
    end

    @impl true
    def mkdir_p(path) do
      report({:mkdir_p, path})
      RealFileSystem.mkdir_p(path)
    end

    @impl true
    def chmod(path, mode) do
      report({:chmod, path, mode})
      RealFileSystem.chmod(path, mode)
    end

    @impl true
    def open(path, modes) do
      report({:open, path, modes})

      case RealFileSystem.open(path, modes) do
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
      RealFileSystem.write(device, contents)
    end

    @impl true
    def sync(device) do
      report({:sync, device_path(device)})
      RealFileSystem.sync(device)
    end

    @impl true
    def close(device) do
      path = device_path(device)
      report({:close, path})
      result = RealFileSystem.close(device)
      Process.delete({__MODULE__, :path, device})
      result
    end

    @impl true
    def rename(source, destination) do
      report({:rename, source, destination})
      RealFileSystem.rename(source, destination)
    end

    @impl true
    def remove(path) do
      report({:remove, path})
      RealFileSystem.remove(path)
    end

    defp device_path(device), do: Process.get({__MODULE__, :path, device})

    defp report(event) do
      if owner = Process.get({__MODULE__, :owner}) do
        send(owner, {:file_system, event})
      end
    end
  end

  setup do
    base = Path.join(System.tmp_dir!(), "nn_keystore_test_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(base) end)
    {:ok, base: base}
  end

  describe "active identity" do
    test "generates, persists, and reloads one operational identity without exposing the seed", %{base: base} do
      refute File.exists?(KeyStore.key_path(base_path: base))

      assert {:ok, first} = load_or_generate(base, @active_seed)
      assert {:ok, second} = KeyStore.load(base_path: base)

      assert IdentityProvider.public_key(first) == Primitives.ed25519_public_from_secret(@active_seed)
      assert IdentityProvider.public_key(second) == IdentityProvider.public_key(first)
      assert IdentityProvider.fingerprint(second) == IdentityProvider.fingerprint(first)
      refute Map.has_key?(Map.from_struct(first), :private_key)
      refute first.provider_state == @active_seed
      refute inspect(first) =~ inspect(@active_seed)
      assert File.read!(KeyStore.key_path(base_path: base)) == @active_seed
    end

    test "signs through the provider facade and survives reload", %{base: base} do
      assert {:ok, identity} = load_or_generate(base, @active_seed)
      assert {:ok, reloaded} = KeyStore.load(base_path: base)

      assert {:ok, signature} = IdentityProvider.sign(reloaded, "device-identity-roundtrip")

      assert Primitives.ed25519_verify(
               IdentityProvider.public_key(identity),
               "device-identity-roundtrip",
               signature
             )
    end

    test "an operational signer refuses to use a seed replaced behind its cached public identity", %{base: base} do
      assert {:ok, identity} = load_or_generate(base, @active_seed)
      File.write!(KeyStore.key_path(base_path: base), @candidate_seed)

      assert {:error, :identity_seed_mismatch} = IdentityProvider.sign(identity, "stale-identity")
    end

    test "writes the directory as 0700 and active seed as 0600", %{base: base} do
      assert {:ok, _identity} = load_or_generate(base, @active_seed)

      assert {:ok, dir_stat} = File.stat(base)
      assert {:ok, key_stat} = File.stat(KeyStore.key_path(base_path: base))
      assert Bitwise.band(dir_stat.mode, 0o777) == 0o700
      assert Bitwise.band(key_stat.mode, 0o777) == 0o600
    end

    test "rejects a corrupt active seed instead of regenerating over it", %{base: base} do
      File.mkdir_p!(base)
      File.write!(KeyStore.key_path(base_path: base), <<1, 2, 3>>)

      assert {:error, :corrupt_seed} = load_or_generate(base, @active_seed)
      assert File.read!(KeyStore.key_path(base_path: base)) == <<1, 2, 3>>
    end

    test "returns not_provisioned when no active identity exists", %{base: base} do
      assert {:error, :not_provisioned} = KeyStore.load(base_path: base)
    end
  end

  describe "staged candidate identity" do
    test "stages a distinct durable candidate without replacing the active key", %{base: base} do
      assert {:ok, active} = load_or_generate(base, @active_seed)
      assert {:ok, candidate} = stage_candidate(base, @candidate_seed)

      assert File.read!(KeyStore.key_path(base_path: base)) == @active_seed
      assert File.read!(KeyStore.candidate_key_path(base_path: base)) == @candidate_seed
      assert IdentityProvider.public_key(active) != IdentityProvider.public_key(candidate)
      assert {:ok, still_active} = KeyStore.load(base_path: base)
      assert IdentityProvider.public_key(still_active) == IdentityProvider.public_key(active)

      assert {:ok, candidate_stat} = File.stat(KeyStore.candidate_key_path(base_path: base))
      assert Bitwise.band(candidate_stat.mode, 0o777) == 0o600
    end

    test "reuses an already-staged candidate across recovery retries", %{base: base} do
      assert {:ok, _active} = load_or_generate(base, @active_seed)
      assert {:ok, first} = stage_candidate(base, @candidate_seed)

      other_seed = :binary.copy(<<0x33>>, 32)
      assert {:ok, second} = stage_candidate(base, other_seed)

      assert IdentityProvider.public_key(second) == IdentityProvider.public_key(first)
      assert File.read!(KeyStore.candidate_key_path(base_path: base)) == @candidate_seed
      assert File.read!(KeyStore.key_path(base_path: base)) == @active_seed
    end

    test "promotes only the staged candidate and returns the new active signer", %{base: base} do
      assert {:ok, _active} = load_or_generate(base, @active_seed)
      assert {:ok, candidate} = stage_candidate(base, @candidate_seed)

      assert {:ok, promoted} = KeyStore.promote_candidate(base_path: base)

      assert IdentityProvider.public_key(promoted) == IdentityProvider.public_key(candidate)
      assert File.read!(KeyStore.key_path(base_path: base)) == @candidate_seed
      refute File.exists?(KeyStore.candidate_key_path(base_path: base))
      assert {:ok, reloaded} = KeyStore.load(base_path: base)
      assert IdentityProvider.public_key(reloaded) == IdentityProvider.public_key(candidate)
    end

    test "discarding a staged candidate preserves the last active signer", %{base: base} do
      assert {:ok, active} = load_or_generate(base, @active_seed)
      assert {:ok, _candidate} = stage_candidate(base, @candidate_seed)

      assert :ok = KeyStore.discard_candidate(base_path: base)
      refute File.exists?(KeyStore.candidate_key_path(base_path: base))
      assert File.read!(KeyStore.key_path(base_path: base)) == @active_seed
      assert {:ok, reloaded} = KeyStore.load(base_path: base)
      assert IdentityProvider.public_key(reloaded) == IdentityProvider.public_key(active)
    end

    test "does not promote when no complete candidate is staged", %{base: base} do
      assert {:ok, _active} = load_or_generate(base, @active_seed)
      assert {:error, :candidate_not_staged} = KeyStore.promote_candidate(base_path: base)

      File.write!(KeyStore.candidate_key_path(base_path: base), <<1, 2, 3>>)
      assert {:error, :corrupt_seed} = KeyStore.promote_candidate(base_path: base)
      assert File.read!(KeyStore.key_path(base_path: base)) == @active_seed
    end
  end

  describe "durable atomic writes" do
    test "orders restrictive creation, file fsync, rename, and parent-directory fsync", %{base: base} do
      TracingFileSystem.attach(self())
      key_path = KeyStore.key_path(base_path: base)

      assert {:ok, _identity} =
               KeyStore.load_or_generate(
                 base_path: base,
                 seed_generator: fn -> @active_seed end,
                 file_system: TracingFileSystem
               )

      assert_receive {:file_system, {:read, ^key_path}}
      assert_receive {:file_system, {:mkdir_p, ^base}}
      assert_receive {:file_system, {:chmod, ^base, 0o700}}
      assert_receive {:file_system, {:open, temp_path, temp_modes}}
      assert Path.dirname(temp_path) == base
      assert String.starts_with?(Path.basename(temp_path), Path.basename(key_path) <> ".tmp.")
      assert :write in temp_modes
      assert :binary in temp_modes
      assert :raw in temp_modes
      assert :exclusive in temp_modes
      assert_receive {:file_system, {:chmod, ^temp_path, 0o600}}
      assert_receive {:file_system, {:write, ^temp_path, 32}}
      assert_receive {:file_system, {:sync, ^temp_path}}
      assert_receive {:file_system, {:close, ^temp_path}}
      assert_receive {:file_system, {:rename, ^temp_path, ^key_path}}
      assert_receive {:file_system, {:open, ^base, directory_modes}}
      assert :read in directory_modes
      assert :raw in directory_modes
      assert :directory in directory_modes
      assert_receive {:file_system, {:sync, ^base}}
      assert_receive {:file_system, {:close, ^base}}
      refute_receive {:file_system, _}
    end

    for stage <- [:temp_opened, :temp_chmodded, :temp_written, :temp_synced, :temp_closed, :before_rename] do
      @stage stage
      test "candidate interruption at #{@stage} leaves the active seed byte-identical", %{base: base} do
        assert {:ok, active} = load_or_generate(base, @active_seed)

        assert {:error, {:fault_injected, @stage, :power_loss}} =
                 KeyStore.stage_candidate(
                   base_path: base,
                   seed_generator: fn -> @candidate_seed end,
                   fault_injector: fail_at(@stage)
                 )

        assert File.read!(KeyStore.key_path(base_path: base)) == @active_seed
        assert {:ok, reloaded} = KeyStore.load(base_path: base)
        assert IdentityProvider.public_key(reloaded) == IdentityProvider.public_key(active)
        refute File.exists?(KeyStore.candidate_key_path(base_path: base))
      end
    end

    test "interruption after candidate rename leaves a complete candidate and the old active key", %{base: base} do
      assert {:ok, active} = load_or_generate(base, @active_seed)

      assert {:error, {:fault_injected, :renamed, :power_loss}} =
               KeyStore.stage_candidate(
                 base_path: base,
                 seed_generator: fn -> @candidate_seed end,
                 fault_injector: fail_at(:renamed)
               )

      assert File.read!(KeyStore.key_path(base_path: base)) == @active_seed
      assert File.read!(KeyStore.candidate_key_path(base_path: base)) == @candidate_seed
      assert {:ok, reloaded} = KeyStore.load(base_path: base)
      assert IdentityProvider.public_key(reloaded) == IdentityProvider.public_key(active)
      assert {:ok, _candidate} = KeyStore.load_candidate(base_path: base)
    end

    test "promotion interruption is atomic: before rename keeps old, after rename exposes complete new", %{base: base} do
      assert {:ok, _active} = load_or_generate(base, @active_seed)
      assert {:ok, _candidate} = stage_candidate(base, @candidate_seed)

      assert {:error, {:fault_injected, :before_rename, :power_loss}} =
               KeyStore.promote_candidate(base_path: base, fault_injector: fail_at(:before_rename))

      assert File.read!(KeyStore.key_path(base_path: base)) == @active_seed
      assert File.read!(KeyStore.candidate_key_path(base_path: base)) == @candidate_seed

      assert {:error, {:fault_injected, :renamed, :power_loss}} =
               KeyStore.promote_candidate(base_path: base, fault_injector: fail_at(:renamed))

      assert File.read!(KeyStore.key_path(base_path: base)) == @candidate_seed
      refute File.exists?(KeyStore.candidate_key_path(base_path: base))
      assert {:ok, promoted_after_restart} = KeyStore.load(base_path: base)

      assert IdentityProvider.public_key(promoted_after_restart) ==
               Primitives.ed25519_public_from_secret(@candidate_seed)
    end

    test "orphaned partial temp files are never interpreted as active or candidate keys", %{base: base} do
      assert {:ok, active} = load_or_generate(base, @active_seed)
      File.write!(KeyStore.key_path(base_path: base) <> ".tmp.torn", <<1, 2, 3>>)
      File.write!(KeyStore.candidate_key_path(base_path: base) <> ".tmp.torn", <<4, 5, 6>>)

      assert {:ok, reloaded} = KeyStore.load(base_path: base)
      assert {:error, :candidate_not_staged} = KeyStore.load_candidate(base_path: base)
      assert IdentityProvider.public_key(reloaded) == IdentityProvider.public_key(active)
    end
  end

  describe "fingerprint/1" do
    test "matches the server lowercase-hex SHA-256 rule for a known key" do
      public_key = :binary.copy(<<0x42>>, 32)
      server_rule = Base.encode16(:crypto.hash(:sha256, public_key), case: :lower)

      assert KeyStore.fingerprint(public_key) == server_rule
      assert String.length(server_rule) == 64
    end
  end

  defp load_or_generate(base, seed) do
    KeyStore.load_or_generate(base_path: base, seed_generator: fn -> seed end)
  end

  defp stage_candidate(base, seed) do
    KeyStore.stage_candidate(base_path: base, seed_generator: fn -> seed end)
  end

  defp fail_at(stage) do
    fn
      ^stage -> {:error, :power_loss}
      _other -> :ok
    end
  end
end
