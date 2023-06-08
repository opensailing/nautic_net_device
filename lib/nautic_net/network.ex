defmodule NauticNet.Network do
  @moduledoc """
  High-level functions for transmitting common packet types to the NMEA2000 network.
  """

  alias NauticNet.CAN
  alias NauticNet.NMEA2000.J1939.ISOAddressClaimParams
  alias NauticNet.NMEA2000.J1939.ISORequestParams
  alias NauticNet.NMEA2000.J1939.ProductInformationParams
  alias NauticNet.NMEA2000.Packet

  def request_address_claims do
    CAN.transmit_packet(%Packet{
      source_addr: :null,
      dest_addr: :broadcast,
      parameters: %ISORequestParams{
        pgn: ISOAddressClaimParams.pgn()
      }
    })
  end

  def request_product_infos do
    CAN.transmit_packet(%Packet{
      source_addr: :null,
      dest_addr: :broadcast,
      parameters: %ISORequestParams{
        pgn: ProductInformationParams.pgn()
      }
    })
  end
end
