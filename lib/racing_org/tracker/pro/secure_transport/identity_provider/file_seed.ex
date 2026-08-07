defmodule RacingOrg.Tracker.Pro.SecureTransport.IdentityProvider.FileSeed do
  @moduledoc """
  Ed25519 identity provider backed by a durable 32-byte seed file.

  The operational identity handle contains only the seed-file path, the expected public
  key, and the filesystem implementation. Every signature reads the seed privately,
  derives and constant-time compares its public key with the expected identity, signs,
  and then drops the seed from the call stack.
  """

  @behaviour RacingOrg.Tracker.Pro.SecureTransport.IdentityProvider

  alias RacingOrg.Tracker.Pro.SecureTransport.IdentityProvider
  alias RacingOrg.Tracker.Pro.SecureTransport.KeyStore.FileSystem
  alias RacingOrg.Tracker.Pro.SecureTransport.Primitives

  @seed_size 32
  @public_key_size 32

  @enforce_keys [:path, :expected_public_key, :file_system]
  defstruct [:path, :expected_public_key, :file_system]

  @type t :: %__MODULE__{
          path: String.t(),
          expected_public_key: binary(),
          file_system: module()
        }

  @doc "Construct a file-backed identity from a non-secret path and expected public key."
  @spec from_path(term(), term(), keyword()) :: {:ok, IdentityProvider.t()} | {:error, term()}
  def from_path(path, expected_public_key, opts \\ [])

  def from_path(path, <<_::binary-size(@public_key_size)>> = expected_public_key, opts)
      when is_binary(path) and path != "" and is_list(opts) do
    if Keyword.keyword?(opts) do
      state = %__MODULE__{
        path: path,
        expected_public_key: expected_public_key,
        file_system: Keyword.get(opts, :file_system, FileSystem)
      }

      IdentityProvider.new(__MODULE__, state)
    else
      {:error, :invalid_file_seed_options}
    end
  end

  def from_path(_path, _expected_public_key, _opts), do: {:error, :invalid_file_seed_handle}

  @impl true
  def public_key(%__MODULE__{expected_public_key: public_key}), do: public_key

  @impl true
  def fingerprint(%__MODULE__{expected_public_key: public_key}) do
    IdentityProvider.fingerprint_for_public_key(public_key)
  end

  @impl true
  def sign(%__MODULE__{} = state, message) when is_binary(message) do
    with {:ok, seed} <- read_seed(state),
         actual_public_key = Primitives.ed25519_public_from_secret(seed),
         true <- Primitives.secure_compare(actual_public_key, state.expected_public_key) do
      {:ok, Primitives.ed25519_sign(seed, message)}
    else
      false -> {:error, :identity_seed_mismatch}
      {:error, _reason} = error -> error
    end
  rescue
    _exception -> {:error, :sign_failed}
  end

  defp read_seed(%__MODULE__{path: path, file_system: file_system}) do
    case file_system.read(path) do
      {:ok, <<seed::binary-size(@seed_size)>>} -> {:ok, seed}
      {:ok, _other} -> {:error, :corrupt_seed}
      {:error, reason} -> {:error, {:identity_seed_read_failed, reason}}
      _other -> {:error, :identity_seed_read_failed}
    end
  end
end
