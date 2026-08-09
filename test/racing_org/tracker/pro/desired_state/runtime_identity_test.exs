defmodule RacingOrg.Tracker.Pro.DesiredState.RuntimeIdentityTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.DesiredState.RuntimeIdentity
  alias RacingOrg.Tracker.Pro.SecureTransport.KeyStore.FileSystem, as: RealFileSystem

  defmodule TracingFileSystem do
    @behaviour RealFileSystem

    def attach(owner), do: :persistent_term.put({__MODULE__, :owner}, owner)
    def detach, do: :persistent_term.erase({__MODULE__, :owner})

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
      if owner = :persistent_term.get({__MODULE__, :owner}, nil),
        do: send(owner, {:file_system, event})
    end
  end

  setup do
    base = Path.join(System.tmp_dir!(), "desired_identity_#{System.unique_integer([:positive])}")
    boot_term_key = {__MODULE__, make_ref()}
    previous_trap_exit = Process.flag(:trap_exit, true)

    on_exit(fn ->
      File.rm_rf(base)
      :persistent_term.erase(boot_term_key)
      TracingFileSystem.detach()
      Process.flag(:trap_exit, previous_trap_exit)
    end)

    %{base: base, boot_term_key: boot_term_key}
  end

  test "creates nonzero boot and storage incarnation IDs through injected entropy", ctx do
    entropy = sequence_entropy([<<0x11::128>>, <<0x22::128>>])

    pid = start_identity(ctx, entropy: entropy)

    assert RuntimeIdentity.readiness(pid) == %{
             boot_id: <<0x11::128>>,
             storage_epoch: <<0x22::128>>
           }

    assert RuntimeIdentity.boot_id(pid) == <<0x11::128>>
    assert RuntimeIdentity.storage_epoch(pid) == <<0x22::128>>
    refute RuntimeIdentity.boot_id(pid) == <<0::128>>
    refute RuntimeIdentity.storage_epoch(pid) == <<0::128>>
  end

  test "keeps boot_id for the BEAM incarnation and storage_epoch across process restart", ctx do
    first = start_identity(ctx, entropy: sequence_entropy([<<0x31::128>>, <<0x41::128>>]))
    first_identity = RuntimeIdentity.readiness(first)
    GenServer.stop(first)

    second = start_identity(ctx, entropy: fn _ -> flunk("restart must not draw entropy") end)

    assert RuntimeIdentity.readiness(second) == first_identity
  end

  test "uses a fresh boot_id for a simulated BEAM boot while retaining durable storage_epoch", ctx do
    first = start_identity(ctx, entropy: sequence_entropy([<<0x51::128>>, <<0x61::128>>]))
    first_identity = RuntimeIdentity.readiness(first)
    GenServer.stop(first)

    next_boot_key = {__MODULE__, make_ref()}
    on_exit(fn -> :persistent_term.erase(next_boot_key) end)

    second =
      start_identity(%{ctx | boot_term_key: next_boot_key},
        entropy: sequence_entropy([<<0x71::128>>])
      )

    assert RuntimeIdentity.boot_id(second) == <<0x71::128>>
    assert RuntimeIdentity.storage_epoch(second) == first_identity.storage_epoch
  end

  test "regenerates storage_epoch only after complete desired-state storage loss", ctx do
    first = start_identity(ctx, entropy: sequence_entropy([<<0x12::128>>, <<0x13::128>>]))
    first_identity = RuntimeIdentity.readiness(first)
    GenServer.stop(first)

    File.rm_rf!(ctx.base)

    next_boot_key = {__MODULE__, make_ref()}
    on_exit(fn -> :persistent_term.erase(next_boot_key) end)

    second =
      start_identity(%{ctx | boot_term_key: next_boot_key},
        entropy: sequence_entropy([<<0x14::128>>, <<0x15::128>>])
      )

    assert RuntimeIdentity.boot_id(second) == <<0x14::128>>
    assert RuntimeIdentity.storage_epoch(second) == <<0x15::128>>
    refute RuntimeIdentity.storage_epoch(second) == first_identity.storage_epoch
  end

  test "fails closed when storage_epoch alone is lost from a populated root", ctx do
    first = start_identity(ctx, entropy: sequence_entropy([<<0x16::128>>, <<0x17::128>>]))
    GenServer.stop(first)

    artifact = Path.join(ctx.base, "active_generation")
    temporary_artifact = Path.join(ctx.base, "active_generation.tmp.interrupted")
    File.write!(artifact, "surviving-authority")
    File.write!(temporary_artifact, "surviving-temp")
    File.rm!(RuntimeIdentity.storage_epoch_path(base_dir: ctx.base))

    next_boot_key = {__MODULE__, make_ref()}
    on_exit(fn -> :persistent_term.erase(next_boot_key) end)

    assert {:error, :storage_epoch_missing_with_artifacts} =
             RuntimeIdentity.start_link(
               name: nil,
               base_dir: ctx.base,
               boot_term_key: next_boot_key,
               entropy: sequence_entropy([<<0x18::128>>, <<0x19::128>>])
             )

    refute File.exists?(RuntimeIdentity.storage_epoch_path(base_dir: ctx.base))
    assert File.read!(artifact) == "surviving-authority"
    assert File.read!(temporary_artifact) == "surviving-temp"
  end

  test "sweeps interrupted AtomicFile temporary artifacts before creating storage_epoch", ctx do
    File.mkdir_p!(ctx.base)
    artifact = Path.join(ctx.base, "storage_epoch.tmp.interrupted")
    File.write!(artifact, "surviving-temp")

    pid =
      start_identity(ctx,
        entropy: sequence_entropy([<<0x1A::128>>, <<0x1B::128>>])
      )

    assert RuntimeIdentity.readiness(pid) == %{
             boot_id: <<0x1A::128>>,
             storage_epoch: <<0x1B::128>>
           }

    refute File.exists?(artifact)
    assert File.read!(RuntimeIdentity.storage_epoch_path(base_dir: ctx.base)) == <<0x1B::128>>
  end

  test "rejects zero or malformed entropy without persisting an identity", ctx do
    assert {:error, :zero_identifier} =
             RuntimeIdentity.start_link(
               name: nil,
               base_dir: ctx.base,
               boot_term_key: ctx.boot_term_key,
               entropy: fn 16 -> <<0::128>> end
             )

    refute File.exists?(RuntimeIdentity.storage_epoch_path(base_dir: ctx.base))

    other_key = {__MODULE__, make_ref()}
    on_exit(fn -> :persistent_term.erase(other_key) end)

    assert {:error, :invalid_entropy} =
             RuntimeIdentity.start_link(
               name: nil,
               base_dir: ctx.base,
               boot_term_key: other_key,
               entropy: fn 16 -> <<1, 2, 3>> end
             )
  end

  test "rejects corrupt durable storage_epoch instead of silently replacing it", ctx do
    path = RuntimeIdentity.storage_epoch_path(base_dir: ctx.base)
    File.mkdir_p!(ctx.base)
    File.write!(path, <<1, 2, 3>>)

    assert {:error, :corrupt_storage_epoch} =
             RuntimeIdentity.start_link(
               name: nil,
               base_dir: ctx.base,
               boot_term_key: ctx.boot_term_key,
               entropy: sequence_entropy([<<0x21::128>>])
             )

    assert File.read!(path) == <<1, 2, 3>>
  end

  test "initialization follows the Tier-B atomic durability sequence", ctx do
    TracingFileSystem.attach(self())
    path = RuntimeIdentity.storage_epoch_path(base_dir: ctx.base)

    pid =
      start_identity(ctx,
        entropy: sequence_entropy([<<0x81::128>>, <<0x82::128>>]),
        file_system: TracingFileSystem
      )

    assert RuntimeIdentity.storage_epoch(pid) == <<0x82::128>>
    assert_receive {:file_system, {:read, ^path}}
    assert_receive {:file_system, {:mkdir_p, base}}
    assert base == ctx.base
    assert_receive {:file_system, {:chmod, ^base, 0o700}}
    parent = Path.dirname(base)
    assert_receive {:file_system, {:open, ^parent, parent_modes}}
    assert :directory in parent_modes
    assert_receive {:file_system, {:sync, ^parent}}
    assert_receive {:file_system, {:close, ^parent}}
    assert_receive {:file_system, {:open, temp_path, modes}}
    assert Path.dirname(temp_path) == ctx.base
    assert :exclusive in modes
    assert_receive {:file_system, {:chmod, ^temp_path, 0o600}}
    assert_receive {:file_system, {:write, ^temp_path, 16}}
    assert_receive {:file_system, {:sync, ^temp_path}}
    assert_receive {:file_system, {:close, ^temp_path}}
    assert_receive {:file_system, {:rename, ^temp_path, ^path}}
    assert_receive {:file_system, {:open, ^base, directory_modes}}
    assert :directory in directory_modes
    assert_receive {:file_system, {:sync, ^base}}
    assert_receive {:file_system, {:close, ^base}}
  end

  test "fault injection covers every Tier-B durability boundary", ctx do
    stages = [
      :temp_opened,
      :temp_chmodded,
      :temp_written,
      :temp_synced,
      :temp_closed,
      :before_rename,
      :renamed,
      :parent_synced
    ]

    Enum.each(stages, fn failed_stage ->
      base = Path.join(ctx.base, Atom.to_string(failed_stage))
      key = {__MODULE__, failed_stage, make_ref()}

      result =
        RuntimeIdentity.start_link(
          name: nil,
          base_dir: base,
          boot_term_key: key,
          entropy: sequence_entropy([<<0x91::128>>, <<0x92::128>>]),
          fault_injector: fn
            ^failed_stage -> {:error, :simulated_power_loss}
            _ -> :ok
          end
        )

      assert {:error, {:fault_injected, ^failed_stage, :simulated_power_loss}} = result
      :persistent_term.erase(key)

      case failed_stage do
        stage when stage in [:renamed, :parent_synced] ->
          assert File.read!(RuntimeIdentity.storage_epoch_path(base_dir: base)) == <<0x92::128>>

        _ ->
          refute File.exists?(RuntimeIdentity.storage_epoch_path(base_dir: base))
      end
    end)
  end

  defp start_identity(ctx, opts) do
    {:ok, pid} =
      RuntimeIdentity.start_link(
        Keyword.merge(
          [name: nil, base_dir: ctx.base, boot_term_key: ctx.boot_term_key],
          opts
        )
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    pid
  end

  defp sequence_entropy(values) do
    {:ok, agent} = Agent.start_link(fn -> values end)

    fn 16 ->
      Agent.get_and_update(agent, fn
        [next | rest] -> {next, rest}
        [] -> flunk("unexpected entropy request")
      end)
    end
  end
end
