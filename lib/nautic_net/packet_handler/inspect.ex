defmodule NauticNet.PacketHandler.Inspect do
  use GenServer
  require Logger

  @impl true
  def init(opts) do
    only = List.flatten([Keyword.get(opts, :only, [])])
    {:ok, %{only: only}}
  end

  @impl true
  def handle_info({:data, data}, state) do
    Logger.debug("Recieved: #{inspect(data, pretty: true)}")
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.debug("#{__MODULE__} unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end
end
