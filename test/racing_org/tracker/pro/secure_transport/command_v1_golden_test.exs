defmodule RacingOrg.Tracker.Pro.SecureTransport.CommandV1GoldenTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Frozen golden vectors for the command_v1 control wire contract.

  Pins the exact encoded bytes of the `DeviceCommand`/`ServerReply` protobuf
  control envelope (the command surface `RacingOrg.Tracker.Pro.Commands` and the
  channel command path consume) and of the `command_delivery`/`command_ack`
  secure-transport envelope, covering both in-flight payload shapes (protobuf
  `ServerReply` bytes as frozen by the backend command fence, and the canonical
  `type`/`args` command envelope the tracker ledger accepts), against
  `priv/secure_transport/command_v1_vectors.json`. The backend keeps a
  byte-identical copy of that file, so tracker and backend codecs cannot drift
  independently.
  """

  alias RacingOrg.Tracker.Pro.Commands
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.{Canonical, Command, Messages}

  alias RacingOrg.Tracker.Protobuf.{
    ActiveWaypointUpdate,
    CancelAssignment,
    CourseMark,
    DeviceCommand,
    LatLon,
    LineGeometry,
    RaceAssignment,
    RouteUpdate,
    SamplingRules,
    ServerReply
  }

  @vectors_path Path.expand("../../../../../priv/secure_transport/command_v1_vectors.json", __DIR__)
  @frozen_sha256 "a108f15d2368f221ede5fc5d6ead0c02e71a685a71044e115f5b7767750fb26d"
  @payload_variants ~w(race_assignment route_update active_waypoint_update cancel_assignment)
  @delivery_vectors ~w(race_assignment_server_reply canonical_noop)

  setup_all do
    %{document: @vectors_path |> File.read!() |> Jason.decode!()}
  end

  test "command_v1_vectors.json is byte-frozen at the shared cross-repository sha" do
    actual =
      @vectors_path
      |> File.read!()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    assert actual == @frozen_sha256,
           """
           priv/secure_transport/command_v1_vectors.json is FROZEN.

           Its SHA-256 no longer matches the pinned cross-repository value:

             pinned:  #{@frozen_sha256}
             actual:  #{actual}

           This file is the shared command_v1 golden vector consumed byte-for-byte
           by both the tracker and the backend. Any change to it is a cross-repo
           wire-contract break: regenerating or editing the vectors silently
           allows the two codecs to drift apart.

           If a contract change is truly intended, it must be coordinated across
           both repositories (a new vector file plus matching sha pins on both
           sides), not made by editing this frozen file in one repo.
           """
  end

  test "the vector set covers the closed assignment command surface", %{document: document} do
    assert Enum.map(document["vectors"], & &1["name"]) == @payload_variants

    for vector <- document["vectors"] do
      assert vector["server_reply"]["protocol_version"] == 1
      assert [variant] = Map.keys(vector["server_reply"]["command"]["payload"])
      assert variant == vector["name"]
    end
  end

  test "every DeviceCommand and ServerReply vector reproduces its exact pinned bytes", %{
    document: document
  } do
    for vector <- document["vectors"] do
      reply = build_reply(vector["server_reply"])
      command_bytes = hex(vector["expected"]["device_command_hex"])
      reply_bytes = hex(vector["expected"]["server_reply_hex"])

      assert DeviceCommand.encode(reply.command) == command_bytes,
             "#{vector["name"]}: tracker DeviceCommand encoding drifted from the frozen vector"

      assert ServerReply.encode(reply) == reply_bytes,
             "#{vector["name"]}: tracker ServerReply encoding drifted from the frozen vector"

      assert DeviceCommand.decode(command_bytes) == reply.command
      assert ServerReply.decode(reply_bytes) == reply
      assert Commands.decode(reply_bytes) == {:ok, reply}
    end
  end

  test "both in-flight command_delivery payload shapes are pinned in exact envelope bytes", %{
    document: document
  } do
    delivery_vectors = document["command_delivery"]["vectors"]
    assert Enum.map(delivery_vectors, & &1["name"]) == @delivery_vectors

    for %{"name" => name, "inputs" => inputs, "expected" => expected} <- delivery_vectors do
      payload = resolve_payload(document, inputs)

      assert Command.payload_hash(payload) == {:ok, hex(expected["payload_hash_hex"])},
             "#{name}: payload hash drifted from the frozen vector"

      record = delivery_record(inputs, hex(expected["payload_hash_hex"]))

      assert Command.hash(record) == {:ok, hex(expected["command_hash_hex"])},
             "#{name}: command record hash drifted from the frozen vector"

      delivery =
        record
        |> Map.put(:command_hash, hex(expected["command_hash_hex"]))
        |> Map.put(:payload, payload)

      delivery_bytes = hex(expected["command_delivery_hex"])
      assert Messages.encode(:command_delivery, delivery) == {:ok, delivery_bytes}
      assert Messages.decode(:command_delivery, delivery_bytes) == {:ok, delivery}
    end
  end

  test "the command_ack envelope binding the pinned delivery is pinned", %{document: document} do
    %{"binds" => binds, "inputs" => inputs, "expected" => expected} = document["command_ack"]

    bound =
      Enum.find(document["command_delivery"]["vectors"], &(&1["name"] == binds)) ||
        flunk("command_ack binds unknown delivery vector #{inspect(binds)}")

    status = ack_status(inputs["status"])
    reason = ack_reason(inputs["reason"])
    result = hex(inputs["result_hex"])

    assert Command.result_hash(%{status: status, reason: reason, result: result}) ==
             {:ok, hex(expected["result_hash_hex"])}

    ack =
      bound["inputs"]
      |> delivery_record(hex(bound["expected"]["payload_hash_hex"]))
      |> Map.drop([:expires_at_ms, :payload_hash])
      |> Map.merge(%{
        command_hash: hex(bound["expected"]["command_hash_hex"]),
        status: status,
        reason: reason,
        result_hash: hex(expected["result_hash_hex"]),
        result: result
      })

    ack_bytes = hex(expected["command_ack_hex"])
    assert Messages.encode(:command_ack, ack) == {:ok, ack_bytes}
    assert Messages.decode(:command_ack, ack_bytes) == {:ok, ack}
  end

  test "shared vector contains no plaintext credential material" do
    raw = File.read!(@vectors_path)

    refute raw =~ "psk"
    refute raw =~ "password"
    refute raw =~ "passphrase"
  end

  # --- Builders (mirrored in the one-off vector generator) ---

  defp build_reply(reply) do
    struct(ServerReply,
      protocol_version: Map.fetch!(reply, "protocol_version"),
      device_id: Map.fetch!(reply, "device_id"),
      command: build_command(Map.fetch!(reply, "command"))
    )
  end

  defp build_command(command) do
    struct(DeviceCommand,
      command_id: Map.get(command, "command_id", ""),
      assignment_id: Map.get(command, "assignment_id", ""),
      assignment_version: Map.get(command, "assignment_version", 0),
      assignment_hash: Map.get(command, "assignment_hash", ""),
      issued_at: build_timestamp(Map.get(command, "issued_at")),
      expires_at: build_timestamp(Map.get(command, "expires_at")),
      payload: build_payload(Map.fetch!(command, "payload"))
    )
  end

  defp build_payload(%{"race_assignment" => race}) do
    {:race_assignment,
     struct(RaceAssignment,
       boat_id: Map.fetch!(race, "boat_id"),
       device_id: Map.fetch!(race, "device_id"),
       race_plan_id: Map.fetch!(race, "race_plan_id"),
       race_session_id: Map.fetch!(race, "race_session_id"),
       race_recording_id: Map.fetch!(race, "race_recording_id"),
       official_start_time: build_timestamp(Map.get(race, "official_start_time")),
       expected_duration_seconds: Map.fetch!(race, "expected_duration_seconds"),
       start_line: build_line(Map.get(race, "start_line")),
       finish_line: build_line(Map.get(race, "finish_line")),
       course_marks: Enum.map(Map.fetch!(race, "course_marks"), &build_mark/1),
       shortened_course: Map.fetch!(race, "shortened_course"),
       shortened_final_mark_code: Map.fetch!(race, "shortened_final_mark_code"),
       active_mark_code: Map.fetch!(race, "active_mark_code"),
       sampling_rules: build_sampling_rules(Map.get(race, "sampling_rules")),
       route_request_id: Map.fetch!(race, "route_request_id"),
       route_geometry: Enum.map(Map.fetch!(race, "route_geometry"), &build_position/1),
       route_hash: Map.fetch!(race, "route_hash")
     )}
  end

  defp build_payload(%{"route_update" => route}) do
    {:route_update,
     struct(RouteUpdate,
       route_request_id: Map.fetch!(route, "route_request_id"),
       route_geometry: Enum.map(Map.fetch!(route, "route_geometry"), &build_position/1),
       route_hash: Map.fetch!(route, "route_hash"),
       active_mark_code: Map.fetch!(route, "active_mark_code")
     )}
  end

  defp build_payload(%{"active_waypoint_update" => waypoint}) do
    {:active_waypoint_update, struct(ActiveWaypointUpdate, active_mark_code: Map.fetch!(waypoint, "active_mark_code"))}
  end

  defp build_payload(%{"cancel_assignment" => cancel}) do
    {:cancel_assignment, struct(CancelAssignment, reason: Map.fetch!(cancel, "reason"))}
  end

  defp build_timestamp(nil), do: nil

  defp build_timestamp(%{"seconds" => seconds, "nanos" => nanos}) do
    struct(Google.Protobuf.Timestamp, seconds: seconds, nanos: nanos)
  end

  defp build_line(nil), do: nil

  defp build_line(%{"end_a" => end_a, "end_b" => end_b}) do
    struct(LineGeometry, end_a: build_position(end_a), end_b: build_position(end_b))
  end

  defp build_position(%{"latitude" => latitude, "longitude" => longitude}) do
    struct(LatLon, latitude: latitude, longitude: longitude)
  end

  defp build_sampling_rules(nil), do: nil

  defp build_sampling_rules(rules) do
    struct(SamplingRules,
      default_mode: sample_mode(Map.fetch!(rules, "default_mode")),
      race_mode: sample_mode(Map.fetch!(rules, "race_mode")),
      event_mode: sample_mode(Map.fetch!(rules, "event_mode")),
      start_window_seconds: Map.fetch!(rules, "start_window_seconds"),
      mark_proximity_meters: Map.fetch!(rules, "mark_proximity_meters"),
      finish_window_seconds: Map.fetch!(rules, "finish_window_seconds")
    )
  end

  defp build_mark(mark) do
    struct(CourseMark,
      code: Map.fetch!(mark, "code"),
      position: build_position(Map.fetch!(mark, "position")),
      rounding: rounding(Map.fetch!(mark, "rounding")),
      sequence: Map.fetch!(mark, "sequence")
    )
  end

  defp sample_mode("SAMPLE_MODE_OUTING_1HZ"), do: :SAMPLE_MODE_OUTING_1HZ
  defp sample_mode("SAMPLE_MODE_RACE_5HZ"), do: :SAMPLE_MODE_RACE_5HZ
  defp sample_mode("SAMPLE_MODE_EVENT_10HZ"), do: :SAMPLE_MODE_EVENT_10HZ

  defp rounding("MARK_ROUNDING_PORT"), do: :MARK_ROUNDING_PORT
  defp rounding("MARK_ROUNDING_STARBOARD"), do: :MARK_ROUNDING_STARBOARD
  defp rounding("MARK_ROUNDING_GATE"), do: :MARK_ROUNDING_GATE

  defp ack_status("applied"), do: :applied
  defp ack_reason("none"), do: :none

  defp resolve_payload(document, %{"payload_vector" => name}) do
    vector =
      Enum.find(document["vectors"], &(&1["name"] == name)) ||
        flunk("delivery payload references unknown vector #{inspect(name)}")

    hex(vector["expected"]["server_reply_hex"])
  end

  defp resolve_payload(_document, %{"payload_canonical" => value}) do
    assert {:ok, payload} = Canonical.encode(value)
    payload
  end

  defp delivery_record(inputs, payload_hash) do
    %{
      device_id: hex(inputs["device_id_hex"]),
      credential_epoch: inputs["credential_epoch"],
      storage_epoch: hex(inputs["storage_epoch_hex"]),
      required_generation: inputs["required_generation"],
      required_manifest_hash: hex(inputs["required_manifest_hash_hex"]),
      command_epoch: inputs["command_epoch"],
      command_sequence: inputs["command_sequence"],
      command_id: hex(inputs["command_id_hex"]),
      expires_at_ms: inputs["expires_at_ms"],
      payload_hash: payload_hash
    }
  end

  defp hex(value), do: Base.decode16!(value, case: :lower)
end
