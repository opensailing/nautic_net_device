defmodule NauticNet.Serial.Fake.Server do
  @moduledoc """
  GenServer implementation for a test Serial interface driver.
  """

  use GenServer

  require Logger

  @name __MODULE__

  defmodule State do
    defstruct parent_pid: nil
  end

  def start_link(_) do
    GenServer.start_link(__MODULE__, self(), name: @name)
  end

  @impl GenServer
  def init(parent_pid) do
    {:ok, %State{parent_pid: parent_pid}}
  end
end
