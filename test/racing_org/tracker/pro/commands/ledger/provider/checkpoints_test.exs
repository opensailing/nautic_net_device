defmodule RacingOrg.Tracker.Pro.Commands.Ledger.Provider.CheckpointsTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.Commands.Ledger.Provider.Checkpoints

  defmodule ThrowingObserver do
    def persist_now(_server), do: throw(:observer_failed)
    def sync_now(_server), do: throw(:observer_failed)
  end

  test "normalizes thrown observer failures without escaping the durable executor" do
    context = %{calibration: {ThrowingObserver, :observer}}
    intent = %{args: %{targets: [:calibration]}}

    for operation <- [:persist_now, :sync_now] do
      assert {:ok, %{outcome: :failed, targets: %{"calibration" => "unavailable"}}} =
               Checkpoints.run(operation, intent, context)
    end
  end
end
