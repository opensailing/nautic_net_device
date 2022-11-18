defmodule NauticNet.HostCLI do
  @moduledoc """
  Imports to be made accessible from IEx on the host.
  """

  @doc """
  Print out unique message identifiers from CANUSB log file.
  """
  def print_identifiers(log_filename) do
    log_filename
    |> File.read!()
    |> String.split("\n")
    |> Enum.reduce(%{}, fn line, map ->
      case String.split(line, " ") do
        [_, _, message] ->
          # T1DFF080D8C4419AA0BED56920
          <<"T", id_hex::binary-8, _::binary>> = message
          Map.update(map, id_hex, 1, &(&1 + 1))

        _ ->
          map
      end
    end)
    |> Enum.sort()
    |> Enum.map_join("\n", fn {id, count} -> "#{id} #{count}\t" end)
    |> IO.puts()
  end

  @doc """
  Replay a CANUSB log file from the Fake driver.
  """
  def replay_log(log_filename, opts \\ []) do
    NauticNet.CAN.Fake.Driver.replay_canusb_log(log_filename, opts)
  end
end
