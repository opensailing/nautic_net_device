defmodule NauticNet.CAN.PiCAN.Driver do
  @moduledoc """
  Implementation of a CAN driver for the PiCAN-M hat.

  Device info: https://copperhilltech.com/pican-m-nmea-0183-nmea-2000-hat-for-raspberry-pi/
  """

  @behaviour NauticNet.CAN.Driver

  alias NauticNet.CAN.PiCAN.Server

  @impl NauticNet.CAN.Driver
  def init(driver_config) do
    case Server.start_link(driver_config) do
      {:ok, _pid} -> :ok
      _ -> :error
    end
  end

  @impl NauticNet.CAN.Driver
  defdelegate transmit_frame(frame), to: Server
end
