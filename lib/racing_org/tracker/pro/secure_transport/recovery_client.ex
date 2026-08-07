defmodule RacingOrg.Tracker.Pro.SecureTransport.RecoveryClient do
  @moduledoc """
  Candidate-PoP client for recovery challenge, commit, and idempotent status.

  All server responses are signed receipts. The client binds them back to the exact
  candidate assertion, challenge envelope, attempt, candidate fingerprint, logical
  device, credential epoch, and accepted commit-signing-bytes hash before returning
  success. Challenge expiry is never authorized against the tracker's RTC.
  """

  alias RacingOrg.Tracker.Pro.SecureTransport.IdentityProvider
  alias RacingOrg.Tracker.Pro.SecureTransport.Primitives
  alias RacingOrg.Tracker.Pro.SecureTransport.TrackerContractV2, as: Contract

  @challenge_path "/api/devices/recovery/challenges"
  @nonce_size 32

  @doc "Prepare the exact serial-aware recovery challenge request."
  @spec prepare_challenge(IdentityProvider.t(), binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def prepare_challenge(%IdentityProvider{} = identity, serial, opts \\ []) do
    with {:ok, client_nonce} <- client_nonce(opts),
         public_key = IdentityProvider.public_key(identity),
         {:ok, assertion} <- Contract.recovery_challenge_assertion(serial, public_key, client_nonce),
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

  @doc "POST a recovery challenge and verify its signed classification."
  @spec challenge(IdentityProvider.t(), binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def challenge(%IdentityProvider{} = identity, serial, opts \\ []) do
    with {:ok, request} <- prepare_challenge(identity, serial, opts),
         {:ok, response} <- post(Keyword.get(opts, :challenge_path, @challenge_path), request.body, opts),
         {:ok, receipt} <- verify_challenge_response(request, response, opts) do
      {:ok, %{request: request, receipt: receipt}}
    end
  end

  @doc "Verify a challenge receipt against the exact request assertion."
  @spec verify_challenge_response(map(), term(), keyword()) :: {:ok, map()} | {:error, term()}
  def verify_challenge_response(request, response, opts \\ []) do
    with {:ok, receipt} <- verify_receipt_response(response, opts),
         :ok <- ensure(receipt.receipt_type == :challenge, :unexpected_receipt_type),
         :ok <-
           secure_match(
             receipt.payload.request_hash,
             Primitives.sha256(request.assertion),
             :receipt_request_mismatch
           ) do
      {:ok, receipt}
    end
  end

  @doc "Validate an injected challenge result against the candidate and serial."
  @spec validate_challenge_result(IdentityProvider.t(), binary(), term(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def validate_challenge_result(identity, serial, result, opts \\ [])

  def validate_challenge_result(
        %IdentityProvider{} = identity,
        serial,
        %{request: request, receipt: receipt},
        opts
      ) do
    public_key = IdentityProvider.public_key(identity)

    with :ok <- secure_match(request.candidate_public_key, public_key, :candidate_public_key_mismatch),
         {:ok, assertion} <- Contract.recovery_challenge_assertion(serial, public_key, request.client_nonce),
         :ok <- secure_match(request.assertion, assertion, :challenge_assertion_mismatch),
         :ok <- verify_candidate_signature(public_key, request.assertion, request.signature),
         {:ok, verified} <- verify_receipt_envelope(receipt.envelope, opts),
         :ok <- ensure(verified.receipt_type == :challenge, :unexpected_receipt_type),
         :ok <-
           secure_match(
             verified.payload.request_hash,
             Primitives.sha256(assertion),
             :receipt_request_mismatch
           ) do
      {:ok, %{request: request, receipt: verified}}
    end
  end

  def validate_challenge_result(_identity, _serial, _result, _opts),
    do: {:error, :invalid_challenge_result}

  @doc "Prepare candidate proof over the exact signed challenge envelope."
  @spec prepare_commit(IdentityProvider.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def prepare_commit(%IdentityProvider{} = identity, challenge_receipt, _opts \\ []) do
    with :ok <- validate_recoverable_challenge(challenge_receipt),
         public_key = IdentityProvider.public_key(identity),
         {:ok, assertion} <-
           Contract.recovery_commit_assertion(
             challenge_receipt.payload.attempt_id,
             public_key,
             challenge_receipt.envelope_hash
           ),
         {:ok, signature} <- IdentityProvider.sign(identity, assertion) do
      {:ok,
       %{
         kind: :commit,
         assertion: assertion,
         body: %{
           "candidate_public_key" => Base.encode64(public_key),
           "challenge_envelope_hash" => Base.encode64(challenge_receipt.envelope_hash),
           "signature" => Base.encode64(signature)
         },
         candidate_public_key: public_key,
         challenge_envelope_hash: challenge_receipt.envelope_hash,
         signature: signature
       }}
    end
  end

  @doc "Commit recovery and validate the returned lifecycle receipt."
  @spec commit(IdentityProvider.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def commit(%IdentityProvider{} = identity, challenge_receipt, opts \\ []) do
    with {:ok, request} <- prepare_commit(identity, challenge_receipt, opts),
         path = recovery_path(challenge_receipt.payload.attempt_id, "commit", opts),
         {:ok, response} <- post(path, request.body, opts),
         {:ok, receipt} <- verify_lifecycle_response(request, challenge_receipt, response, opts) do
      {:ok, %{request: request, receipt: receipt}}
    end
  end

  @doc "Prepare a fresh-nonce candidate-PoP status request."
  @spec prepare_status(IdentityProvider.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def prepare_status(%IdentityProvider{} = identity, challenge_receipt, opts \\ []) do
    with :ok <- validate_recoverable_challenge(challenge_receipt),
         {:ok, nonce} <- client_nonce(opts),
         public_key = IdentityProvider.public_key(identity),
         {:ok, assertion} <-
           Contract.recovery_status_assertion(
             challenge_receipt.payload.attempt_id,
             public_key,
             challenge_receipt.envelope_hash,
             nonce
           ),
         {:ok, signature} <- IdentityProvider.sign(identity, assertion) do
      {:ok,
       %{
         kind: :status,
         assertion: assertion,
         body: %{
           "candidate_public_key" => Base.encode64(public_key),
           "challenge_envelope_hash" => Base.encode64(challenge_receipt.envelope_hash),
           "client_nonce" => Base.encode64(nonce),
           "signature" => Base.encode64(signature)
         },
         candidate_public_key: public_key,
         challenge_envelope_hash: challenge_receipt.envelope_hash,
         client_nonce: nonce,
         signature: signature
       }}
    end
  end

  @doc "Query recovery status with fresh candidate PoP and verify lifecycle replay."
  @spec status(IdentityProvider.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def status(%IdentityProvider{} = identity, challenge_receipt, opts \\ []) do
    with {:ok, request} <- prepare_status(identity, challenge_receipt, opts),
         path = recovery_path(challenge_receipt.payload.attempt_id, "status", opts),
         {:ok, response} <- post(path, request.body, opts),
         {:ok, receipt} <- verify_lifecycle_response(request, challenge_receipt, response, opts) do
      {:ok, %{request: request, receipt: receipt}}
    end
  end

  @doc "Verify lifecycle receipt bindings for commit or status."
  @spec verify_lifecycle_response(map(), map(), term(), keyword()) :: {:ok, map()} | {:error, term()}
  def verify_lifecycle_response(request, challenge_receipt, response, opts \\ []) do
    with {:ok, receipt} <- verify_receipt_response(response, opts),
         :ok <- validate_lifecycle_bindings(request, challenge_receipt, receipt) do
      {:ok, receipt}
    end
  end

  @doc "Validate an injected commit/status result, including its exact signed envelope."
  @spec validate_lifecycle_result(IdentityProvider.t(), map(), term(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def validate_lifecycle_result(identity, challenge_receipt, result, opts \\ [])

  def validate_lifecycle_result(
        %IdentityProvider{} = identity,
        challenge_receipt,
        %{request: request, receipt: receipt},
        opts
      ) do
    public_key = IdentityProvider.public_key(identity)

    with :ok <- secure_match(request.candidate_public_key, public_key, :candidate_public_key_mismatch),
         :ok <- verify_candidate_signature(public_key, request.assertion, request.signature),
         {:ok, verified} <- verify_receipt_envelope(receipt.envelope, opts),
         :ok <- validate_lifecycle_bindings(request, challenge_receipt, verified) do
      {:ok, %{request: request, receipt: verified}}
    end
  end

  def validate_lifecycle_result(_identity, _challenge_receipt, _result, _opts),
    do: {:error, :invalid_lifecycle_result}

  defp validate_lifecycle_bindings(request, challenge_receipt, receipt) do
    expected_fingerprint = Primitives.sha256(request.candidate_public_key)

    with :ok <- ensure(receipt.receipt_type == :lifecycle, :unexpected_receipt_type),
         :ok <-
           secure_match(
             receipt.payload.attempt_id,
             challenge_receipt.payload.attempt_id,
             :attempt_id_mismatch
           ),
         :ok <-
           secure_match(
             receipt.payload.challenge_envelope_hash,
             challenge_receipt.envelope_hash,
             :challenge_envelope_hash_mismatch
           ),
         :ok <-
           secure_match(
             receipt.payload.candidate_fingerprint,
             expected_fingerprint,
             :candidate_fingerprint_mismatch
           ),
         :ok <- validate_committed_hash(request, challenge_receipt, receipt.payload) do
      :ok
    end
  end

  defp validate_committed_hash(request, challenge_receipt, %{lifecycle: :committed} = payload) do
    with {:ok, expected_assertion} <- expected_commit_assertion(request, challenge_receipt),
         :ok <-
           secure_match(
             payload.accepted_commit_signing_bytes_hash,
             Primitives.sha256(expected_assertion),
             :accepted_commit_hash_mismatch
           ),
         :ok <- ensure(is_binary(payload.logical_device_id), :logical_device_id_missing),
         :ok <- ensure(payload.credential_epoch > 0, :invalid_credential_epoch) do
      :ok
    end
  end

  defp validate_committed_hash(_request, _challenge_receipt, _payload), do: :ok

  defp expected_commit_assertion(%{kind: :commit} = request, _challenge_receipt),
    do: {:ok, request.assertion}

  defp expected_commit_assertion(%{kind: :status} = request, challenge_receipt) do
    Contract.recovery_commit_assertion(
      challenge_receipt.payload.attempt_id,
      request.candidate_public_key,
      challenge_receipt.envelope_hash
    )
  end

  defp validate_recoverable_challenge(%{
         receipt_type: :challenge,
         payload: %{classification: :recoverable, attempt_id: attempt_id},
         envelope_hash: envelope_hash
       })
       when is_binary(attempt_id) and byte_size(attempt_id) == 16 and is_binary(envelope_hash) and
              byte_size(envelope_hash) == 32,
       do: :ok

  defp validate_recoverable_challenge(_receipt), do: {:error, :challenge_not_recoverable}

  defp recovery_path(attempt_id, action, opts) do
    prefix = Keyword.get(opts, :recovery_path, "/api/devices/recovery")
    prefix <> "/" <> uuid_string(attempt_id) <> "/" <> action
  end

  defp uuid_string(<<a::binary-size(4), b::binary-size(2), c::binary-size(2), d::binary-size(2), e::binary-size(6)>>) do
    Enum.map_join([a, b, c, d, e], "-", &Base.encode16(&1, case: :lower))
  end

  defp post(path, body, opts) do
    client = tesla_client(opts)
    url = Keyword.get(opts, :base_url, configured_api_endpoint()) <> path

    case Tesla.post(client, url, body) do
      {:ok, %Tesla.Env{status: status, body: response}} when status in 200..299 -> {:ok, response}
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

  defp verify_candidate_signature(public_key, assertion, signature) do
    if Primitives.ed25519_verify(public_key, assertion, signature) do
      :ok
    else
      {:error, :invalid_candidate_signature}
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
