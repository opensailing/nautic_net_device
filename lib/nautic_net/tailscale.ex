defmodule NauticNet.Tailscale do
  @moduledoc """
  Starting up the Tailscale VPN.
  """

  require Logger

  def enabled? do
    is_binary(auth_key())
  end

  def start! do
    # Load the tun module
    {_, 0} = Nerves.Runtime.cmd("modprobe", ~w(tun), :return)

    # Spawn tailscaled into a task since it's long-running
    Task.start(&run_tailescaled_forever/0)

    # Wait for tailscaled to start
    Process.sleep(:timer.seconds(1))

    tailscale_args = ~w(up --authkey #{auth_key()})
    {_, 0} = Nerves.Runtime.cmd(tailscale_path(), tailscale_args, :return)

    :ok
  end

  def run_tailescaled_forever do
    tailscaled_args = ~w(
      --state=/data/tailscale/tailscaled.state
      --socket=/run/tailscale/tailscaled.sock
      --port=41641
    )
    {output, code} = Nerves.Runtime.cmd(tailscaled_path(), tailscaled_args, :return)

    Logger.warn("""
    tailscaled exited with code #{code}:

    #{output}
    """)

    # If this ever exits... try it again
    Process.sleep(:timer.seconds(1))
    run_tailescaled_forever()
  end

  defp tailscaled_path do
    Path.join([priv_dir(), "arm", "tailscaled"])
  end

  defp tailscale_path do
    Path.join([priv_dir(), "arm", "tailscale"])
  end

  defp auth_key do
    Application.get_env(:nautic_net_device, :tailscale_auth_key)
  end

  defp priv_dir, do: :nautic_net_device |> :code.priv_dir() |> to_string()
end
