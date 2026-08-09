defmodule RacingOrg.Tracker.Pro.DesiredState.OperationalGate.ViaAuthority do
  @moduledoc """
  Cooperative incarnation contract for a registry used in an operational lease.

  The returned incarnation process is a monotonic revocation token. A registry
  must terminate that process before changing the PID returned for the name,
  before restoring an earlier PID, and before losing its own authoritative
  state. Each new binding incarnation must return a new live token process.

  `OperationalGate` rejects Via registries that do not expose this contract.
  """

  @callback authority_snapshot(name :: term()) ::
              {:ok, owner_pid :: pid(), incarnation_pid :: pid()}
              | {:error, term()}
end
