defmodule NauticNet.CAN do
  @moduledoc """
  Entrypoint for reading and writing from the CAN bus.
  """

  def child_spec(config) do
    %{
      id: __MODULE__,
      start: {NauticNet.CAN.Server, :start_link, [config]}
    }
  end

  defdelegate transmit_frame(frame), to: NauticNet.CAN.Server
end
