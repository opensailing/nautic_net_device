defmodule RacingOrg.Tracker.Pro.SecureTransport.BootstrapStateStatusTest do
  @moduledoc """
  `BootstrapState.sanitized_status/1` is the operator-facing projection of the
  provisioning state machine: a closed key set safe for serial-console
  diagnostics. Authority material, recovery challenges, and legacy
  registration payloads must never appear in it — only phases, epochs,
  counters, and a truncated hardware-identity digest.
  """
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.SecureTransport.BootstrapState

  @digest :crypto.hash(:sha256, "hw-identity")

  defp populated_state do
    %BootstrapState{
      phase: :effective,
      hardware_identity_digest: @digest,
      authority: %{
        credential_epoch: 4,
        receipt: "authority-receipt-secret-bytes",
        device_public_key: :crypto.strong_rand_bytes(32)
      },
      verified_credential_epoch: 4,
      previous_authority: %{credential_epoch: 3, receipt: "previous-receipt-secret"},
      recovery: %{challenge: "recovery-challenge-secret", nonce: :crypto.strong_rand_bytes(16)},
      blocked_reason: nil,
      retry_count: 2,
      legacy_marker: false,
      legacy_registration: %{token: "legacy-registration-token-secret"}
    }
  end

  test "returns the closed key set with epoch, counters, and truncated digest" do
    status = BootstrapState.sanitized_status(populated_state())

    assert status |> Map.keys() |> Enum.sort() ==
             [:blocked_reason, :credential_epoch, :hardware_identity, :legacy, :phase, :recovery_pending, :retry_count]

    assert status.phase == :effective
    assert status.credential_epoch == 4
    assert status.retry_count == 2
    assert status.blocked_reason == nil
    assert status.legacy == false
    assert status.recovery_pending == true
    assert status.hardware_identity == @digest |> Base.encode16(case: :lower) |> String.slice(0, 12)
  end

  test "never leaks authority, recovery, or registration material" do
    rendered = populated_state() |> BootstrapState.sanitized_status() |> inspect(limit: :infinity)

    refute rendered =~ "authority-receipt-secret-bytes"
    refute rendered =~ "previous-receipt-secret"
    refute rendered =~ "recovery-challenge-secret"
    refute rendered =~ "legacy-registration-token-secret"
    refute rendered =~ @digest |> Base.encode16(case: :lower) |> String.slice(12, 52)
  end

  test "a blank state reports absent identity and epoch without raising" do
    status = BootstrapState.sanitized_status(%BootstrapState{})

    assert status.phase == :uninitialized
    assert status.credential_epoch == nil
    assert status.hardware_identity == nil
    assert status.recovery_pending == false
  end

  test "a structured blocked reason collapses to its category atom" do
    blocked = %BootstrapState{phase: :blocked, blocked_reason: {:registration_rejected, %{detail: "/data/path"}}}

    status = BootstrapState.sanitized_status(blocked)

    assert status.blocked_reason == :registration_rejected
    refute inspect(status) =~ "/data/path"

    assert BootstrapState.sanitized_status(%BootstrapState{blocked_reason: :storage_untrusted}).blocked_reason ==
             :storage_untrusted

    assert BootstrapState.sanitized_status(%BootstrapState{blocked_reason: %{odd: "shape"}}).blocked_reason == :blocked
  end
end
