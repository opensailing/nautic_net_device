defmodule RacingOrg.Tracker.Pro.DesiredState.OutputFence do
  @moduledoc """
  Fail-closed external-output fence over the operational gate.

  Output hot paths (telemetry, NMEA broadcasters, estimator publication) consult
  an injected zero-arity fence before emitting. The production fence is
  `OperationalGate.output_permitted?/0`: open gate permits, closed gate fences
  once v1 desired-state authority exists, and incarnations that never
  established authority keep emitting (the legacy carve-out). A raising or
  malformed fence fails closed.
  """

  alias RacingOrg.Tracker.Pro.DesiredState.OperationalGate

  @doc "The production fence."
  @spec default() :: (-> boolean())
  def default, do: &OperationalGate.output_permitted?/0

  @doc "Evaluate a fence, failing closed on faults or malformed fences."
  @spec permitted?((-> boolean()) | term()) :: boolean()
  def permitted?(fence) when is_function(fence, 0) do
    fence.() == true
  rescue
    _exception -> false
  catch
    _kind, _reason -> false
  end

  def permitted?(_fence), do: false
end
