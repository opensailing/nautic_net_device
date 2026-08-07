defmodule RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.KATVectors do
  @moduledoc """
  Loader for the byte-identical Desired State v1 and `control_v1` known-answer vector.
  """

  @path Application.app_dir(
          :racing_org_tracker_pro,
          "priv/secure_transport/desired_state_v1_kat.json"
        )
  @external_resource @path

  @doc "Path to the shared Desired State v1 KAT JSON file."
  @spec path() :: String.t()
  def path, do: @path

  @doc "Load the raw language-neutral KAT map."
  @spec load() :: map()
  def load do
    @path
    |> File.read!()
    |> Jason.decode!()
  end
end
