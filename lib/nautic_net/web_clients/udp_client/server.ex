defmodule NauticNet.WebClients.UDPClient.Server do
  @moduledoc """
  Sends DataSet protobuf packets to the nautic_net_web app.
  """

  use GenServer

  require Logger

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def send(binary) do
    GenServer.cast(__MODULE__, {:send, binary})
  end

  @impl true
  def init(opts) do
    hostname = opts[:hostname] || raise "the :hostname option is required"
    port = opts[:port] || raise "the :port option is required"

    # Port 0 binds to a random available port specified by the OS. This is okay since we are not
    # planning to receive any data on this port. The `:inet` option forces IPv4, because Fly does not
    # support UDP over IPv6 yet.
    {:ok, socket} = :gen_udp.open(0, [:inet, mode: :binary])

    {:ok,
     %{
       hostname: hostname,
       port: port,
       socket: socket
     }}
  end

  @impl true
  def handle_cast({:send, binary}, %{socket: socket, hostname: hostname, port: port} = state) do
    case :gen_udp.send(socket, String.to_charlist(hostname), port, binary) do
      :ok -> :ok
      {:error, reason} -> Logger.warn("Error sending UDP packet: #{inspect(reason)}")
    end

    {:noreply, state}
  end
end
