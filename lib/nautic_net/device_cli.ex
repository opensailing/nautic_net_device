defmodule NauticNet.DeviceCLI do
  @moduledoc """
  Imports to be made accessible from the Nerves CLI.
  """

  alias NauticNet.CAN
  alias NauticNet.CAN.CANUSB
  alias NauticNet.CAN.Fake
  alias NauticNet.Discovery
  alias NauticNet.NMEA2000.Frame
  alias NauticNet.NMEA2000.ParameterGroup.ISOAddressClaimParams
  alias NauticNet.NMEA2000.PGN

  def start_logging_canusb do
    CANUSB.Server.start_logging()
  end

  def stop_logging_canusb do
    CANUSB.Server.stop_logging()
  end

  defdelegate request_address_claims, to: NauticNet.Network
  defdelegate request_product_infos, to: NauticNet.Network

  def claim_address(my_addr) do
    source_addrs = Map.keys(Discovery.all())
    # my_addr = Enum.find(1..254, fn addr -> addr not in source_addrs end)
    # my_addr = 53

    iso_address_claim = 0xEE00
    broadcast_addr = 0xFF
    pgn_int = iso_address_claim |> PGN.to_struct() |> Map.put(:pdu_specific, broadcast_addr) |> PGN.to_integer()

    <<can_id::29>> = <<6::3, pgn_int::18, my_addr::8>>

    frame = %Frame{
      type: :extended,
      identifier: can_id,
      data:
        ISOAddressClaimParams.encode(%ISOAddressClaimParams{
          unique_number: 0x12,
          manufacturer_code: 0x34,
          device_instance_lower: 1,
          device_instance_upper: 2,
          device_function: 140,
          device_class: 80,
          system_instance: 0,
          industry_group: 0
        })
    }

    # frame = %NauticNet.NMEA2000.Frame{
    #   data: <<31, 6, 160, 89, 0, 130, 150, 192>>,
    #   identifier: 418_316_084,
    #   timestamp: nil,
    #   timestamp_monotonic_ms: nil,
    #   timestamp_ms: 1_686_150_938_717,
    #   type: :extended
    # }

    CAN.transmit_frame(frame)

    {:ok,
     %{
       source_addrs: source_addrs,
       my_addr: my_addr,
       pgn: hex(pgn_int),
       can_id: hex(can_id)
     }}
  end

  @doc """
  Replay a CANUSB log file from the Fake driver.
  """
  def replay_log(log_filename, opts \\ []) do
    paths = [
      log_filename,
      Path.join([:code.priv_dir(:nautic_net_device), "replay_logs", log_filename])
    ]

    if path = Enum.find(paths, &File.exists?/1) do
      Fake.Driver.replay_canusb_log(path, opts)
    else
      {:error, :file_not_found}
    end
  end

  defp hex(int), do: Integer.to_string(int, 16)
end
