defmodule RacingOrg.Tracker.Pro.Commands.Ledger.Provider.Noop do
  @moduledoc """
  The liveness command: it has no external effect at all.

  Recovery is trivially determinate. A no-op that may or may not have "run" is
  observationally identical either way, so a pending intent is completed rather
  than left ambiguous — there is no external state a crash could have left half
  applied.
  """

  use RacingOrg.Tracker.Pro.Commands.Ledger.Provider

  @impl true
  def execute(_intent, _context), do: {:ok, %{outcome: :applied}}

  @impl true
  def recover(_intent, _context), do: {:applied, %{outcome: :applied}}
end
