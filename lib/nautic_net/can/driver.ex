defmodule NauticNet.CAN.Driver do
  @moduledoc """
  The abstraction layer behind which the CAN bus physical layer can be implemented.
  """

  alias NauticNet.NMEA2000.Frame

  @doc """
  Configure and prepare the CAN bus driver for use.
  """
  @callback init(config :: keyword) :: :ok | :error

  @doc """
  Send a frame to the CAN bus.
  """
  @callback transmit_frame(frame :: Frame.t()) :: :ok
end
