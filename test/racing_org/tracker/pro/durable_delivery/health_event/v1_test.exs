defmodule RacingOrg.Tracker.Pro.DurableDelivery.HealthEvent.V1Test do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.DurableDelivery.HealthEvent.V1

  @firmware_version "0.7.0-rc.1"
  @firmware_git_sha String.duplicate("a", 40)
  @manifest_hash :binary.copy(<<0xA5>>, 32)
  @target %{
    credential_epoch: 7,
    desired_generation: 42,
    manifest_hash: @manifest_hash
  }

  test "round trips every closed firmware-validation event deterministically" do
    events = [
      event(:validation_pending, %{reason_code: :soak_period_incomplete}),
      event(:validation_succeeded),
      event(:validation_failed, %{reason_code: :firmware_validation_failed}),
      event(:rollback_deadline_expired, %{reason_code: :rollback_deadline_expired}),
      event(:required_processes_unhealthy, %{reason_code: :owner_unhealthy}),
      event(:outbox_unhealthy, %{reason_code: :outbox_not_writable}),
      event(:receipt_progress, %{stream: :telemetry, cumulative_sequence: 91})
    ]

    for health_event <- events do
      assert {:ok, first} = V1.encode(health_event)
      assert {:ok, second} = V1.encode(rebuild_in_reverse_order(health_event))
      assert first == second
      assert {1, :tracker_health_event, ^health_event} = :erlang.binary_to_term(first, [:safe])
      assert {:ok, ^health_event} = V1.decode(first)
    end
  end

  test "exposes the closed event, stream, and reason registries" do
    assert V1.event_types() == [
             :validation_pending,
             :validation_succeeded,
             :validation_failed,
             :rollback_deadline_expired,
             :required_processes_unhealthy,
             :outbox_unhealthy,
             :receipt_progress
           ]

    assert V1.receipt_streams() == [:control, :telemetry]
    assert :owner_unhealthy in V1.reason_codes()
    assert :outbox_corrupt in V1.reason_codes()
    assert :firmware_validation_failed in V1.reason_codes()
    assert :rollback_deadline_expired in V1.reason_codes()
    assert Enum.all?(V1.reason_codes(), &is_atom/1)
  end

  test "rejects arbitrary metadata, unknown events, and variant key drift" do
    valid = event(:validation_succeeded)

    assert {:error, :invalid_health_event} = V1.encode(Map.put(valid, :metadata, %{note: "anything"}))
    assert {:error, :invalid_health_event} = V1.encode(event(:generic, %{status: :healthy}))

    assert {:error, :invalid_health_event} =
             V1.encode(
               event(:receipt_progress, %{stream: :telemetry, cumulative_sequence: 1, payload_hash: <<0::256>>})
             )

    assert {:error, :invalid_health_event} =
             V1.encode(event(:outbox_unhealthy, %{reason_code: :outbox_corrupt, path: "/data/outbox"}))

    assert {:error, :invalid_health_event} =
             V1.encode(event(:validation_succeeded, %{reason_code: :ready}))
  end

  test "rejects secret-bearing keys and textual values before encoding" do
    assert {:error, :secret_bearing_health_event} =
             event(:validation_succeeded)
             |> Map.put(:private_key, "not-for-health")
             |> V1.encode()

    assert {:error, :secret_bearing_health_event} =
             event(:validation_succeeded)
             |> Map.put(:firmware_version, "token=tracker-secret")
             |> V1.encode()

    assert {:error, :secret_bearing_health_event} =
             event(:validation_succeeded)
             |> Map.put(:firmware_version, "-----BEGIN PRIVATE KEY-----")
             |> V1.encode()

    assert {:error, :secret_bearing_health_event} =
             event(:validation_succeeded)
             |> Map.put("authorization", "Bearer abc")
             |> V1.encode()
  end

  test "rejects malformed common fields and target authority" do
    invalid_events = [
      event(:validation_succeeded) |> Map.put(:occurred_at_ms, -1),
      event(:validation_succeeded) |> Map.put(:firmware_version, ""),
      event(:validation_succeeded) |> Map.put(:firmware_git_sha, String.duplicate("A", 40)),
      event(:validation_succeeded) |> put_in([:target, :credential_epoch], -1),
      event(:validation_succeeded) |> put_in([:target, :desired_generation], 0),
      event(:validation_succeeded) |> put_in([:target, :manifest_hash], <<0>>),
      event(:validation_succeeded) |> put_in([:target, :device_id], <<1::128>>)
    ]

    for invalid <- invalid_events do
      assert {:error, :invalid_health_event} = V1.encode(invalid)
    end
  end

  test "rejects reasons that do not belong to the exact event variant" do
    invalid_events = [
      event(:validation_pending, %{reason_code: :firmware_validation_failed}),
      event(:validation_failed, %{reason_code: :outbox_not_writable}),
      event(:rollback_deadline_expired, %{reason_code: :soak_period_incomplete}),
      event(:required_processes_unhealthy, %{reason_code: :outbox_corrupt}),
      event(:outbox_unhealthy, %{reason_code: :owner_unhealthy}),
      event(:receipt_progress, %{stream: :telemetry, cumulative_sequence: 1, reason_code: :telemetry_receipt_incomplete})
    ]

    for invalid <- invalid_events do
      assert {:error, :invalid_health_event} = V1.encode(invalid)
    end
  end

  test "rejects malformed authenticated receipt progress" do
    invalid_events = [
      event(:receipt_progress, %{stream: :health, cumulative_sequence: 1}),
      event(:receipt_progress, %{stream: :telemetry, cumulative_sequence: -1}),
      event(:receipt_progress, %{stream: :telemetry, cumulative_sequence: 0x1_0000_0000_0000_0000})
    ]

    for invalid <- invalid_events do
      assert {:error, :invalid_health_event} = V1.encode(invalid)
    end
  end

  test "decode rejects future versions, compressed payloads, trailing bytes, and non-payload terms" do
    health_event = event(:validation_succeeded)

    future = :erlang.term_to_binary({2, :tracker_health_event, health_event}, [:deterministic])
    compressed = :erlang.term_to_binary({1, :tracker_health_event, health_event}, compressed: 9)
    trailing = :erlang.term_to_binary({1, :tracker_health_event, health_event}, [:deterministic]) <> <<0>>

    assert {:error, :unsupported_health_event_version} = V1.decode(future)
    assert {:error, :invalid_health_event_payload} = V1.decode(compressed)
    assert {:error, :invalid_health_event_payload} = V1.decode(trailing)
    atom_binary = String.replace(future, "validation_succeeded", "validation_mystery!!")

    assert {:error, :invalid_health_event_payload} = V1.decode(:erlang.term_to_binary({1, :other, health_event}))
    assert {:error, :invalid_health_event_payload} = V1.decode(atom_binary)
    assert {:error, :invalid_health_event_payload} = V1.decode(:not_binary)
  end

  defp event(event_type, extra \\ %{}) do
    Map.merge(
      %{
        event_type: event_type,
        occurred_at_ms: 123,
        firmware_version: @firmware_version,
        firmware_git_sha: @firmware_git_sha,
        target: @target
      },
      extra
    )
  end

  defp rebuild_in_reverse_order(map) do
    map
    |> Enum.reverse()
    |> Map.new(fn
      {key, value} when is_map(value) -> {key, rebuild_in_reverse_order(value)}
      pair -> pair
    end)
  end
end
