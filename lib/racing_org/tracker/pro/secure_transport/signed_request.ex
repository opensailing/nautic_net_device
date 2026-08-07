defmodule RacingOrg.Tracker.Pro.SecureTransport.SignedRequest do
  @moduledoc """
  Device half of the Phase 6 signed-request assertion for the HTTPS bulk-upload
  plane.

  Every request on the bulk plane (`/api/bulk/...`) carries an Ed25519
  signed-request assertion proving the device's long-term identity
  (`RacingOrg.Tracker.Pro.SecureTransport.KeyStore`). The device signs ONE canonical,
  newline-joined byte string and presents the signature + the inputs the server
  needs to reconstruct and verify it.

  ## The canonical assertion (authoritative — mirrors the server byte-for-byte)

  Reproduces `RacingOrg.SecureTransport.SignedRequest.canonical/5` exactly:

      "racingorg-bulk-v1" \\n        # pinned domain/version tag
      <UPPER METHOD>      \\n        # e.g. "POST"
      <request path>      \\n        # conn.request_path — NO query string
      <lower-hex sha256(body)> \\n   # lowercase hex of SHA-256 over the RAW body bytes
      <unix-seconds timestamp> \\n   # integer unix SECONDS (anti-replay anchor)
      <fingerprint>                 # lowercase-hex SHA-256(public_key)

  joined with `"\\n"`. The body hash is the LOWERCASE HEX of the 32-byte SHA-256
  digest of the exact bytes that will be sent as the request body (for the bulk
  endpoints that is the JSON-encoded body). The server recomputes the hash over
  the raw bytes it receives, so any tampering breaks the signature.

  ## The HTTP headers the server's plug reads

  `RacingOrgWeb.Plugs.DeviceSignedRequest` reads exactly these request headers:

    * `x-racingorg-device-fingerprint` — the device key fingerprint (lowercase hex).
    * `x-racingorg-timestamp`          — the unix SECONDS used in the assertion.
    * `x-racingorg-signature`          — STANDARD base64 of the 64-byte Ed25519
      signature over the canonical assertion.

  The server enforces a `±120s` timestamp window and rejects an exact replay of
  the same `(fingerprint, signature)` inside that window, so the timestamp baked
  into the assertion MUST equal the one sent in the header (this module guarantees
  that by building both from the same value).

  This module builds the canonical bytes, signs them through the operational identity
  provider, and returns the header set. The canonical builder and raw-seed compatibility
  path remain pure for deterministic contract tests.
  """

  alias RacingOrg.Tracker.Pro.SecureTransport.IdentityProvider
  alias RacingOrg.Tracker.Pro.SecureTransport.Primitives

  @domain_tag "racingorg-bulk-v1"

  @fingerprint_header "x-racingorg-device-fingerprint"
  @timestamp_header "x-racingorg-timestamp"
  @signature_header "x-racingorg-signature"

  @typedoc "Headers (name => value) the bulk plane requires on every signed request."
  @type headers :: %{String.t() => String.t()}

  @doc "The pinned domain/version tag baked into every signed assertion."
  @spec domain_tag() :: String.t()
  def domain_tag, do: @domain_tag

  @doc "The request header name carrying the device fingerprint (lowercase hex)."
  @spec fingerprint_header() :: String.t()
  def fingerprint_header, do: @fingerprint_header

  @doc "The request header name carrying the unix-seconds timestamp."
  @spec timestamp_header() :: String.t()
  def timestamp_header, do: @timestamp_header

  @doc "The request header name carrying the base64 Ed25519 signature."
  @spec signature_header() :: String.t()
  def signature_header, do: @signature_header

  @doc """
  Build the canonical assertion bytes for a request.

  `body` is the RAW request body bytes (its SHA-256 is computed + hex-encoded
  here). `method` is upcased; `path` is the request path WITHOUT any query string;
  `timestamp` is unix seconds; `fingerprint` is the device's lowercase-hex
  fingerprint. Mirrors the server's `canonical/5`.
  """
  @spec canonical(String.t(), String.t(), binary(), integer() | String.t(), String.t()) ::
          binary()
  def canonical(method, path, body, timestamp, fingerprint)
      when is_binary(method) and is_binary(path) and is_binary(body) and
             is_binary(fingerprint) do
    Enum.join(
      [
        @domain_tag,
        String.upcase(method),
        path,
        body_hash_hex(body),
        to_string(timestamp),
        fingerprint
      ],
      "\n"
    )
  end

  @doc "Lowercase-hex SHA-256 of the raw `body` bytes (the body-hash binding)."
  @spec body_hash_hex(binary()) :: String.t()
  def body_hash_hex(body) when is_binary(body) do
    body
    |> Primitives.sha256()
    |> Base.encode16(case: :lower)
  end

  @doc """
  Sign the canonical assertion through an operational identity provider.

  A raw 32-byte seed remains accepted only as a deterministic compatibility path for
  pure contract tests and legacy callers.
  """
  @spec sign(IdentityProvider.t() | binary(), String.t(), String.t(), binary(), integer() | String.t(), String.t()) ::
          binary()
  def sign(%IdentityProvider{} = identity, method, path, body, timestamp, fingerprint) do
    if IdentityProvider.fingerprint(identity) != fingerprint do
      raise ArgumentError, "identity fingerprint does not match signed request"
    end

    message = canonical(method, path, body, timestamp, fingerprint)
    IdentityProvider.sign!(identity, message)
  end

  def sign(private_key, method, path, body, timestamp, fingerprint)
      when is_binary(private_key) do
    message = canonical(method, path, body, timestamp, fingerprint)
    Primitives.ed25519_sign(private_key, message)
  end

  @doc """
  Build the full header set the bulk plane expects for one request.

  Given the device `identity` (`%{private_key:, fingerprint:}` — typically a
  `KeyStore.identity/0`), the HTTP `method`, the request `path` (no query string),
  the raw `body` bytes, and the unix-seconds `timestamp`, returns

      %{
        "x-racingorg-device-fingerprint" => <lowercase hex fingerprint>,
        "x-racingorg-timestamp"          => <unix seconds as string>,
        "x-racingorg-signature"          => <base64 Ed25519 signature>
      }

  The timestamp baked into the SIGNED assertion is the SAME value placed in the
  header, so the server's window check + verify agree.
  """
  @spec headers(IdentityProvider.t() | map(), String.t(), String.t(), binary(), integer()) :: headers()
  def headers(%IdentityProvider{} = identity, method, path, body, timestamp)
      when is_binary(method) and is_binary(path) and is_binary(body) and is_integer(timestamp) do
    fingerprint = IdentityProvider.fingerprint(identity)
    signature = sign(identity, method, path, body, timestamp, fingerprint)

    build_headers(fingerprint, timestamp, signature)
  end

  def headers(%{private_key: private_key, fingerprint: fingerprint}, method, path, body, timestamp)
      when is_binary(method) and is_binary(path) and is_binary(body) and is_integer(timestamp) do
    signature = sign(private_key, method, path, body, timestamp, fingerprint)
    build_headers(fingerprint, timestamp, signature)
  end

  @doc "Header set as a Tesla-style list of `{name, value}` tuples."
  @spec header_list(map(), String.t(), String.t(), binary(), integer()) :: [{String.t(), String.t()}]
  def header_list(identity, method, path, body, timestamp) do
    identity
    |> headers(method, path, body, timestamp)
    |> Map.to_list()
  end

  defp build_headers(fingerprint, timestamp, signature) do
    %{
      @fingerprint_header => fingerprint,
      @timestamp_header => Integer.to_string(timestamp),
      @signature_header => Base.encode64(signature)
    }
  end
end
