defmodule RacingOrg.Tracker.Pro do
  @moduledoc """
  Documentation for RacingOrg.Tracker.Pro.
  """

  @doc """
  Returns a unique identifier string for this Nerves device.
  """
  def boat_identifier do
    # :inet.gethostname/0 always succeeds
    {:ok, charlist} = :inet.gethostname()
    to_string(charlist)
  end

  def git_commit do
    Application.get_env(:racing_org_tracker_pro, :git_commit)
  end

  @doc "The running NMEA 2000 VirtualDevice pid (set at boot), or `nil`."
  def virtual_device, do: :persistent_term.get({__MODULE__, :virtual_device}, nil)

  @doc false
  def put_virtual_device(pid), do: :persistent_term.put({__MODULE__, :virtual_device}, pid)

  @doc """
  Builds an upload `DataSet` for `data_points`, tagged with this device's
  identifier and the latest applied server-command acknowledgement (so RacingOrg
  can track which commands the device has applied). `opts` are passed through to
  `RacingOrg.Tracker.Protobuf.new_data_set/2` and override the defaults.
  """
  def data_set(data_points, opts \\ []) do
    base = [
      boat_identifier: boat_identifier(),
      ack: RacingOrg.Tracker.Pro.Commands.current_ack(),
      sample_mode: current_sample_mode(),
      race_phase: current_race_phase()
    ]

    RacingOrg.Tracker.Protobuf.new_data_set(data_points, Keyword.merge(base, opts))
  end

  defp current_sample_mode do
    RacingOrg.Tracker.Pro.Sampling.Mode.to_proto(RacingOrg.Tracker.Pro.Sampling.current_mode())
  catch
    :exit, _ -> :SAMPLE_MODE_UNSPECIFIED
  end

  defp current_race_phase do
    RacingOrg.Tracker.Pro.Sampling.Phase.to_proto(RacingOrg.Tracker.Pro.Sampling.current_phase())
  catch
    :exit, _ -> :RACE_PHASE_UNSPECIFIED
  end
end
