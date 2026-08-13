defmodule RacingOrg.Tracker.Pro.WiFiManager.ReconnectConfirmationTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.FirmwareValidation.ReceiptEvidence
  alias RacingOrg.Tracker.Pro.SecureTransport.Session
  alias RacingOrg.Tracker.Pro.SecureTransport.SessionHolder
  alias RacingOrg.Tracker.Pro.WiFiManager.ReconnectConfirmation

  setup do
    key = {__MODULE__, make_ref()}
    on_exit(fn -> ReceiptEvidence.reset(key: key) end)

    holder = start_supervised!({SessionHolder, name: nil}, id: {:holder, make_ref()})
    %{key: key, holder: holder}
  end

  defp publish_session(holder) do
    session =
      Session.new(
        role: :initiator,
        session_id: :crypto.strong_rand_bytes(16),
        epoch: 0,
        credential_epoch: 4,
        out_key: :binary.copy(<<0xAA>>, 32),
        in_key: :binary.copy(<<0xBB>>, 32)
      )

    {:ok, published} = SessionHolder.publish(holder, session)
    published
  end

  test "a control receipt round trip after the trial start confirms immediately", ctx do
    started_at_ms = System.monotonic_time(:millisecond)
    Process.sleep(5)
    assert :ok = ReceiptEvidence.record(:control, key: ctx.key)

    assert :ok =
             ReconnectConfirmation.confirm(
               session_holder: ctx.holder,
               receipt_evidence_key: ctx.key,
               deadline_ms: 500,
               poll_ms: 10,
               started_at_ms: started_at_ms
             )
  end

  test "a newly established authenticated session confirms without receipt evidence", ctx do
    baseline = publish_session(ctx.holder)

    task =
      Task.async(fn ->
        ReconnectConfirmation.confirm(
          session_holder: ctx.holder,
          receipt_evidence_key: ctx.key,
          deadline_ms: 2_000,
          poll_ms: 10
        )
      end)

    Process.sleep(50)
    {:ok, _replacement} = SessionHolder.publish(ctx.holder, replacement_session(), baseline.generation)

    assert Task.await(task, 3_000) == :ok
  end

  test "a stale pre-trial session without new evidence never confirms", ctx do
    _baseline = publish_session(ctx.holder)

    assert {:error, :wifi_reconnect_unconfirmed} =
             ReconnectConfirmation.confirm(
               session_holder: ctx.holder,
               receipt_evidence_key: ctx.key,
               deadline_ms: 120,
               poll_ms: 10
             )
  end

  test "pre-trial receipt evidence does not count", ctx do
    assert :ok = ReceiptEvidence.record(:control, key: ctx.key)
    Process.sleep(15)

    assert {:error, :wifi_reconnect_unconfirmed} =
             ReconnectConfirmation.confirm(
               session_holder: ctx.holder,
               receipt_evidence_key: ctx.key,
               deadline_ms: 120,
               poll_ms: 10,
               started_at_ms: System.monotonic_time(:millisecond)
             )
  end

  defp replacement_session do
    Session.new(
      role: :initiator,
      session_id: :crypto.strong_rand_bytes(16),
      epoch: 0,
      credential_epoch: 4,
      out_key: :binary.copy(<<0xCC>>, 32),
      in_key: :binary.copy(<<0xDD>>, 32)
    )
  end
end
