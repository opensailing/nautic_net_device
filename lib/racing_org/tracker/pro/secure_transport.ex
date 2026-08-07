defmodule RacingOrg.Tracker.Pro.SecureTransport do
  @moduledoc """
  RacingOrg Secure Transport (v2) — a self-contained, transport-agnostic
  cryptographic handshake + authenticated-encryption framing library.

  DEVICE-side port of the RacingOrg Secure Transport crypto core. This implementation
  is **byte-for-byte compatible** with the server's `RacingOrg.SecureTransport.*`
  (the device is the handshake INITIATOR; the server is the RESPONDER). It does
  **not** touch the database, channels, UDP, or protobuf; it operates only on binaries.

  The protocol is specified byte-for-byte in the server's `docs/SECURE_TRANSPORT.md`.
  This module is a thin facade exposing protocol constants and the primary public API.
  The implementation lives in:

    * `RacingOrg.Tracker.Pro.SecureTransport.Primitives` — `:crypto` wrappers (Ed25519, X25519,
      ChaCha20-Poly1305 with the mandatory structural tag/nonce checks), X25519 point
      validation, constant-time compare.
    * `RacingOrg.Tracker.Pro.SecureTransport.HKDF` — RFC 5869 HKDF over HMAC-SHA256.
    * `RacingOrg.Tracker.Pro.SecureTransport.Handshake` — initiator + responder roles.
    * `RacingOrg.Tracker.Pro.SecureTransport.Session` — established session state.
    * `RacingOrg.Tracker.Pro.SecureTransport.Frame` — wire framing, seal/open.
    * `RacingOrg.Tracker.Pro.SecureTransport.ReplayWindow` — per-(session,epoch) replay defence.

  ## Cipher suite (pinned, single, non-negotiable)

  ChaCha20-Poly1305 (IETF) only — 12-byte nonce, 16-byte tag — via
  `:crypto.crypto_one_time_aead/6,7`. AES-GCM and XChaCha20 are deliberately
  unreachable (see the spec for the empirically-validated reasons).

  Uses only `:crypto` functions present and identical on OTP 27 (server) and OTP 28
  (device). Zero native dependencies.
  """

  # --- Protocol constants (see docs/SECURE_TRANSPORT.md §3) ---

  # Protocol version 0x02 (spec v2): epoch is now bound into the handshake transcript
  # and both signed payloads (and travels on the HELLO/INIT wire), and the
  # purpose-byte registry reserves the whole 0x00..0x7F range for protocol-internal
  # use. See docs/SECURE_TRANSPORT.md (v2) §3, §4, §6.4.
  @protocol_version 0x02
  @magic "SRT1"

  @type_handshake_init 0x01
  @type_handshake_resp 0x02
  @type_data 0x10

  @aead_chacha20_poly1305 0x01

  # Purpose ids (u8) — domain separation of derived keys.
  #
  # 0x00..0x7F is RESERVED for protocol-internal use (session keys, session-id, and any
  # future internal derivation). `derive_purpose_key/3` rejects every byte in this
  # range. External/second-consumer purposes MUST come from the disjoint 0x80..0xFF
  # range. See docs/SECURE_TRANSPORT.md (v2) §6.4.
  @purpose_session 0x01
  @purpose_session_id 0x03
  # Lowest purpose byte an external consumer may use; the boundary of the reserved
  # internal range (everything below is protocol-internal / reserved).
  @purpose_external_min 0x80
  # A SECOND consumer (e.g. a bulk HTTPS download key). Moved into the external range.
  @purpose_https_bulk 0x80
  # Desired-state-only control_v1 AEAD envelope. This remains independent from both
  # session data and HTTPS bulk counters/replay state.
  @purpose_control_v1 0x81

  @dir_device_to_server 0x01
  @dir_server_to_device 0x02

  @role_initiator 0x01
  @role_responder 0x02

  @hkdf_label "RacingOrg-SecureTransport-v1"

  # Fixed sizes
  @key_size 32
  @nonce_size 12
  @tag_size 16
  @x25519_key_size 32
  @ed25519_pub_size 32
  @ed25519_sig_size 64
  @server_nonce_size 32
  @session_id_size 16
  @header_size 35

  # session_epoch is a u32 in both the nonce (§5) and the HKDF info (§6). Deriving keys
  # or sealing with epoch > this value would alias epoch 0 (and reuse a (key, nonce)
  # pair), so it is a hard error (`:epoch_exhausted`), never a wrap. See §5.
  @epoch_max 0xFFFF_FFFF

  # Rekey safety threshold: a fresh-ephemeral re-handshake MUST occur before a
  # direction's per-epoch counter reaches this. 2^48 is an enormous margin below the
  # 2^64 nonce-counter space. Reaching 2^64-1 is a hard error, never a wrap.
  @rekey_after 0x0001_0000_0000_0000
  @counter_max 0xFFFF_FFFF_FFFF_FFFF

  def protocol_version, do: @protocol_version
  def magic, do: @magic

  def type_handshake_init, do: @type_handshake_init
  def type_handshake_resp, do: @type_handshake_resp
  def type_data, do: @type_data

  def aead_chacha20_poly1305, do: @aead_chacha20_poly1305

  def purpose_session, do: @purpose_session
  def purpose_https_bulk, do: @purpose_https_bulk
  def purpose_control_v1, do: @purpose_control_v1
  def purpose_session_id, do: @purpose_session_id
  def purpose_external_min, do: @purpose_external_min

  @doc """
  The protocol-internal purpose bytes that `Handshake.derive_purpose_key/3` must
  refuse (they are produced by the handshake itself; re-deriving them as an
  "external" key would reproduce real session key material — e.g. the public
  cleartext session_id). The whole `0x00..0x7F` range is reserved, but these are the
  ones with assigned meaning.
  """
  def reserved_internal_purposes, do: [@purpose_session, @purpose_session_id]

  def dir_device_to_server, do: @dir_device_to_server
  def dir_server_to_device, do: @dir_server_to_device

  def role_initiator, do: @role_initiator
  def role_responder, do: @role_responder

  def hkdf_label, do: @hkdf_label

  def key_size, do: @key_size
  def nonce_size, do: @nonce_size
  def tag_size, do: @tag_size
  def x25519_key_size, do: @x25519_key_size
  def ed25519_pub_size, do: @ed25519_pub_size
  def ed25519_sig_size, do: @ed25519_sig_size
  def server_nonce_size, do: @server_nonce_size
  def session_id_size, do: @session_id_size
  def header_size, do: @header_size

  def rekey_after, do: @rekey_after
  def counter_max, do: @counter_max
  def epoch_max, do: @epoch_max

  # --- Primary public API (delegated) ---

  alias RacingOrg.Tracker.Pro.SecureTransport.{Frame, Handshake, Primitives}

  @doc "Generate a long-term Ed25519 identity keypair: `{public32, private32}`."
  defdelegate generate_identity_keypair(), to: Primitives

  @doc "Generate a fresh ephemeral X25519 keypair: `{public32, private32}`."
  defdelegate generate_ephemeral_keypair(), to: Primitives

  @doc "Build the responder HELLO (server-first). See `Handshake.responder_hello/1`."
  defdelegate responder_hello(opts), to: Handshake

  @doc "Initiator consumes HELLO, produces INIT + a pending state. See `Handshake`."
  defdelegate initiator_init(hello_wire, opts), to: Handshake

  @doc "Responder consumes INIT, returns the established `Session`. See `Handshake`."
  defdelegate responder_finalize(state, init_wire), to: Handshake

  @doc "Seal a plaintext into a wire frame over a `Session`."
  defdelegate seal(session, plaintext), to: Frame

  @doc "Open a wire frame against a `Session`."
  defdelegate open(session, frame), to: Frame
end
