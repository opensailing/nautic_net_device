defmodule NauticNet.CAN.Fake.Driver do
  @moduledoc """
  Implementation of a CAN driver for testing.
  """

  @behaviour NauticNet.CAN.Driver

  alias NauticNet.CAN.Fake.Server

  @impl NauticNet.CAN.Driver
  def init(driver_config) do
    case Server.start_link(driver_config) do
      {:ok, _pid} -> :ok
      _ -> :error
    end
  end

  @impl NauticNet.CAN.Driver
  defdelegate transmit_frame(frame), to: Server

  # For testing purposes
  defdelegate receive_frame(frame), to: Server
  defdelegate replay_canusb_log(filename_or_list, opts \\ []), to: Server
end
