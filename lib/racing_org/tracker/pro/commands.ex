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

  alias RacingOrg.Tracker.Protobuf.{
    CancelAssignment,
    CommandAck,
    CourseMark,
    DeviceCommand,
    LatLon,
    LineGeometry,
    PolarCell,
    PolarOptimum,
    PolarRow,
    PolarTable,
    RaceAssignment,
    SamplingRules,
    ServerReply
  }

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

  @doc "Purely validate and normalize a complete desired-state assignment projection."
  @spec validate_assignment(term()) :: {:ok, Assignment.t()} | {:error, term()}
  def validate_assignment(content), do: assignment_from_desired_state(content)

  @doc "Durably install the authoritative desired-state assignment projection."
  @spec reconcile_assignment(GenServer.server(), map()) :: {:ok, Assignment.t()} | {:error, term()}
  def reconcile_assignment(server \\ __MODULE__, content) when is_map(content) do
    GenServer.call(server, {:reconcile_assignment, content})
  end

  @doc "Durably apply the assignment tombstone."
  @spec clear_assignment(GenServer.server()) :: :ok | {:error, term()}
  def clear_assignment(server \\ __MODULE__), do: GenServer.call(server, :clear_assignment)

  @doc "Purely validate and normalize a desired-state reference polar."
  @spec validate_polar(term()) :: {:ok, Polar.t()} | {:error, term()}
  def validate_polar(content), do: Polar.from_desired_state(content)

  @doc "Durably install the authoritative desired-state reference polar."
  @spec reconcile_polar(GenServer.server(), map()) :: {:ok, Polar.t()} | {:error, term()}
  def reconcile_polar(server \\ __MODULE__, content) when is_map(content) do
    GenServer.call(server, {:reconcile_polar, content})
  end

  @doc "Durably apply the reference-polar tombstone."
  @spec clear_polar(GenServer.server()) :: :ok | {:error, term()}
  def clear_polar(server \\ __MODULE__), do: GenServer.call(server, :clear_polar)

  @doc """
  The current reference performance polar (`RacingOrg.Tracker.Pro.Polar`), or `nil`.

  Boat-scoped config, independent of the race assignment — for later phases that
  interpolate target speeds / VMG from the reference grid.
  """
  @spec current_polar(GenServer.server()) :: Polar.t() | nil
  def current_polar(server \\ __MODULE__), do: GenServer.call(server, :current_polar)

  @doc """
  The precompiled polar interpolant (`RacingOrg.Tracker.Pro.Polar.Lookup`) for the
  current polar, or `nil` (no polar, or a polar whose grid did not compile).

  This is built ONCE — when a polar is applied (or rehydrated on boot) — and cached
  in state, NOT rebuilt per read. The compute engine reads it once per polar version
  and caches it locally, so the live compute hot path never rebuilds the interpolant
  and never copies the source polar. See `Polar.Lookup.build/1`.
  """
  @spec current_polar_lookup(GenServer.server()) :: Polar.Lookup.t() | nil
  def current_polar_lookup(server \\ __MODULE__), do: GenServer.call(server, :current_polar_lookup)

  @doc "The current polar's monotonic version, or `nil` when no polar is loaded."
  @spec current_polar_version(GenServer.server()) :: non_neg_integer() | nil
  def current_polar_version(server \\ __MODULE__) do
    case current_polar(server) do
      %Polar{version: v} -> v
      nil -> nil
    end
  end

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
      # The compiled Polar.Lookup for `polar`, built ONCE on apply/restore (off the
      # hot path) and cached here; nil when there is no polar or it didn't compile.
      polar_lookup: nil,
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
      {:ok, %Polar{} = polar} -> %{state | polar: polar, polar_lookup: build_lookup(polar)}
      :empty -> state
    end
  end

  # Build the compiled interpolant once; a polar whose grid does not compile (empty /
  # degenerate) yields a nil lookup (the raw polar is still kept). The polar arrives
  # from the network, so guard the build defensively: a malformed grid must never
  # crash the command pipeline — it just leaves the lookup nil.
  defp build_lookup(%Polar{} = polar) do
    case Polar.Lookup.build(polar) do
      {:ok, lookup} -> lookup
      {:error, _reason} -> nil
    end
  rescue
    error ->
      Logger.warning("[Commands] polar lookup build failed: #{inspect(error)}")
      nil
  end

  @impl true
  def handle_call({:apply_reply, reply}, _from, state) do
    {result, state} = do_apply(reply, state)
    {:reply, result, state}
  end

  def handle_call({:reconcile_assignment, content}, _from, state) do
    with {:ok, assignment} <- validate_assignment(content),
         :ok <- maybe_persist(state.store_dir, assignment) do
      command = assignment_notification(assignment)
      state = %{state | assignment: assignment}
      notify(state, command)
      {:reply, {:ok, assignment}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:clear_assignment, _from, state) do
    case clear_assignment_store(state.store_dir) do
      :ok ->
        state = %{state | assignment: nil}
        notify(state, assignment_tombstone_notification())
        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:reconcile_polar, content}, _from, state) do
    with {:ok, polar} <- validate_polar(content),
         :ok <- maybe_persist_polar(state.polar_dir, polar) do
      state = %{state | polar: polar, polar_lookup: build_lookup(polar)}
      notify(state, polar_notification(polar))
      {:reply, {:ok, polar}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:clear_polar, _from, state) do
    case clear_polar_store(state.polar_dir) do
      :ok ->
        state = %{state | polar: nil, polar_lookup: nil}
        notify(state, polar_tombstone_notification())
        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:current_ack, _from, state), do: {:reply, state.ack, state}
  def handle_call(:current_assignment, _from, state), do: {:reply, state.assignment, state}
  def handle_call(:current_polar, _from, state), do: {:reply, state.polar, state}
  def handle_call(:current_polar_lookup, _from, state), do: {:reply, state.polar_lookup, state}

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
    # Compile the interpolant ONCE here, on the apply path (off the hot path), and
    # cache it so the compute engine never rebuilds it per tick.
    %{state | polar: polar, polar_lookup: build_lookup(polar)}
  end

  defp apply_polar(state, %DeviceCommand{}), do: state

  # --- Strict Desired State assignment projection ---
  #
  # The backend projection is COMPLETE and canonical, so nothing here coerces or
  # drops: a nested field present with the wrong shape (an unparseable
  # `official_start_at`, a non-map course mark, a negative mark position, a
  # non-numeric route point) rejects the WHOLE assignment rather than silently
  # installing a partially-understood race. The legacy `%DeviceCommand{}` path
  # (`apply_command/2`) is untouched and keeps its protobuf-native leniency.

  @assignment_schema_version 1

  defp assignment_from_desired_state(%{} = content) do
    with :ok <- strict_schema_version(get(content, :schema_version)),
         {:ok, assignment_id} <- required_string(get(content, :assignment_id)),
         {:ok, version} <- strict_assignment_version(content),
         {:ok, device_id} <- required_string(get(content, :device_id)),
         {:ok, boat_id} <- optional_string(get(content, :boat_id)),
         {:ok, race_id} <- optional_string(get(content, :race_id)),
         {:ok, race_session_id} <- optional_string(get(content, :race_session_id)),
         {:ok, hash} <-
           optional_string(get(content, :assignment_hash) || get(content, :assignment_key)),
         {:ok, official_start} <- optional_timestamp(get(content, :official_start_at)),
         {:ok, expires_at} <- optional_timestamp(get(content, :expires_at)),
         {:ok, duration} <- optional_nonnegative_integer(get(content, :expected_duration_seconds)),
         {:ok, start_line} <- strict_line(get(content, :start_line)),
         {:ok, finish_line} <- strict_line(get(content, :finish) || get(content, :finish_line)),
         {:ok, course_marks} <- strict_course_marks(get(content, :course_marks)),
         {:ok, shortened?, shortened_mark} <-
           strict_shortened_course(get(content, :shortened_course)),
         {:ok, active_mark_code} <- strict_active_mark_code(content),
         {:ok, sampling_rules} <- strict_sampling_rules(get(content, :sampling_rules)),
         {:ok, route} <- strict_route(get(content, :route)),
         {:ok, route_request_id} <- strict_route_request_id(content, route),
         {:ok, route_geometry} <- strict_route_geometry(content, route),
         {:ok, route_hash} <-
           optional_string(get(content, :route_geometry_hash) || get(content, :route_hash)) do
      race_assignment =
        struct(RaceAssignment,
          boat_id: boat_id,
          device_id: device_id,
          race_plan_id: race_id,
          race_session_id: race_session_id,
          race_recording_id: assignment_id,
          official_start_time: official_start,
          expected_duration_seconds: duration,
          start_line: start_line,
          finish_line: finish_line,
          course_marks: course_marks,
          shortened_course: shortened?,
          shortened_final_mark_code: shortened_mark,
          active_mark_code: active_mark_code,
          sampling_rules: sampling_rules,
          route_request_id: route_request_id,
          route_geometry: route_geometry,
          route_hash: route_hash
        )

      {:ok,
       %Assignment{
         assignment_id: assignment_id,
         version: version,
         hash: hash,
         command_id: nil,
         expires_at: expires_at,
         race_assignment: race_assignment,
         active_mark_code: active_mark_code,
         route_geometry: route_geometry,
         route_hash: route_hash,
         desired_state: content,
         cancelled: false
       }}
    end
  end

  defp assignment_from_desired_state(_content), do: {:error, :invalid_assignment}

  defp strict_schema_version(@assignment_schema_version), do: :ok
  defp strict_schema_version(_version), do: {:error, :unsupported_assignment_schema_version}

  defp strict_assignment_version(content) do
    case get(content, :assignment_version) || get(content, :version) do
      version when is_integer(version) and version >= 0 -> {:ok, version}
      _other -> {:error, :invalid_assignment_version}
    end
  end

  defp strict_active_mark_code(content) do
    case get(content, :active_next_mark) do
      nil ->
        optional_string(get(content, :active_mark_code))

      %{} = mark ->
        with {:ok, code} <- optional_string(get(mark, :code)),
             {:ok, _position, _sequence} <-
               strict_mark_position(get(mark, :position), get(mark, :sequence), 1) do
          {:ok, code}
        end

      _other ->
        {:error, :invalid_active_next_mark}
    end
  end

  defp strict_route(nil), do: {:ok, %{}}
  defp strict_route(%{} = route), do: {:ok, route}
  defp strict_route(_route), do: {:error, :invalid_route}

  defp strict_route_request_id(content, route) do
    optional_string(get(content, :route_request_id) || get(route, :route_request_id))
  end

  defp strict_route_geometry(content, route) do
    points =
      get(content, :route_points) ||
        get(content, :optimized_route_geometry) ||
        get(route, :route_points) ||
        get(route, :route_geometry) ||
        []

    strict_positions(points)
  end

  defp strict_positions(points) when is_list(points) do
    points
    |> Enum.reduce_while({:ok, []}, fn point, {:ok, acc} ->
      case strict_position(point) do
        {:ok, position} -> {:cont, {:ok, [position | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, positions} -> {:ok, Enum.reverse(positions)}
      {:error, _reason} = error -> error
    end
  end

  defp strict_positions(_points), do: {:error, :invalid_route_geometry}

  # An empty line map is a legitimate "no geometry yet" projection; a PARTIAL one
  # (present but missing/!numeric ends) is malformed and rejects.
  defp strict_line(nil), do: {:ok, nil}
  defp strict_line(line) when map_size(line) == 0, do: {:ok, nil}

  defp strict_line(%{} = line) do
    end_a = get(line, :end_a) || get(line, :port) || get(line, :a)
    end_b = get(line, :end_b) || get(line, :starboard) || get(line, :b)

    with {:ok, a} <- strict_position(end_a),
         {:ok, b} <- strict_position(end_b) do
      {:ok, struct(LineGeometry, end_a: a, end_b: b)}
    else
      {:error, _reason} -> {:error, :invalid_line_geometry}
    end
  end

  defp strict_line(_line), do: {:error, :invalid_line_geometry}

  defp strict_course_marks(nil), do: {:ok, []}

  defp strict_course_marks(marks) when is_list(marks) do
    marks
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {mark, index}, {:ok, acc} ->
      case strict_course_mark(mark, index) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, _reason} = error -> error
    end
  end

  defp strict_course_marks(_marks), do: {:error, :invalid_course_marks}

  defp strict_course_mark(%{} = mark, index) do
    with {:ok, code} <- optional_string(get(mark, :code)),
         {:ok, position, sequence} <-
           strict_mark_position(get(mark, :position), get(mark, :sequence), index) do
      {:ok, struct(CourseMark, code: code, position: position, sequence: sequence)}
    end
  end

  defp strict_course_mark(_mark, _index), do: {:error, :invalid_course_mark}

  # `position` is overloaded by the backend: an ordinal (integer) OR a geographic
  # point (map). Both are accepted; anything else — notably a NEGATIVE ordinal —
  # rejects.
  defp strict_mark_position(position, sequence, _index)
       when is_integer(position) and position >= 0 do
    with {:ok, _sequence} <- optional_nonnegative_integer(sequence) do
      {:ok, nil, position}
    end
  end

  defp strict_mark_position(nil, sequence, index) do
    case optional_nonnegative_integer(sequence) do
      {:ok, nil} -> {:ok, nil, index}
      {:ok, sequence} -> {:ok, nil, sequence}
      {:error, _reason} = error -> error
    end
  end

  defp strict_mark_position(%{} = position, sequence, index) do
    with {:ok, latlon} <- strict_position(position),
         {:ok, sequence} <- optional_nonnegative_integer(sequence) do
      {:ok, latlon, sequence || index}
    end
  end

  defp strict_mark_position(_position, _sequence, _index), do: {:error, :invalid_mark_position}

  defp strict_position(%LatLon{} = position), do: {:ok, position}

  defp strict_position(%{} = position) do
    latitude = get(position, :latitude) || get(position, :lat)
    longitude = get(position, :longitude) || get(position, :lon) || get(position, :lng)

    if in_range?(latitude, -90, 90) and in_range?(longitude, -180, 180) do
      {:ok, struct(LatLon, latitude: latitude / 1, longitude: longitude / 1)}
    else
      {:error, :invalid_position}
    end
  end

  defp strict_position(_position), do: {:error, :invalid_position}

  defp in_range?(value, min, max), do: is_number(value) and value >= min and value <= max

  defp strict_sampling_rules(nil), do: {:ok, nil}

  defp strict_sampling_rules(%{} = rules) do
    with {:ok, start_window} <-
           optional_nonnegative_integer(get(rules, :start_window_seconds)),
         {:ok, mark_proximity} <-
           optional_nonnegative_integer(get(rules, :mark_proximity_meters)),
         {:ok, finish_window} <-
           optional_nonnegative_integer(get(rules, :finish_window_seconds)) do
      {:ok,
       struct(SamplingRules,
         start_window_seconds: start_window || 0,
         mark_proximity_meters: mark_proximity || 0,
         finish_window_seconds: finish_window || 0
       )}
    end
  end

  defp strict_sampling_rules(_rules), do: {:error, :invalid_sampling_rules}

  defp strict_shortened_course(nil), do: {:ok, false, ""}
  defp strict_shortened_course(value) when is_boolean(value), do: {:ok, value, ""}
  defp strict_shortened_course(value) when map_size(value) == 0, do: {:ok, false, ""}

  defp strict_shortened_course(%{} = value) do
    case optional_string(get(value, :final_mark_code) || get(value, :code)) do
      {:ok, code} -> {:ok, true, code}
      {:error, _reason} -> {:error, :invalid_shortened_course}
    end
  end

  defp strict_shortened_course(_value), do: {:error, :invalid_shortened_course}

  defp optional_timestamp(nil), do: {:ok, nil}
  defp optional_timestamp(%Google.Protobuf.Timestamp{} = timestamp), do: {:ok, timestamp}

  defp optional_timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, RacingOrg.Tracker.Protobuf.to_proto_timestamp(datetime)}
      {:error, _reason} -> {:error, :invalid_timestamp}
    end
  end

  defp optional_timestamp(_value), do: {:error, :invalid_timestamp}

  defp required_string(value) when is_binary(value) and value != "", do: {:ok, value}
  defp required_string(_value), do: {:error, :missing_required_field}

  # Absent resolves to the protobuf-native empty string; a present non-string is
  # malformed and rejects.
  defp optional_string(nil), do: {:ok, ""}
  defp optional_string(value) when is_binary(value), do: {:ok, value}
  defp optional_string(_value), do: {:error, :invalid_string_field}

  defp optional_nonnegative_integer(nil), do: {:ok, nil}

  defp optional_nonnegative_integer(value) when is_integer(value) and value >= 0, do: {:ok, value}

  defp optional_nonnegative_integer(_value), do: {:error, :invalid_nonnegative_integer}

  defp assignment_notification(%Assignment{} = assignment) do
    struct(DeviceCommand,
      assignment_id: assignment.assignment_id,
      assignment_version: assignment.version,
      assignment_hash: assignment.hash || "",
      payload: {:race_assignment, assignment.race_assignment}
    )
  end

  defp assignment_tombstone_notification do
    struct(DeviceCommand,
      payload: {:cancel_assignment, struct(CancelAssignment, reason: "desired_state_tombstone")}
    )
  end

  defp polar_notification(%Polar{} = polar) do
    struct(DeviceCommand, payload: {:polar_table, polar_to_protobuf(polar)})
  end

  defp polar_tombstone_notification do
    struct(DeviceCommand, payload: {:polar_table, struct(PolarTable)})
  end

  defp polar_to_protobuf(%Polar{} = polar) do
    rows =
      Enum.map(polar.rows, fn row ->
        cells = Enum.map(row.cells, &struct(PolarCell, &1))
        struct(PolarRow, tws_mps: row.tws_mps, cells: cells)
      end)

    optima = Enum.map(polar.optima, &struct(PolarOptimum, &1))
    struct(PolarTable, polar_id: polar.polar_id, version: polar.version, rows: rows, optima: optima)
  end

  defp get(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp get(_map, _key), do: nil

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

  defp clear_assignment_store(nil), do: :ok
  defp clear_assignment_store(dir), do: Store.clear(dir)

  defp maybe_persist_polar(nil, _polar), do: :ok
  defp maybe_persist_polar(dir, polar), do: Polar.Store.save(dir, polar)

  defp clear_polar_store(nil), do: :ok
  defp clear_polar_store(dir), do: Polar.Store.clear(dir)

  defp notify(state, command) do
    for pid <- state.subscribers, do: send(pid, {:racing_org_command, command})
  end
end
