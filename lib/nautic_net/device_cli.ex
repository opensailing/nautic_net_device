defmodule NauticNet.DeviceCLI do
  @moduledoc """
  Imports to be made accessible from the Nerves CLI.
  """

  alias NauticNet.CAN.CANUSB
  alias NauticNet.CAN.Fake

  def start_logging_canusb do
    CANUSB.Server.start_logging()
  end

  def stop_logging_canusb do
    CANUSB.Server.stop_logging()
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
end
