defmodule RacingOrg.Tracker.Pro.HardwareIdentity do
  @moduledoc """
  Provider seam for reading a tracker hardware identity.

  Implementations publish a stable provider name and return that provider's canonical
  identifier. Callers must treat read failures as fail-closed bootstrap errors.
  """

  @type provider :: binary()
  @type hardware_identifier :: binary()
  @type error_reason :: term()

  @doc "The stable provider name carried by identity protocol messages."
  @callback provider() :: provider()

  @doc "Read and canonicalize the hardware identifier."
  @callback identifier() :: {:ok, hardware_identifier()} | {:error, error_reason()}
end
