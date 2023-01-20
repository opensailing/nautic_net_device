defmodule NauticNet.WebClients.UDPClient do
  alias NauticNet.WebClients.UDPClient.Server

  def send_data_set(proto_binary) do
    Server.send(proto_binary)
  end
end
