defmodule NauticNet.DeviceInfo do
  @moduledoc """
  Represents information about a device on the NMEA network.
  """
  defstruct [:source_addr, :manufacturer_code, :unique_number]

  @type id :: {manufacturer_code :: integer, unique_number :: integer}
  @type t :: %__MODULE__{}

  @doc """
  Returns a unique identifier for this device for internal use.
  """
  @spec identifier(t) :: id
  def identifier(%__MODULE__{} = device_info) do
    {device_info.manufacturer_code, device_info.unique_number}
  end
end
