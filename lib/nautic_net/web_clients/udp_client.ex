defmodule NauticNet.WebClients.UDPClient do
  alias NauticNet.WebClients.UDPClient.Server

  def child_spec(arg), do: NauticNet.WebClients.UDPClient.Server.child_spec(arg)

  def send_data_set(proto_binary) do
    Server.send(proto_binary)
  end
end
