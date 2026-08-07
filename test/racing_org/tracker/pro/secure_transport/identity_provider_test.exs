defmodule RacingOrg.Tracker.Pro.SecureTransport.IdentityProviderTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.IdentityProviderTestSupport
  alias RacingOrg.Tracker.Pro.SecureTransport.IdentityProvider
  alias RacingOrg.Tracker.Pro.SecureTransport.IdentityProvider.FileSeed
  alias RacingOrg.Tracker.Pro.SecureTransport.Primitives

  @seed :binary.copy(<<0x42>>, 32)

  defmodule UnavailableSigner do
    @behaviour IdentityProvider

    @impl true
    def public_key(:state), do: :binary.copy(<<0x24>>, 32)

    @impl true
    def fingerprint(:state) do
      :state
      |> public_key()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
    end

    @impl true
    def sign(:state, _message), do: {:error, :signer_unavailable}
  end

  describe "operational provider facade" do
    test "exposes public key, fingerprint, and signing without operational callers reading the seed" do
      assert {:ok, identity} = IdentityProviderTestSupport.identity_from_seed(@seed)

      public_key = IdentityProvider.public_key(identity)
      fingerprint = IdentityProvider.fingerprint(identity)

      assert byte_size(public_key) == 32
      assert fingerprint == Base.encode16(Primitives.sha256(public_key), case: :lower)

      assert {:ok, signature} = IdentityProvider.sign(identity, "provider-message")
      assert byte_size(signature) == 64
      assert Primitives.ed25519_verify(public_key, "provider-message", signature)

      refute Map.has_key?(Map.from_struct(identity), :private_key)
      refute inspect(identity) =~ inspect(@seed)
    end

    test "delegates operational signer failures without exposing provider state" do
      assert {:ok, identity} = IdentityProvider.new(UnavailableSigner, :state)
      assert IdentityProvider.public_key(identity) == :binary.copy(<<0x24>>, 32)

      assert IdentityProvider.fingerprint(identity) ==
               Base.encode16(:crypto.hash(:sha256, :binary.copy(<<0x24>>, 32)), case: :lower)

      assert {:error, :signer_unavailable} = IdentityProvider.sign(identity, "message")
      refute Map.has_key?(Map.from_struct(identity), :private_key)
      refute inspect(identity) =~ ":state"
    end

    test "rejects raw private-key compatibility options" do
      assert {:error, :invalid_identity_provider_options} =
               IdentityProvider.new(UnavailableSigner, :state, legacy_private_key: @seed)
    end

    test "rejects malformed file handles and corrupt seed contents" do
      public_key = Primitives.ed25519_public_from_secret(@seed)

      assert {:error, :invalid_file_seed_handle} = FileSeed.from_path("", public_key)
      assert {:error, :invalid_file_seed_handle} = FileSeed.from_path("/tmp/seed", <<0::248>>)

      path =
        Path.join(
          System.tmp_dir!(),
          "racing-org-corrupt-identity-#{System.unique_integer([:positive, :monotonic])}.key"
        )

      File.write!(path, <<0::248>>, [:binary, :exclusive])
      ExUnit.Callbacks.on_exit({__MODULE__, path}, fn -> File.rm(path) end)

      assert {:ok, identity} = FileSeed.from_path(path, public_key)
      assert {:error, :corrupt_seed} = IdentityProvider.sign(identity, "message")
    end
  end
end
