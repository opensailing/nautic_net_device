defmodule RacingOrg.Tracker.Pro.Commands.Ledger.Provider.PersistCheckpoints do
  @moduledoc """
  Force the named learner observers to flush their checkpoints to durable storage.

  The effect is idempotent per observer, so recovery re-runs it rather than
  leaving the intent ambiguous. See `Commands.Ledger.Provider.Checkpoints`.
  """

  use RacingOrg.Tracker.Pro.Commands.Ledger.Provider

  alias RacingOrg.Tracker.Pro.Commands.Ledger.Provider.Checkpoints
  alias RacingOrg.Tracker.Pro.Commands.Ledger.Registry

  @impl true
  def execute(intent, context), do: Checkpoints.run(:persist_now, decoded(intent), context)

  # Re-running an idempotent flush cannot corrupt what a first run produced, so
  # recovery re-runs rather than guessing whether the interrupted run landed.
  @impl true
  def recover(intent, context) do
    {:ok, result} = execute(intent, context)
    {:applied, result}
  end

  defp decoded(%{payload: payload}) do
    case Registry.decode_payload(payload) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> %{type: :persist_checkpoints, args: %{targets: []}}
    end
  end
end
