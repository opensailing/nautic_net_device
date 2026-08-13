defmodule RacingOrg.Tracker.Pro.FirmwareValidation.ReceiptHealthTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.FirmwareValidation.ReceiptHealth

  test "projects exact control and telemetry round-trip statuses from injected readers" do
    assert %{control: :succeeded, telemetry: :pending} =
             ReceiptHealth.read(
               control_reader: fn -> :succeeded end,
               telemetry_reader: fn -> :pending end
             )
  end

  test "invalid and exceptional receipt readers fail closed" do
    assert %{control: :failed, telemetry: :failed} =
             ReceiptHealth.read(
               control_reader: fn -> :unexpected end,
               telemetry_reader: fn -> raise "telemetry unavailable" end
             )
  end

  test "an authenticated receipt succeeds only when the injected outbox acknowledgement succeeds" do
    receipt = %{stream: :telemetry, sequence: 1}
    parent = self()

    assert :succeeded =
             ReceiptHealth.acknowledge(receipt,
               acknowledger: fn received, opts ->
                 send(parent, {:acknowledged, received, opts})
                 {:ok, []}
               end
             )

    assert_receive {:acknowledged, ^receipt, [idempotent: true]}

    assert :failed =
             ReceiptHealth.acknowledge(receipt,
               acknowledger: fn _received, _opts -> {:error, :receipt_entry_not_found} end
             )

    assert :failed =
             ReceiptHealth.acknowledge(receipt,
               acknowledger: fn _received, _opts -> raise "owner unavailable" end
             )
  end
end
