defmodule RacingOrg.Tracker.Pro.SecureTransport.RegisterClient do
  @moduledoc """
  Device-side TOKENLESS self-registration client (Phase AC7).

  This REPLACES the old claim flow. There is no longer an out-of-band claim token
  or server-issued nonce: on boot the device presents its long-term Ed25519 PUBLIC
  key (`KeyStore`) plus an Ed25519 proof-of-possession over a self-chosen unix
  timestamp, and the server records the public key as the device's authoritative
  `DeviceKey`. The device starts UNASSIGNED; an admin later associates it to an
  account (by email) in the web panel. Nothing about the secure-transport stack
  (handshake/AEAD/bulk) changes — only this provisioning step.

  ## Proof-of-possession message (authoritative, mirrors the server)

  The signed bytes are reconstructed verbatim by the server in
  `RacingOrg.Devices.register_pop_message/2`:

      "RacingOrg-TrackerRegister-v1"
        || lp(public_key_raw_32)
        || lp(Integer.to_string(timestamp))

  where:

    * the domain `"RacingOrg-TrackerRegister-v1"` is the LITERAL ASCII bytes — it is
      NOT length-prefixed;
    * `lp(x) = u16-big-endian(byte_size(x)) || x` (the same length-prefix framing as
      the secure-transport handshake; a field larger than `0xFFFF` is a hard error,
      never silently truncated);
    * `public_key` is the raw 32-byte Ed25519 public key;
    * `timestamp` is unix SECONDS, length-prefixed as its DECIMAL ASCII string.

  The signature binds the device's identity to a fresh timestamp, so a captured
  request goes stale (the server enforces a freshness window). Re-registering on
  every boot is safe: the server is idempotent (re-register of the same fingerprint
  just refreshes it).

  ## Wire encoding of the request body

  The server's `POST /api/devices/register` decoder operates on RAW binaries; over
  JSON the device encodes the binary fields with STANDARD base64 — the established
  device↔server convention (cf. the `x-racingorg-signature` header and the
  `proto_base64` data-set body). The request body is:

      {
        "public_key":      "<base64(raw 32-byte Ed25519 public key)>",
        "signature":       "<base64(64-byte Ed25519 signature)>",
        "timestamp":       <integer unix seconds>,
        "boat_identifier": "<hostname / optional>"
      }

  ## Responses

    * 201 `{device_id, fingerprint, status, assigned: false}` — recorded.
    * 401 — bad / stale proof-of-possession.
    * 400 — malformed request.
  """

  alias RacingOrg.Tracker.Pro.SecureTransport.IdentityProvider
  alias RacingOrg.Tracker.Pro.SecureTransport.KeyStore
  alias RacingOrg.Tracker.Pro.SecureTransport.Primitives

  @register_pop_domain "RacingOrg-TrackerRegister-v1"
  @default_register_path "/api/devices/register"

  @type identity :: KeyStore.identity()

  @typedoc "A successful registration association the device retains."
  @type register_result :: %{
          device_id: String.t() | nil,
          fingerprint: String.t() | nil,
          status: String.t() | nil,
          raw: map()
        }

  ## --- Pure construction ---------------------------------------------------

  @doc """
  Builds the canonical proof-of-possession message the device must sign.

  Reproduces the server's `register_pop_message/2` byte-for-byte:
  `"RacingOrg-TrackerRegister-v1" || lp(public_key) || lp(Integer.to_string(ts))`.
  The domain is literal ASCII (NOT length-prefixed); the timestamp is the decimal
  ASCII of the unix-seconds integer, length-prefixed. Pure.
  """
  @spec build_register_pop_message(binary(), integer()) :: binary()
  def build_register_pop_message(public_key, timestamp)
      when is_binary(public_key) and is_integer(timestamp) do
    @register_pop_domain <> lp(public_key) <> lp(Integer.to_string(timestamp))
  end

  @doc """
  Signs the proof-of-possession over `timestamp` through the device's operational
  identity provider. Returns the raw 64-byte Ed25519 signature. The raw-seed map
  clause exists only for deterministic v1 compatibility tests.
  """
  @spec sign_register_pop(identity() | map(), integer()) :: binary()
  def sign_register_pop(%IdentityProvider{} = identity, timestamp) do
    message = build_register_pop_message(IdentityProvider.public_key(identity), timestamp)
    IdentityProvider.sign!(identity, message)
  end

  # Deterministic raw-seed compatibility path retained for v1 KATs and pure interop
  # tests. Operational callers use the IdentityProvider clause above.
  def sign_register_pop(%{private_key: private_key, public_key: public_key}, timestamp) do
    message = build_register_pop_message(public_key, timestamp)
    Primitives.ed25519_sign(private_key, message)
  end

  @doc """
  Builds the JSON-ready registration request body (a plain map of string keys).

  Encodes the binary fields with standard base64; the timestamp is the integer
  unix seconds; `boat_identifier` is included only when a non-empty value is given.
  Pure.
  """
  @spec build_register_request(identity() | map(), integer(), String.t() | nil) :: map()
  def build_register_request(identity, timestamp, boat_identifier \\ nil)

  def build_register_request(%IdentityProvider{} = identity, timestamp, boat_identifier) do
    build_register_request_with_public_key(
      identity,
      IdentityProvider.public_key(identity),
      timestamp,
      boat_identifier
    )
  end

  def build_register_request(%{public_key: public_key} = identity, timestamp, boat_identifier) do
    build_register_request_with_public_key(identity, public_key, timestamp, boat_identifier)
  end

  ## --- Registration flow ---------------------------------------------------

  @doc """
  Performs the tokenless self-registration against the server.

  Builds the PoP-signed request from `identity` over a fresh unix-seconds
  timestamp, POSTs it as JSON to the register route, and parses the response.

  Options:

    * `:timestamp` — override the unix-seconds timestamp (default `System.os_time`).
    * `:boat_identifier` — the optional boat identifier (default the device hostname
      via `RacingOrg.Tracker.Pro.boat_identifier/0`).
    * `:register_path` — override the POST path (default `#{@default_register_path}`).
    * `:adapter` — a Tesla adapter (fun or `{module, opts}`) — used to inject a mock
      transport in tests; defaults to the app's configured Tesla adapter.
    * `:base_url` — override the API base (default the configured `:api_endpoint`).

  Returns:

    * `{:ok, register_result}` on 201 (or any 2xx).
    * `{:error, {:register_rejected, status, body}}` on 401 / 400 (and other 4xx).
    * `{:error, {:unexpected_status, status, body}}` for an unhandled status.
    * `{:error, {:transport, reason}}` on a transport-level failure.
  """
  @spec register(identity(), keyword()) ::
          {:ok, register_result()}
          | {:error,
             {:register_rejected, non_neg_integer(), term()}
             | {:unexpected_status, non_neg_integer(), term()}
             | {:transport, term()}}
  def register(identity, opts \\ []) do
    timestamp = Keyword.get_lazy(opts, :timestamp, &now_unix/0)
    boat_identifier = Keyword.get_lazy(opts, :boat_identifier, &default_boat_identifier/0)
    body = build_register_request(identity, timestamp, boat_identifier)
    path = Keyword.get(opts, :register_path, @default_register_path)

    case post_register(path, body, opts) do
      {:ok, %Tesla.Env{status: status} = env} when status in 200..299 ->
        {:ok, parse_success(env.body)}

      {:ok, %Tesla.Env{status: status, body: resp_body}} when status in 400..499 ->
        {:error, {:register_rejected, status, resp_body}}

      {:ok, %Tesla.Env{status: status, body: resp_body}} ->
        {:error, {:unexpected_status, status, resp_body}}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  ## --- internal ------------------------------------------------------------

  defp build_register_request_with_public_key(identity, public_key, timestamp, boat_identifier) do
    signature = sign_register_pop(identity, timestamp)

    %{
      "public_key" => Base.encode64(public_key),
      "signature" => Base.encode64(signature),
      "timestamp" => timestamp
    }
    |> maybe_put_boat_identifier(boat_identifier)
  end

  defp post_register(path, body, opts) do
    middleware = [Tesla.Middleware.JSON]

    client =
      case Keyword.fetch(opts, :adapter) do
        {:ok, adapter} -> Tesla.client(middleware, adapter)
        :error -> Tesla.client(middleware)
      end

    url = Keyword.get(opts, :base_url, configured_api_endpoint()) <> path
    Tesla.post(client, url, body)
  end

  defp configured_api_endpoint do
    Application.get_env(:racing_org_tracker_pro, :api_endpoint, "")
  end

  defp parse_success(body) when is_map(body) do
    %{
      device_id: body["device_id"],
      fingerprint: body["fingerprint"],
      status: body["status"],
      raw: body
    }
  end

  defp parse_success(body),
    do: %{device_id: nil, fingerprint: nil, status: nil, raw: %{"body" => body}}

  defp maybe_put_boat_identifier(map, id) when is_binary(id) and id != "" do
    Map.put(map, "boat_identifier", id)
  end

  defp maybe_put_boat_identifier(map, _), do: map

  defp now_unix, do: System.os_time(:second)

  defp default_boat_identifier do
    RacingOrg.Tracker.Pro.boat_identifier()
  rescue
    _ -> nil
  end

  # Length-prefix framing identical to the server's register PoP and the
  # secure-transport handshake (u16-big-endian length || bytes), with the same hard
  # guard against a field exceeding what a u16 can encode.
  defp lp(bin) when is_binary(bin) and byte_size(bin) <= 0xFFFF do
    <<byte_size(bin)::unsigned-big-integer-size(16), bin::binary>>
  end

  defp lp(bin) when is_binary(bin) do
    raise ArgumentError,
          "register proof-of-possession field exceeds u16 length framing (#{byte_size(bin)} bytes)"
  end
end
