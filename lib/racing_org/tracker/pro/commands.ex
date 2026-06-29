defmodule RacingOrg.Tracker.Pro.Commands do
  @moduledoc """
  Receives, validates, and de-duplicates RacingOrg server commands that arrive on
  the device-initiated UDP socket, and tracks the acknowledgement the device
  reports back on its telemetry/heartbeat uploads.

  All commands are versioned and idempotent: a command is applied at most once,
  stale assignment versions and expired or mis-addressed commands are ignored,
  and malformed packets are dropped safely. Applying a command here only updates
  in-memory command state and notifies subscribers; durable persistence and
  behavioural effects (sampling, archiving, NMEA2000 output) live in later
  phases that subscribe via `subscribe/2` or read `current_assignment/1`.

  The reference performance polar (`:polar_table` command) is BOAT-scoped config,
  kept as a SEPARATE piece of device state (`current_polar/1`) with its OWN
  monotonic version and its own durable store (`RacingOrg.Tracker.Pro.Polar.Store`).
  It is deliberately decoupled from the race-assignment lifecycle: a polar is
  never discarded, rejected, or mutated by assignment staleness/expiry/cancel
  logic, and applying a polar never touches an active assignment.
  """
  use GenServer

  require Logger

  alias RacingOrg.Tracker.Pro.Commands.Assignment
  alias RacingOrg.Tracker.Pro.Commands.Store
  alias RacingOrg.Tracker.Pro.Polar
  alias RacingOrg.Tracker.Protobuf.CommandAck
  alias RacingOrg.Tracker.Protobuf.DeviceCommand
  alias RacingOrg.Tracker.Protobuf.PolarTable
  alias RacingOrg.Tracker.Protobuf.ServerReply

  @protocol_version 1

  # --- Client API ---

  def start_link(opts) do
    case Keyword.fetch(opts, :name) do
      {:ok, name} -> GenServer.start_link(__MODULE__, opts, name: name)
      :error -> GenServer.start_link(__MODULE__, opts)
    end
  end

  @doc """
  Validate and (if accepted) apply a `ServerReply`, given either its encoded
  binary or a decoded `%ServerReply{}`. Returns `:applied` or `{:ignored, reason}`.
  """
  def apply_reply(server \\ __MODULE__, reply), do: GenServer.call(server, {:apply_reply, reply})

  @doc "The `CommandAck` to report on outgoing telemetry/heartbeat, or `nil`."
  def current_ack(server \\ __MODULE__) do
    GenServer.call(server, :current_ack)
  catch
    :exit, _ -> nil
  end

  @doc "The currently-applied assignment state, or `nil`."
  def current_assignment(server \\ __MODULE__), do: GenServer.call(server, :current_assignment)

  @doc """
  The current reference performance polar (`RacingOrg.Tracker.Pro.Polar`), or `nil`.

  Boat-scoped config, independent of the race assignment — for later phases that
  interpolate target speeds / VMG from the reference grid.
  """
  @spec current_polar(GenServer.server()) :: Polar.t() | nil
  def current_polar(server \\ __MODULE__), do: GenServer.call(server, :current_polar)

  @doc "Subscribe `pid` to `{:racing_org_command, %DeviceCommand{}}` notifications."
  def subscribe(server \\ __MODULE__, pid \\ self()), do: GenServer.call(server, {:subscribe, pid})

  @doc "Safely decode a `ServerReply` binary. Never raises."
  def decode(binary) when is_binary(binary) do
    {:ok, ServerReply.decode(binary)}
  rescue
    error -> {:error, error}
  end

  # --- Server ---

  @impl true
  def init(opts) do
    state = %{
      device_id: opts[:device_id],
      protocol_version: opts[:protocol_version] || @protocol_version,
      applied_command_ids: MapSet.new(),
      assignment: nil,
      polar: nil,
      ack: nil,
      subscribers: MapSet.new(),
      now_fn: opts[:now_fn] || (&DateTime.utc_now/0),
      store_dir: opts[:store_dir],
      polar_dir: opts[:polar_dir]
    }

    {:ok, state |> restore_assignment() |> restore_polar()}
  end

  # Re-hydrate the persisted assignment at boot so applied state, the ACK, and
  # version-based de-duplication survive reboots.
  defp restore_assignment(%{store_dir: nil} = state), do: state

  defp restore_assignment(%{store_dir: dir} = state) do
    case Store.load(dir) do
      {:ok, %Assignment{} = assignment} ->
        %{
          state
          | assignment: assignment,
            ack: ack_from_assignment(assignment),
            applied_command_ids: MapSet.put(state.applied_command_ids, assignment.command_id)
        }

      :empty ->
        state
    end
  end

  # Re-hydrate the persisted polar at boot so the boat-scoped reference grid and
  # its version-based de-duplication survive reboots, independently of the
  # assignment.
  defp restore_polar(%{polar_dir: nil} = state), do: state

  defp restore_polar(%{polar_dir: dir} = state) do
    case Polar.Store.load(dir) do
      {:ok, %Polar{} = polar} -> %{state | polar: polar}
      :empty -> state
    end
  end

  @impl true
  def handle_call({:apply_reply, reply}, _from, state) do
    {result, state} = do_apply(reply, state)
    {:reply, result, state}
  end

  def handle_call(:current_ack, _from, state), do: {:reply, state.ack, state}
  def handle_call(:current_assignment, _from, state), do: {:reply, state.assignment, state}
  def handle_call(:current_polar, _from, state), do: {:reply, state.polar, state}

  def handle_call({:subscribe, pid}, _from, state) do
    {:reply, :ok, %{state | subscribers: MapSet.put(state.subscribers, pid)}}
  end

  # UDP receive path forwards packets here asynchronously.
  @impl true
  def handle_cast({:packet, binary}, state) do
    {_result, state} = do_apply(binary, state)
    {:noreply, state}
  end

  # --- Command pipeline ---

  defp do_apply(binary, state) when is_binary(binary) do
    case decode(binary) do
      {:ok, reply} -> do_apply(reply, state)
      {:error, _} -> {{:ignored, :malformed}, state}
    end
  end

  defp do_apply(%ServerReply{} = reply, state) do
    with :ok <- check_protocol(reply, state),
         :ok <- check_device(reply, state),
         {:ok, command} <- fetch_command(reply),
         :ok <- check_command_id(command),
         :ok <- check_not_expired(command, state),
         :ok <- check_not_duplicate(command, state),
         :ok <- check_not_stale(command, state),
         :ok <- check_polar_not_stale(command, state) do
      apply_command(command, state)
    else
      {:ignored, reason} ->
        Logger.debug("Ignoring server command: #{reason}")
        {{:ignored, reason}, state}
    end
  end

  defp check_protocol(%ServerReply{protocol_version: v}, %{protocol_version: v}), do: :ok
  defp check_protocol(_reply, _state), do: {:ignored, :protocol_mismatch}

  defp check_device(%ServerReply{device_id: id}, _state) when id in ["", nil], do: :ok
  defp check_device(_reply, %{device_id: nil}), do: :ok
  defp check_device(%ServerReply{device_id: id}, %{device_id: id}), do: :ok
  defp check_device(_reply, _state), do: {:ignored, :device_mismatch}

  defp fetch_command(%ServerReply{command: %DeviceCommand{} = command}), do: {:ok, command}
  defp fetch_command(_reply), do: {:ignored, :no_command}

  defp check_command_id(%DeviceCommand{command_id: id}) when id in ["", nil],
    do: {:ignored, :missing_command_id}

  defp check_command_id(_command), do: :ok

  defp check_not_expired(%DeviceCommand{expires_at: nil}, _state), do: :ok

  defp check_not_expired(%DeviceCommand{expires_at: %{seconds: seconds}}, state) do
    if DateTime.compare(DateTime.from_unix!(seconds), state.now_fn.()) == :lt do
      {:ignored, :expired}
    else
      :ok
    end
  end

  defp check_not_duplicate(%DeviceCommand{command_id: id}, state) do
    if MapSet.member?(state.applied_command_ids, id), do: {:ignored, :duplicate}, else: :ok
  end

  # Assignment versions are monotonic per assignment_id. Commands not scoped to an
  # assignment (empty assignment_id) are never considered stale.
  defp check_not_stale(%DeviceCommand{assignment_id: ""}, _state), do: :ok

  defp check_not_stale(%DeviceCommand{assignment_id: aid, assignment_version: version}, %{
         assignment: %{assignment_id: aid, version: applied_version}
       }) do
    if version <= applied_version, do: {:ignored, :stale_version}, else: :ok
  end

  defp check_not_stale(_command, _state), do: :ok

  # The polar carries its OWN monotonic version (independent of assignment_version);
  # ignore an already-applied (older/equal) version. Non-polar commands are a
  # no-op here.
  defp check_polar_not_stale(%DeviceCommand{payload: {:polar_table, %PolarTable{version: version}}}, %{
         polar: %Polar{version: applied_version}
       }) do
    if version <= applied_version, do: {:ignored, :stale_polar_version}, else: :ok
  end

  defp check_polar_not_stale(_command, _state), do: :ok

  defp apply_command(%DeviceCommand{} = command, state) do
    state = %{
      state
      | ack: build_ack(command),
        applied_command_ids: MapSet.put(state.applied_command_ids, command.command_id)
    }

    state =
      state
      |> apply_assignment(command)
      |> apply_polar(command)

    notify(state, command)
    {:applied, state}
  end

  defp apply_assignment(state, %DeviceCommand{} = command) do
    case Assignment.update(state.assignment, command) do
      {:updated, assignment} ->
        maybe_persist(state.store_dir, assignment)
        %{state | assignment: assignment}

      :no_change ->
        state
    end
  end

  # A polar command updates ONLY the boat-scoped polar state + its store, never the
  # assignment. Any other command leaves the polar untouched.
  defp apply_polar(state, %DeviceCommand{payload: {:polar_table, %PolarTable{} = table}}) do
    polar = Polar.from_protobuf(table)
    maybe_persist_polar(state.polar_dir, polar)
    %{state | polar: polar}
  end

  defp apply_polar(state, %DeviceCommand{}), do: state

  defp build_ack(%DeviceCommand{} = command) do
    struct(CommandAck,
      command_id: command.command_id,
      assignment_id: command.assignment_id,
      assignment_version: command.assignment_version
    )
  end

  defp ack_from_assignment(%Assignment{} = assignment) do
    struct(CommandAck,
      command_id: assignment.command_id,
      assignment_id: assignment.assignment_id,
      assignment_version: assignment.version
    )
  end

  defp maybe_persist(nil, _assignment), do: :ok
  defp maybe_persist(dir, assignment), do: Store.save(dir, assignment)

  defp maybe_persist_polar(nil, _polar), do: :ok
  defp maybe_persist_polar(dir, polar), do: Polar.Store.save(dir, polar)

  defp notify(state, command) do
    for pid <- state.subscribers, do: send(pid, {:racing_org_command, command})
  end
end
