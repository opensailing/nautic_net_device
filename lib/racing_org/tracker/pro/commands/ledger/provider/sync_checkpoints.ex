defmodule RacingOrg.Tracker.Pro.Commands.Ledger.Provider.SyncCheckpoints do
  @moduledoc """
  Force the named learner observers to submit their checkpoints upstream.

  The effect is idempotent per observer (a re-submitted checkpoint is deduplicated
  by the durable delivery layer), so recovery re-runs it rather than leaving the
  intent ambiguous. See `Commands.Ledger.Provider.Checkpoints`.
  """

  use RacingOrg.Tracker.Pro.Commands.Ledger.Provider

  alias RacingOrg.Tracker.Pro.Commands.Ledger.Provider.Checkpoints
  alias RacingOrg.Tracker.Pro.Commands.Ledger.Registry

  @impl true
  def execute(intent, context), do: Checkpoints.run(:sync_now, decoded(intent), context)

  # Re-submitting an idempotent checkpoint is deduplicated downstream, so recovery
  # re-runs rather than guessing whether the interrupted run landed.
  @impl true
  def recover(intent, context) do
    {:ok, result} = execute(intent, context)
    {:applied, result}
  end

  defp decoded(%{payload: payload}) do
    case Registry.decode_payload(payload) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> %{type: :sync_checkpoints, args: %{targets: []}}
    end
  end
end
