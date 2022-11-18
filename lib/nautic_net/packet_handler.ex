defmodule NauticNet.PacketHandler do
  @moduledoc """
  Callback module for dealing with business logic after a known NMEA2000 packet has been fully received and decoded.
  """

  alias NauticNet.NMEA2000.Packet

  @doc """
  Prepare the packet handler for use. The result of this function will be
  passed as the `config` argument to `handle_packet/2`.
  """
  @callback init(opts :: term) :: term

  @doc """
  Do something (quickly, please!) with a fully-decoded NMEA2000 packet.

  Beware that this callback is run within the CAN server process, and we don't want to block that,
  so this callback function should do as little as possible.
  """
  @callback handle_packet(packet :: Packet.t(), config :: term) :: term

  @doc """
  The CAN interface device has closed its stream and is no longer available.
  """
  @callback handle_closed(config :: term) :: term
end
