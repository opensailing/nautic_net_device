defmodule RacingOrg.Tracker.Pro.CAN.Driver do
  @moduledoc """
  The abstraction layer behind which the CAN bus physical layer can be implemented.
  """

  alias RacingOrg.Tracker.NMEA2000.Frame

  @doc """
  Configure and prepare the CAN bus driver for use.
  """
  @callback init(config :: keyword) :: :ok | :error

  @doc """
  Send a frame to the CAN bus.
  """
  @callback transmit_frame(frame :: Frame.t()) :: :ok
end
