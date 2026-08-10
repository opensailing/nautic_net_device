defmodule RacingOrg.Tracker.Pro.DesiredState.Runtime do
  @moduledoc """
  Production composition for the logger's Desired State runtime.

  The runtime derives the logical device UUID and credential epoch only from the
  verified bootstrap authority. Session key fingerprints are deliberately absent
  from this boundary.
  """

  alias RacingOrg.Tracker.Pro
  alias RacingOrg.Tracker.Pro.DesiredState.{Applier, Manager, OperationalGate, RuntimeIdentity, Store}
  alias RacingOrg.Tracker.Pro.SecureTransport.BootstrapState
  alias RacingOrg.Tracker.Pro.SecureTransport.BootProvisioner
  alias RacingOrg.Tracker.Pro.SecureTransport.ChannelClient
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1, as: Contract
  alias RacingOrg.Tracker.Pro.SecureTransport.SessionHolder

  @spec applier_child_spec(keyword()) :: Supervisor.child_spec()
  def applier_child_spec(opts \\ []) do
    %{
      id: Applier,
      start: {__MODULE__, :start_applier, [opts]},
      restart: :permanent,
      shutdown: 5_000,
      type: :worker,
      modules: [Applier]
    }
  end

  @spec manager_child_spec(keyword()) :: Supervisor.child_spec()
  def manager_child_spec(opts \\ []) do
    %{
      id: Manager,
      start: {__MODULE__, :start_manager, [opts]},
      restart: :permanent,
      shutdown: 5_000,
      type: :worker,
      modules: [Manager]
    }
  end

  @doc false
  @spec start_applier(keyword()) :: GenServer.on_start()
  def start_applier(opts) do
    Applier.start_link(
      name: Keyword.get(opts, :name, Applier),
      store: store(opts),
      manager: Keyword.get(opts, :manager, Manager),
      manager_capability: Keyword.fetch!(opts, :controller_capability)
    )
  end

  @doc false
  @spec start_manager(keyword()) :: GenServer.on_start()
  def start_manager(opts) do
    runtime_identity = Keyword.get(opts, :runtime_identity, RuntimeIdentity)
    boot_provisioner = Keyword.get(opts, :boot_provisioner, BootProvisioner)
    applier = Keyword.get(opts, :applier, Applier)
    controller_capability = Keyword.fetch!(opts, :controller_capability)

    identity_provider =
      Keyword.get_lazy(opts, :identity, fn ->
        fn -> identity(boot_provisioner, runtime_identity) end
      end)

    Manager.start_link(
      name: Keyword.get(opts, :name, Manager),
      store: store(opts),
      gate: Keyword.get(opts, :gate, OperationalGate),
      controller_capability: controller_capability,
      session_holder: Keyword.get(opts, :session_holder, SessionHolder),
      identity: identity_provider,
      identity_refresh_ms: Keyword.get(opts, :identity_refresh_ms, 250),
      owner_retry_base_ms: Keyword.get(opts, :owner_retry_base_ms, 25),
      owner_retry_max_ms: Keyword.get(opts, :owner_retry_max_ms, 5_000),
      lease_heartbeat_ms: Keyword.get(opts, :lease_heartbeat_ms, 1_000),
      lease_timeout_ms: Keyword.get(opts, :lease_timeout_ms, 5_000),
      compatibility: Keyword.get_lazy(opts, :compatibility, fn -> compatibility(opts) end),
      applier:
        Keyword.get_lazy(opts, :applier_callbacks, fn ->
          applier_callbacks(applier, controller_capability)
        end),
      ack_sink:
        Keyword.get_lazy(opts, :ack_sink, fn ->
          ack_sink(Keyword.get(opts, :channel_client, ChannelClient))
        end)
    )
  end

  @doc false
  @spec identity(GenServer.server(), GenServer.server()) :: {:ok, map()} | {:error, atom()}
  def identity(boot_provisioner \\ BootProvisioner, runtime_identity \\ RuntimeIdentity) do
    identity_from(
      BootProvisioner.current_state(boot_provisioner),
      RuntimeIdentity.readiness(runtime_identity)
    )
  rescue
    _exception -> {:error, :no_verified_authority}
  catch
    :exit, _reason -> {:error, :no_verified_authority}
  end

  @doc false
  @spec identity_from(BootstrapState.t(), map()) :: {:ok, map()} | {:error, atom()}
  def identity_from(
        %BootstrapState{authority: %{logical_device_id: device_id}} = bootstrap_state,
        %{boot_id: boot_id, storage_epoch: storage_epoch}
      ) do
    with {:ok, credential_epoch} <- BootstrapState.credential_epoch(bootstrap_state) do
      {:ok,
       %{
         device_id: device_id,
         credential_epoch: credential_epoch,
         boot_id: boot_id,
         storage_epoch: storage_epoch
       }}
    end
  end

  def identity_from(%BootstrapState{}, _runtime_identity),
    do: {:error, :no_verified_authority}

  @doc false
  @spec compatibility(keyword()) :: map()
  def compatibility(opts \\ []) do
    firmware_version =
      Keyword.get_lazy(opts, :firmware_version, fn ->
        :racing_org_tracker_pro
        |> Application.spec(:vsn)
        |> to_string()
      end)

    firmware_git_sha = Keyword.get_lazy(opts, :firmware_git_sha, &Pro.git_commit/0)

    capabilities =
      Enum.map(Contract.capabilities(), fn {name, _id, version} ->
        {name, version}
      end)

    %{
      firmware_version: firmware_version,
      firmware_git_sha: firmware_git_sha,
      capabilities: capabilities
    }
  end

  defp store(opts) do
    runtime_identity = Keyword.get(opts, :runtime_identity, RuntimeIdentity)
    base_dir = Keyword.get(opts, :base_dir, desired_state_directory())

    Store.new(
      base_dir: base_dir,
      storage_epoch: RuntimeIdentity.storage_epoch(runtime_identity)
    )
  end

  defp desired_state_directory do
    RuntimeIdentity.storage_epoch_path()
    |> Path.dirname()
  end

  @doc false
  @spec applier_callbacks(GenServer.server(), reference()) :: map()
  def applier_callbacks(applier, manager_capability) when is_reference(manager_capability) do
    %{
      register: fn -> Applier.register_manager(applier, manager_capability) end,
      validate: fn pointer, _sections, secret, owner_pid_map ->
        Applier.validate_generation(applier, pointer, secret, owner_pid_map)
      end,
      apply_non_network: fn pointer, _sections, owner_pid_map ->
        Applier.apply_non_network(applier, pointer, owner_pid_map)
      end,
      apply_wifi: fn pointer, secret, owner_pid_map ->
        Applier.apply_wifi(applier, pointer, secret, owner_pid_map)
      end,
      reset: fn owner_pid_map ->
        Applier.reset_to_compile_default(applier, owner_pid_map)
      end,
      reconcile: fn pointer, owner_pid_map ->
        Applier.reconcile_generation(applier, pointer, owner_pid_map)
      end,
      owners: fn -> Applier.owners(applier) end
    }
  end

  @doc false
  @spec ack_sink(GenServer.server()) :: (map() -> :ok | {:error, :control_plane_unavailable})
  def ack_sink(channel_client \\ ChannelClient) do
    fn ack -> ChannelClient.send_desired_state_ack(channel_client, ack) end
  end
end
