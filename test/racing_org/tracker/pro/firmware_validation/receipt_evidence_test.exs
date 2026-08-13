defmodule RacingOrg.Tracker.Pro.FirmwareValidation.ReceiptEvidenceTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.FirmwareValidation.ReceiptEvidence

  setup do
    key = {__MODULE__, make_ref()}
    on_exit(fn -> ReceiptEvidence.reset(key: key) end)
    %{key: key}
  end

  test "both classes start pending and become succeeded once recorded", %{key: key} do
    assert ReceiptEvidence.status(:control, key: key) == :pending
    assert ReceiptEvidence.status(:telemetry, key: key) == :pending

    assert :ok = ReceiptEvidence.record(:control, key: key)
    assert ReceiptEvidence.status(:control, key: key) == :succeeded
    assert ReceiptEvidence.status(:telemetry, key: key) == :pending

    assert :ok = ReceiptEvidence.record(:telemetry, key: key)
    assert ReceiptEvidence.status(:telemetry, key: key) == :succeeded
  end

  test "evidence older than the freshness window degrades to pending", %{key: key} do
    assert :ok = ReceiptEvidence.record(:control, key: key)
    assert ReceiptEvidence.status(:control, key: key, freshness_ms: 3_600_000) == :succeeded

    Process.sleep(15)
    assert ReceiptEvidence.status(:control, key: key, freshness_ms: 5) == :pending
  end

  test "recorded_after?/2 anchors evidence to a monotonic start point", %{key: key} do
    before_ms = System.monotonic_time(:millisecond)
    refute ReceiptEvidence.recorded_after?(:control, before_ms, key: key)

    assert :ok = ReceiptEvidence.record(:control, key: key)
    assert ReceiptEvidence.recorded_after?(:control, before_ms, key: key)

    later_ms = System.monotonic_time(:millisecond) + 60_000
    refute ReceiptEvidence.recorded_after?(:control, later_ms, key: key)
  end

  test "unknown classes are inert and never crash", %{key: key} do
    assert :ok = ReceiptEvidence.record(:unknown, key: key)
    assert ReceiptEvidence.status(:unknown, key: key) == :pending
    refute ReceiptEvidence.recorded_after?(:unknown, 0, key: key)
  end
end
