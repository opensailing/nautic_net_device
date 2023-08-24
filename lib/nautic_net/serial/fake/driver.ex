defmodule NauticNet.Serial.Fake.Driver do
  @moduledoc """
  Implementation of a Serial driver for testing.
  """

  @behaviour NauticNet.Serial.Driver

  alias NauticNet.Serial.Fake.Server

  @impl NauticNet.Serial.Driver
  def init(driver_config) do
    case Server.start_link(driver_config) do
      {:ok, _pid} -> :ok
      _ -> :error
    end
  end
end
