defmodule RacingOrg.Tracker.Pro.SecureTransport.BootstrapClient do
  @moduledoc """
  Receipt-verifying HTTP client for serial-aware registration v2.

  The candidate signs the canonical assertion through `IdentityProvider`. Successful
  responses are accepted only when the pinned server signature verifies and the signed
  receipt request hash matches the exact assertion bytes sent by this client.
  """

  alias RacingOrg.Tracker.Pro.SecureTransport.IdentityProvider
  alias RacingOrg.Tracker.Pro.SecureTransport.Primitives
  alias RacingOrg.Tracker.Pro.SecureTransport.TrackerContractV2, as: Contract

  @default_path "/api/devices/register/v2"
  @nonce_size 32

  @type request_context :: %{
          assertion: binary(),
          body: map(),
          candidate_public_key: binary(),
          client_nonce: binary(),
          signature: binary()
        }

  @doc "Prepare one exact registration assertion and canonical JSON request body."
  @spec prepare_registration(IdentityProvider.t(), binary(), keyword()) ::
          {:ok, request_context()} | {:error, term()}
  def prepare_registration(%IdentityProvider{} = identity, serial, opts \\ []) do
    with {:ok, client_nonce} <- client_nonce(opts),
         public_key = IdentityProvider.public_key(identity),
         {:ok, assertion} <- Contract.registration_assertion(serial, public_key, client_nonce),
         {:ok, signature} <- IdentityProvider.sign(identity, assertion) do
      {:ok,
       %{
         assertion: assertion,
         body: %{
           "provider" => Contract.provider(),
           "serial" => serial,
           "candidate_public_key" => Base.encode64(public_key),
           "client_nonce" => Base.encode64(client_nonce),
           "signature" => Base.encode64(signature)
         },
         candidate_public_key: public_key,
         client_nonce: client_nonce,
         signature: signature
       }}
    end
  end

  @doc "POST registration v2 and verify the server-authority receipt."
  @spec register(IdentityProvider.t(), binary(), keyword()) ::
          {:ok, %{request: request_context(), receipt: map()}} | {:error, term()}
  def register(%IdentityProvider{} = identity, serial, opts \\ []) do
    with {:ok, request} <- prepare_registration(identity, serial, opts),
         {:ok, response} <- post(Keyword.get(opts, :register_path, @default_path), request.body, opts),
         {:ok, receipt} <- verify_registration_response(request, response, opts) do
      {:ok, %{request: request, receipt: receipt}}
    end
  end

  @doc "Verify a registration receipt wrapper against a prepared exact request."
  @spec verify_registration_response(request_context(), term(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def verify_registration_response(request, response, opts \\ []) when is_map(request) do
    with {:ok, receipt} <- verify_receipt_response(response, opts),
         :ok <- ensure(receipt.receipt_type == :registration, :unexpected_receipt_type),
         :ok <-
           secure_match(
             receipt.payload.request_hash,
             Primitives.sha256(request.assertion),
             :receipt_request_mismatch
           ) do
      {:ok, receipt}
    end
  end

  @doc "Validate an injected/client result against the candidate, serial, and exact receipt."
  @spec validate_result(IdentityProvider.t(), binary(), term(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def validate_result(identity, serial, result, opts \\ [])

  def validate_result(%IdentityProvider{} = identity, serial, %{request: request, receipt: receipt}, opts) do
    public_key = IdentityProvider.public_key(identity)

    with :ok <- secure_match(request.candidate_public_key, public_key, :candidate_public_key_mismatch),
         {:ok, expected_assertion} <- Contract.registration_assertion(serial, public_key, request.client_nonce),
         :ok <- secure_match(request.assertion, expected_assertion, :registration_assertion_mismatch),
         :ok <- validate_request_signature(public_key, request),
         {:ok, verified} <- verify_receipt_envelope(receipt.envelope, opts),
         :ok <- ensure(verified.receipt_type == :registration, :unexpected_receipt_type),
         :ok <-
           secure_match(
             verified.payload.request_hash,
             Primitives.sha256(expected_assertion),
             :receipt_request_mismatch
           ) do
      {:ok, %{request: request, receipt: verified}}
    end
  end

  def validate_result(_identity, _serial, _result, _opts), do: {:error, :invalid_registration_result}

  defp validate_request_signature(public_key, request) do
    if Primitives.ed25519_verify(public_key, request.assertion, request.signature) do
      :ok
    else
      {:error, :invalid_candidate_signature}
    end
  end

  defp post(path, body, opts) do
    client = tesla_client(opts)
    url = Keyword.get(opts, :base_url, configured_api_endpoint()) <> path

    case Tesla.post(client, url, body) do
      {:ok, %Tesla.Env{status: status, body: response}} when status in 200..299 -> {:ok, response}
      {:ok, %Tesla.Env{status: 409}} -> {:error, :registration_conflict}
      {:ok, %Tesla.Env{status: status}} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, {:transport, reason}}
    end
  end

  defp tesla_client(opts) do
    middleware = [Tesla.Middleware.JSON]

    case Keyword.fetch(opts, :adapter) do
      {:ok, adapter} -> Tesla.client(middleware, adapter)
      :error -> Tesla.client(middleware)
    end
  end

  defp verify_receipt_response(response, opts) do
    case Keyword.fetch(opts, :server_public_key) do
      {:ok, key} -> Contract.verify_receipt_response(response, key)
      :error -> Contract.verify_receipt_response(response)
    end
  end

  defp verify_receipt_envelope(envelope, opts) do
    case Keyword.fetch(opts, :server_public_key) do
      {:ok, key} -> Contract.verify_receipt_envelope(envelope, key)
      :error -> Contract.verify_receipt_envelope(envelope)
    end
  end

  defp client_nonce(opts) do
    case Keyword.fetch(opts, :client_nonce) do
      {:ok, <<_::binary-size(@nonce_size)>> = nonce} -> {:ok, nonce}
      {:ok, _invalid} -> {:error, :bad_client_nonce_length}
      :error -> generate_nonce(opts)
    end
  end

  defp generate_nonce(opts) do
    generator = Keyword.get(opts, :nonce_generator, fn -> :crypto.strong_rand_bytes(@nonce_size) end)

    case generator.() do
      <<_::binary-size(@nonce_size)>> = nonce -> {:ok, nonce}
      _other -> {:error, :invalid_nonce_generator}
    end
  rescue
    _exception -> {:error, :nonce_generation_failed}
  catch
    _kind, _reason -> {:error, :nonce_generation_failed}
  end

  defp configured_api_endpoint, do: Application.get_env(:racing_org_tracker_pro, :api_endpoint, "")

  defp secure_match(left, right, error)
       when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right) do
    if Primitives.secure_compare(left, right), do: :ok, else: {:error, error}
  end

  defp secure_match(_left, _right, error), do: {:error, error}
  defp ensure(true, _error), do: :ok
  defp ensure(false, error), do: {:error, error}
end
