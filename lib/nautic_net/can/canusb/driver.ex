defmodule NauticNet.CAN.CANUSB.Driver do
  @moduledoc """
  Implementation of a CAN driver for the CANUSB serial device.

  Device info: http://www.can232.com/?page_id=16
  """

  @behaviour NauticNet.CAN.Driver

  alias NauticNet.CAN.CANUSB.Server

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
