defmodule RacingOrg.Tracker.Pro.CAN.Fake.Driver do
  @moduledoc """
  Implementation of a CAN driver for testing.
  """

  @behaviour RacingOrg.Tracker.Pro.CAN.Driver

  alias RacingOrg.Tracker.Pro.CAN.Fake.Server

  @stale_server_shutdown_timeout 5_000

  @impl RacingOrg.Tracker.Pro.CAN.Driver
  def init(driver_config), do: start_server(driver_config)

  defp start_server(driver_config) do
    case Server.start_link(driver_config) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, stale_pid}} when is_pid(stale_pid) ->
        with :ok <- await_stale_server_shutdown(stale_pid) do
          start_server(driver_config)
        end

      _other ->
        :error
    end
  end

  defp await_stale_server_shutdown(stale_pid) do
    monitor_ref = Process.monitor(stale_pid)

    receive do
      {:DOWN, ^monitor_ref, :process, ^stale_pid, _reason} ->
        :ok
    after
      @stale_server_shutdown_timeout ->
        Process.demonitor(monitor_ref, [:flush])
        :error
    end
  end

  @impl RacingOrg.Tracker.Pro.CAN.Driver
  defdelegate transmit_frame(frame), to: Server

  # For testing purposes
  defdelegate receive_frame(frame), to: Server
  defdelegate replay_canusb_log(filename_or_list, opts \\ []), to: Server
end
