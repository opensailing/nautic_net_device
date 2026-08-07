defmodule RacingOrg.Tracker.Pro.IdentityProviderTestSupport do
  alias RacingOrg.Tracker.Pro.SecureTransport.IdentityProvider.FileSeed
  alias RacingOrg.Tracker.Pro.SecureTransport.Primitives

  def identity_from_seed(<<_::binary-size(32)>> = seed) do
    path =
      Path.join(
        System.tmp_dir!(),
        "racing-org-tracker-identity-#{System.unique_integer([:positive, :monotonic])}.key"
      )

    File.write!(path, seed, [:binary, :exclusive])
    File.chmod!(path, 0o600)
    ExUnit.Callbacks.on_exit({__MODULE__, path}, fn -> File.rm(path) end)

    FileSeed.from_path(path, Primitives.ed25519_public_from_secret(seed))
  end

  def identity_from_seed(_seed), do: {:error, :invalid_private_seed}
end
