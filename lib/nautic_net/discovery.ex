defmodule NauticNet.Discovery do
  @moduledoc """
  Handles the discovery and lookup of metadata for devices on the NMEA2000 network.
  """
  alias NauticNet.Discovery

  @doc false
  def child_spec(config) do
    %{
      id: __MODULE__,
      start: {Discovery.Server, :start_link, [config]}
    }
  end

  defdelegate handle_packet(packet), to: Discovery.Server
  defdelegate fetch(source_address), to: Discovery.Server
  defdelegate all, to: Discovery.Server
  defdelegate forget_all, to: Discovery.Server
end
