defmodule NauticNet do
  @moduledoc """
  Documentation for NauticNet.
  """

  @doc """
  Returns a unique identifier string for this Nerves device.
  """
  def boat_identifier do
    # :inet.gethostname/0 always succeeds
    {:ok, charlist} = :inet.gethostname()
    to_string(charlist)
  end

  def git_commit do
    Application.get_env(:nautic_net_device, :git_commit)
  end
end
