defmodule RacingOrg.Tracker.Pro.Commands.Assignment do
  @moduledoc """
  The device's view of the active race assignment, built from applied
  `DeviceCommand`s.

  A `race_assignment` command establishes the assignment (course, start/finish
  geometry, marks, sampling rules, timing, IDs). Subsequent `route_update` and
  `active_waypoint_update` commands overlay the optimized route and active mark,
  and `cancel_assignment` marks it cancelled. The originating `RaceAssignment`
  payload is kept whole so later phases can read course/sampling/timing detail.
  """

  alias RacingOrg.Tracker.Protobuf.DeviceCommand

  @type t :: %__MODULE__{}

  defstruct [
    :assignment_id,
    :version,
    :hash,
    :command_id,
    :expires_at,
    :race_assignment,
    :active_mark_code,
    :route_geometry,
    :route_hash,
    :desired_state,
    cancelled: false
  ]

  @doc """
  Apply a command to the current assignment (`nil` if none yet).

  Returns `{:updated, assignment}` for assignment-bearing commands, or
  `:no_change` for commands that do not affect assignment state (and for
  route/waypoint/cancel commands that arrive with no active assignment).
  """
  def update(_current, %DeviceCommand{payload: {:race_assignment, race}} = command) do
    {:updated, from_command(command, race)}
  end

  def update(%__MODULE__{} = current, %DeviceCommand{payload: {:route_update, route}} = command) do
    updated = %{
      current
      | route_geometry: route.route_geometry,
        route_hash: route.route_hash,
        active_mark_code: blank_to_keep(route.active_mark_code, current.active_mark_code)
    }

    {:updated, stamp(updated, command)}
  end

  def update(%__MODULE__{} = current, %DeviceCommand{payload: {:active_waypoint_update, waypoint}} = command) do
    {:updated, stamp(%{current | active_mark_code: waypoint.active_mark_code}, command)}
  end

  def update(%__MODULE__{} = current, %DeviceCommand{payload: {:cancel_assignment, _}} = command) do
    {:updated, stamp(%{current | cancelled: true}, command)}
  end

  # noop / server_time_config / manifest / missing_chunk, or route/waypoint/cancel
  # with no active assignment.
  def update(_current, %DeviceCommand{}), do: :no_change

  defp from_command(%DeviceCommand{} = command, race) do
    %__MODULE__{
      assignment_id: command.assignment_id,
      version: command.assignment_version,
      hash: command.assignment_hash,
      command_id: command.command_id,
      expires_at: command.expires_at,
      race_assignment: race,
      active_mark_code: race.active_mark_code,
      route_geometry: race.route_geometry,
      route_hash: race.route_hash,
      cancelled: false
    }
  end

  defp stamp(%__MODULE__{} = assignment, %DeviceCommand{} = command) do
    %{
      assignment
      | version: command.assignment_version,
        command_id: command.command_id,
        hash: command.assignment_hash
    }
  end

  defp blank_to_keep(value, _keep) when value not in [nil, ""], do: value
  defp blank_to_keep(_value, keep), do: keep
end
