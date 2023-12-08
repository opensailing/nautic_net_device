defmodule NauticNet.DeviceInfo do
  @moduledoc """
  Represents information about a device on the NMEA network.
  """
  defstruct [
    :manufacturer_code,
    :manufacturer_name,
    :source_addr,
    :unique_number,
    :nmea_2000_version,
    :product_code,
    :model_id,
    :software_version_code,
    :model_version,
    :model_serial_code,
    :certification_level,
    :load_equivalency
  ]

  @type id :: {manufacturer_code :: integer, unique_number :: integer}
  @type t :: %__MODULE__{}

  @doc """
  Returns a unique identifier for this device for internal use.
  """
  @spec identifier(t) :: id
  def identifier(%__MODULE__{} = device_info) do
    {device_info.manufacturer_code, device_info.unique_number}
  end

  @doc """
  Convert the NMEA NAME from the 64bit binary to an integer
  """
  def hw_id(nmea_name) do
    <<i::integer-size(64)-unit(1)>> = nmea_name
    i
  end
end
