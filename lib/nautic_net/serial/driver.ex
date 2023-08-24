defmodule NauticNet.Serial.Driver do
  @moduledoc """
  The abstraction layer behind which the Serial Port physical layer can be implemented.
  """

  @doc """
  Configure and prepare the Serial Port driver for use.
  """
  @callback init(config :: keyword) :: :ok | :error
end
