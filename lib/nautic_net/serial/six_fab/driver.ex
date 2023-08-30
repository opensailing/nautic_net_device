defmodule NauticNet.Serial.SixFab.Driver do
  @moduledoc """
  For interacting with Sixfab GPS from their Raspberry Pi 4G/LTE Cellular Modem Kit.
  """
  @behaviour NauticNet.Serial.Driver
  require Logger

  @modem_serial_port_name "ttyUSB2"
  @nmea_serial_port_name "ttyUSB1"

  @impl NauticNet.Serial.Driver
  def init(_config) do
    open_read_port()
    open_listener()
    :ok
  end

  def open_read_port() do
    {:ok, pid} = Circuits.UART.start_link()
    Circuits.UART.open(pid, @modem_serial_port_name, speed: 115_200, active: false)
    Circuits.UART.write(pid, "AT+QGPS=1\r")
    Circuits.UART.close(pid)
    GenServer.stop(pid)
  end

  def open_listener() do
    {:ok, pid} = Circuits.UART.start_link()
    Circuits.UART.open(pid, @nmea_serial_port_name, speed: 115_200, active: true, framing: Circuits.UART.Framing.Line)
  end
end
