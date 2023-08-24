defmodule NauticNet.Serial do
  @moduledoc """
  Entrypoint for reading and writing from a serial port.
  """

  def child_spec(config) do
    %{
      id: __MODULE__,
      start: {NauticNet.Serial.Server, :start_link, [config]}
    }
  end
end
