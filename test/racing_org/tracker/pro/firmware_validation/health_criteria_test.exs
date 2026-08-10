defmodule RacingOrg.Tracker.Pro.FirmwareValidation.HealthCriteriaTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.FirmwareValidation.HealthCriteria

  @git_sha "0123456789abcdef0123456789abcdef01234567"
  @other_git_sha "abcdef0123456789abcdef0123456789abcdef01"

  test "returns ready only when every health criterion passes and soak has elapsed" do
    assert :ready = HealthCriteria.evaluate(healthy_snapshot(), expected_target())
  end

  test "reports each unmet health criterion with its stable diagnostic code" do
    cases = [
      {fn snapshot -> put_in(snapshot, [:firmware, :version], "0.8.1") end,
       unmet(:firmware_version, :firmware_version_mismatch)},
      {fn snapshot -> put_in(snapshot, [:firmware, :git_sha], @other_git_sha) end,
       unmet(:firmware_git_sha, :firmware_git_sha_mismatch)},
      {fn snapshot -> put_in(snapshot, [:session, :authenticated], false) end,
       unmet(:session_authentication, :session_not_authenticated)},
      {fn snapshot -> put_in(snapshot, [:session, :credential_epoch], 6) end,
       unmet(:credential_epoch, :credential_epoch_mismatch)},
      {fn snapshot -> put_in(snapshot, [:desired_state, :generation], 41) end,
       unmet(:desired_generation, :desired_generation_mismatch)},
      {fn snapshot -> put_in(snapshot, [:desired_state, :effective], false) end,
       unmet(:desired_generation_effective, :desired_generation_not_effective)},
      {fn snapshot -> put_in(snapshot, [:desired_state, :compatible], false) end,
       unmet(:desired_generation_compatibility, :desired_generation_incompatible)},
      {fn snapshot -> put_in(snapshot, [:process_health, :supervisor], :unhealthy) end,
       unmet(:supervisor_health, :supervisor_unhealthy)},
      {fn snapshot -> put_in(snapshot, [:process_health, :owner], :unhealthy) end,
       unmet(:owner_health, :owner_unhealthy)},
      {fn snapshot -> put_in(snapshot, [:receipts, :control], :pending) end,
       unmet(:control_receipt_round_trip, :control_receipt_incomplete)},
      {fn snapshot -> put_in(snapshot, [:receipts, :telemetry], :failed) end,
       unmet(:telemetry_receipt_round_trip, :telemetry_receipt_incomplete)},
      {fn snapshot -> put_in(snapshot, [:outbox, :corrupt], true) end, unmet(:outbox_integrity, :outbox_corrupt)},
      {fn snapshot -> put_in(snapshot, [:outbox, :critical_pressure], true) end,
       unmet(:outbox_pressure, :outbox_critical_pressure)},
      {fn snapshot -> put_in(snapshot, [:timing, :observed_at_ms], 9_999) end,
       unmet(:soak_period, :soak_period_incomplete)}
    ]

    Enum.each(cases, fn {mutate, expected_unmet} ->
      assert {:pending, [^expected_unmet]} =
               healthy_snapshot()
               |> mutate.()
               |> HealthCriteria.evaluate(expected_target())
    end)
  end

  test "accepts only closed process-health and receipt status registries" do
    assert HealthCriteria.status_registry() == %{
             process_health: [:healthy, :unhealthy],
             receipt_round_trip: [:succeeded, :pending, :failed],
             result: [:ready, :pending, :rollback_required]
           }

    for {path, invalid_status} <- [
          {[:process_health, :supervisor], :starting},
          {[:process_health, :owner], true},
          {[:receipts, :control], :unknown},
          {[:receipts, :telemetry], true}
        ] do
      snapshot = put_in(healthy_snapshot(), path, invalid_status)

      assert {:pending, [unmet(:input, :invalid_snapshot)]} ==
               HealthCriteria.evaluate(snapshot, expected_target())
    end
  end

  test "receipt round trips must succeed rather than merely avoid failure" do
    for receipt <- [:control, :telemetry], status <- [:pending, :failed] do
      expected =
        case receipt do
          :control -> unmet(:control_receipt_round_trip, :control_receipt_incomplete)
          :telemetry -> unmet(:telemetry_receipt_round_trip, :telemetry_receipt_incomplete)
        end

      snapshot = put_in(healthy_snapshot(), [:receipts, receipt], status)
      assert {:pending, [^expected]} = HealthCriteria.evaluate(snapshot, expected_target())
    end
  end

  test "orders multiple failures deterministically by the closed criteria registry" do
    snapshot =
      healthy_snapshot()
      |> put_in([:firmware, :version], "0.8.1")
      |> put_in([:session, :authenticated], false)
      |> put_in([:desired_state, :effective], false)
      |> put_in([:process_health, :owner], :unhealthy)
      |> put_in([:receipts, :control], :failed)
      |> put_in([:outbox, :critical_pressure], true)

    assert {:pending,
            [
              unmet(:firmware_version, :firmware_version_mismatch),
              unmet(:session_authentication, :session_not_authenticated),
              unmet(:desired_generation_effective, :desired_generation_not_effective),
              unmet(:owner_health, :owner_unhealthy),
              unmet(:control_receipt_round_trip, :control_receipt_incomplete),
              unmet(:outbox_pressure, :outbox_critical_pressure)
            ]} == HealthCriteria.evaluate(snapshot, expected_target())
  end

  test "the soak boundary is inclusive" do
    just_before = put_in(healthy_snapshot(), [:timing, :observed_at_ms], 9_999)
    at_boundary = put_in(healthy_snapshot(), [:timing, :observed_at_ms], 10_000)

    assert {:pending, [unmet(:soak_period, :soak_period_incomplete)]} ==
             HealthCriteria.evaluate(just_before, expected_target())

    assert :ready = HealthCriteria.evaluate(at_boundary, expected_target())
  end

  test "failures are retryable before the deadline and require rollback at the exact deadline" do
    failing = put_in(healthy_snapshot(), [:receipts, :control], :pending)
    expected = [unmet(:control_receipt_round_trip, :control_receipt_incomplete)]

    assert {:pending, ^expected} =
             failing
             |> put_in([:timing, :observed_at_ms], 19_999)
             |> HealthCriteria.evaluate(expected_target())

    assert {:rollback_required, ^expected} =
             failing
             |> put_in([:timing, :observed_at_ms], 20_000)
             |> HealthCriteria.evaluate(expected_target())

    assert {:rollback_required, ^expected} =
             failing
             |> put_in([:timing, :observed_at_ms], 20_001)
             |> HealthCriteria.evaluate(expected_target())
  end

  test "a fully healthy snapshot remains ready at or after the deadline" do
    assert :ready =
             healthy_snapshot()
             |> put_in([:timing, :observed_at_ms], 20_000)
             |> HealthCriteria.evaluate(expected_target())

    assert :ready =
             healthy_snapshot()
             |> put_in([:timing, :observed_at_ms], 20_001)
             |> HealthCriteria.evaluate(expected_target())
  end

  test "malformed snapshots fail closed without raising" do
    malformed_snapshots = [
      Map.delete(healthy_snapshot(), :session),
      put_in(healthy_snapshot(), [:firmware, :version], nil),
      put_in(healthy_snapshot(), [:firmware, :git_sha], "short"),
      put_in(healthy_snapshot(), [:session, :authenticated], "yes"),
      put_in(healthy_snapshot(), [:session, :credential_epoch], -1),
      put_in(healthy_snapshot(), [:desired_state, :generation], 0),
      put_in(healthy_snapshot(), [:desired_state, :effective], :yes),
      put_in(healthy_snapshot(), [:desired_state, :compatible], 1),
      put_in(healthy_snapshot(), [:outbox, :corrupt], "false"),
      put_in(healthy_snapshot(), [:outbox, :critical_pressure], nil),
      put_in(healthy_snapshot(), [:timing, :soak_started_at_ms], 10_001),
      Map.put(healthy_snapshot(), :metadata, %{secret: "must-not-be-accepted"}),
      update_in(healthy_snapshot(), [:receipts], &Map.put(&1, :receipt_payload, "must-not-be-accepted"))
    ]

    Enum.each(malformed_snapshots, fn snapshot ->
      assert {:pending, [unmet(:input, :invalid_snapshot)]} ==
               HealthCriteria.evaluate(snapshot, expected_target())
    end)

    assert {:rollback_required, [unmet(:input, :invalid_snapshot)]} ==
             HealthCriteria.evaluate(:not_a_snapshot, expected_target())

    assert {:rollback_required, [unmet(:input, :invalid_snapshot)]} ==
             healthy_snapshot()
             |> Map.delete(:timing)
             |> HealthCriteria.evaluate(expected_target())

    assert {:rollback_required, [unmet(:input, :invalid_snapshot)]} ==
             healthy_snapshot()
             |> put_in([:timing, :observed_at_ms], "now")
             |> HealthCriteria.evaluate(expected_target())
  end

  test "malformed targets fail closed immediately" do
    malformed_targets = [
      %{},
      Map.put(expected_target(), :metadata, :not_allowed),
      put_in(expected_target(), [:firmware, :version], nil),
      put_in(expected_target(), [:firmware, :git_sha], "short"),
      update_in(expected_target(), [:firmware], &Map.put(&1, :release_secret, "not-allowed")),
      Map.put(expected_target(), :credential_epoch, -1),
      Map.put(expected_target(), :desired_generation, 0),
      Map.put(expected_target(), :soak_period_ms, 0),
      Map.put(expected_target(), :deadline_at_ms, -1)
    ]

    Enum.each(malformed_targets, fn target ->
      assert {:rollback_required, [unmet(:input, :invalid_target)]} ==
               HealthCriteria.evaluate(healthy_snapshot(), target)
    end)
  end

  test "diagnostics are closed, sanitized, and contain no observed values or secrets" do
    secret = "credential-token-do-not-leak"

    snapshot =
      healthy_snapshot()
      |> put_in([:firmware, :version], secret)
      |> Map.put(:metadata, %{secret: secret})

    result = HealthCriteria.evaluate(snapshot, expected_target())

    assert result == {:pending, [unmet(:input, :invalid_snapshot)]}
    refute inspect(result) =~ secret

    assert HealthCriteria.criteria() == [
             :firmware_version,
             :firmware_git_sha,
             :session_authentication,
             :credential_epoch,
             :desired_generation,
             :desired_generation_effective,
             :desired_generation_compatibility,
             :supervisor_health,
             :owner_health,
             :control_receipt_round_trip,
             :telemetry_receipt_round_trip,
             :outbox_integrity,
             :outbox_pressure,
             :soak_period,
             :input
           ]

    assert HealthCriteria.diagnostic_codes() == [
             :firmware_version_mismatch,
             :firmware_git_sha_mismatch,
             :session_not_authenticated,
             :credential_epoch_mismatch,
             :desired_generation_mismatch,
             :desired_generation_not_effective,
             :desired_generation_incompatible,
             :supervisor_unhealthy,
             :owner_unhealthy,
             :control_receipt_incomplete,
             :telemetry_receipt_incomplete,
             :outbox_corrupt,
             :outbox_critical_pressure,
             :soak_period_incomplete,
             :invalid_snapshot,
             :invalid_target
           ]

    assert Enum.all?(HealthCriteria.diagnostic_codes(), &is_atom/1)
  end

  test "unmet criteria expose only closed criterion and diagnostic-code keys" do
    {:pending, unmet_criteria} =
      healthy_snapshot()
      |> put_in([:firmware, :version], "0.8.1")
      |> put_in([:receipts, :telemetry], :pending)
      |> HealthCriteria.evaluate(expected_target())

    assert Enum.all?(unmet_criteria, fn unmet_criterion ->
             Map.keys(unmet_criterion) |> Enum.sort() == [:criterion, :diagnostic_code]
           end)
  end

  defp healthy_snapshot do
    %{
      firmware: %{version: "0.8.0", git_sha: @git_sha},
      session: %{authenticated: true, credential_epoch: 7},
      desired_state: %{generation: 42, effective: true, compatible: true},
      process_health: %{supervisor: :healthy, owner: :healthy},
      receipts: %{control: :succeeded, telemetry: :succeeded},
      outbox: %{corrupt: false, critical_pressure: false},
      timing: %{observed_at_ms: 10_000, soak_started_at_ms: 5_000}
    }
  end

  defp expected_target do
    %{
      firmware: %{version: "0.8.0", git_sha: @git_sha},
      credential_epoch: 7,
      desired_generation: 42,
      soak_period_ms: 5_000,
      deadline_at_ms: 20_000
    }
  end

  defp unmet(criterion, diagnostic_code) do
    %{criterion: criterion, diagnostic_code: diagnostic_code}
  end
end
