defmodule NauticNet.DeviceCLI do
  @moduledoc """
  Imports to be made accessible from the Nerves CLI.
  """

  def start_logging_canusb do
    NauticNet.CAN.CANUSB.Server.start_logging()
  end

  def stop_logging_canusb do
    NauticNet.CAN.CANUSB.Server.stop_logging()
  end
end
