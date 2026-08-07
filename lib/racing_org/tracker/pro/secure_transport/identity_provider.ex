defmodule RacingOrg.Tracker.Pro.SecureTransport.IdentityProvider do
  @moduledoc """
  Operational long-term device identity signer.

  Callers receive an opaque identity handle and use `public_key/1`, `fingerprint/1`,
  and `sign/2`; they never receive raw private-key bytes. Provider state must be a
  non-secret handle such as a file path or hardware-slot identifier.
  """

  alias RacingOrg.Tracker.Pro.SecureTransport.Primitives

  @public_key_size 32
  @signature_size 64

  @callback public_key(provider_state :: term()) :: binary()
  @callback fingerprint(provider_state :: term()) :: String.t()
  @callback sign(provider_state :: term(), message :: binary()) ::
              {:ok, binary()} | {:error, term()}

  @enforce_keys [:provider, :provider_state, :public_key, :fingerprint]
  @derive {Inspect, only: [:provider, :public_key, :fingerprint]}
  defstruct [:provider, :provider_state, :public_key, :fingerprint]

  @opaque t :: %__MODULE__{
            provider: module(),
            provider_state: term(),
            public_key: binary(),
            fingerprint: String.t()
          }

  @doc "Construct an opaque identity handle from a provider and a non-secret handle."
  @spec new(module(), term(), keyword()) :: {:ok, t()} | {:error, term()}
  def new(provider, provider_state, opts \\ [])

  def new(provider, provider_state, []) when is_atom(provider) do
    with :ok <- validate_provider(provider),
         {:ok, public_key} <- provider_public_key(provider, provider_state),
         {:ok, fingerprint} <- provider_fingerprint(provider, provider_state, public_key) do
      {:ok,
       %__MODULE__{
         provider: provider,
         provider_state: provider_state,
         public_key: public_key,
         fingerprint: fingerprint
       }}
    end
  end

  def new(_provider, _provider_state, opts) when is_list(opts),
    do: {:error, :invalid_identity_provider_options}

  def new(_provider, _provider_state, _opts), do: {:error, :invalid_identity_provider}

  @doc "Return the raw 32-byte Ed25519 public key for an identity handle."
  @spec public_key(t()) :: binary()
  def public_key(%__MODULE__{public_key: public_key}), do: public_key

  @doc "Return lowercase hexadecimal SHA-256 of the identity public key."
  @spec fingerprint(t()) :: String.t()
  def fingerprint(%__MODULE__{fingerprint: fingerprint}), do: fingerprint

  @doc "Return the module implementing this identity handle."
  @spec provider(t()) :: module()
  def provider(%__MODULE__{provider: provider}), do: provider

  @doc "Sign arbitrary bytes through the identity provider."
  @spec sign(t(), binary()) :: {:ok, binary()} | {:error, term()}
  def sign(%__MODULE__{provider: provider, provider_state: state}, message) when is_binary(message) do
    case provider.sign(state, message) do
      {:ok, signature} when is_binary(signature) and byte_size(signature) == @signature_size ->
        {:ok, signature}

      {:ok, _signature} ->
        {:error, :invalid_signature}

      {:error, _reason} = error ->
        error

      _other ->
        {:error, :invalid_signer_response}
    end
  rescue
    exception -> {:error, {:signer_exception, exception}}
  catch
    kind, reason -> {:error, {:signer_throw, kind, reason}}
  end

  def sign(%__MODULE__{}, _message), do: {:error, :invalid_message}

  @doc "Sign bytes or raise when the operational signer fails."
  @spec sign!(t(), binary()) :: binary()
  def sign!(%__MODULE__{} = identity, message) do
    case sign(identity, message) do
      {:ok, signature} -> signature
      {:error, reason} -> raise "identity signer failed: #{inspect(reason)}"
    end
  end

  @doc "Compute the canonical lowercase hexadecimal public-key fingerprint."
  @spec fingerprint_for_public_key(binary()) :: String.t()
  def fingerprint_for_public_key(<<_::binary-size(@public_key_size)>> = public_key) do
    public_key
    |> Primitives.sha256()
    |> Base.encode16(case: :lower)
  end

  defp validate_provider(provider) do
    if Code.ensure_loaded?(provider) and
         function_exported?(provider, :public_key, 1) and
         function_exported?(provider, :fingerprint, 1) and
         function_exported?(provider, :sign, 2) do
      :ok
    else
      {:error, :invalid_identity_provider}
    end
  end

  defp provider_public_key(provider, state) do
    case provider.public_key(state) do
      <<_::binary-size(@public_key_size)>> = public_key -> {:ok, public_key}
      _other -> {:error, :invalid_public_key}
    end
  rescue
    exception -> {:error, {:provider_exception, exception}}
  catch
    kind, reason -> {:error, {:provider_throw, kind, reason}}
  end

  defp provider_fingerprint(provider, state, public_key) do
    expected = fingerprint_for_public_key(public_key)

    case provider.fingerprint(state) do
      ^expected -> {:ok, expected}
      _other -> {:error, :invalid_fingerprint}
    end
  rescue
    exception -> {:error, {:provider_exception, exception}}
  catch
    kind, reason -> {:error, {:provider_throw, kind, reason}}
  end
end
