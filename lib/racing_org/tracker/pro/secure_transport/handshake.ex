defmodule RacingOrg.Tracker.Pro.SecureTransport.Handshake do
  @moduledoc """
  Mutually authenticated, forward-secret handshake (initiator = device,
  responder = server). Pure functions over binaries; no transport.

  Flow (server-first; see the server's `docs/SECURE_TRANSPORT.md` §4):

      responder_hello/1   -> {hello_wire, responder_state}
      initiator_init/2    -> {init_wire, session}        (device side, derives keys)
      responder_finalize/2 -> {:ok, session} | {:error}  (server side, derives keys)

  The DEVICE is the INITIATOR (`initiator_init/2`). The responder role functions are
  ported too so the device can self-interop test and so the cross-implementation
  golden can be reproduced byte-for-byte on the device.

  Both sides derive the SAME per-direction keys from the SAME transcript. Each side
  generates a FRESH ephemeral X25519 keypair (forward secrecy); the ephemeral private
  is used only to compute the shared secret and is then dropped (never stored in the
  `Session`, never logged).

  All signed payloads and the transcript are canonical, length-prefixed, and bind the
  protocol version + pinned AEAD id, so a downgrade fails closed.
  """

  import Bitwise, only: [&&&: 2]

  alias RacingOrg.Tracker.Pro.SecureTransport, as: ST
  alias RacingOrg.Tracker.Pro.SecureTransport.{HKDF, IdentityProvider, Primitives, Session}

  # ---- Wire (de)serialization helpers ----

  defp lp(bin) when is_binary(bin) and byte_size(bin) <= 0xFFFF do
    <<byte_size(bin)::16, bin::binary>>
  end

  defp take_lp(<<len::16, rest::binary>>) when byte_size(rest) >= len do
    <<value::binary-size(len), tail::binary>> = rest
    {:ok, value, tail}
  end

  defp take_lp(_), do: {:error, :truncated}

  # ---- Responder: produce HELLO ----

  @doc """
  Responder (server) step 1: produce the HELLO wire message and a state to finalize
  with once the initiator's INIT arrives.

  Options:

    * `:server_identity_private` (required) — server long-term Ed25519 private (seed).
    * `:server_identity_public` (required) — server long-term Ed25519 public.
    * `:device_identity_public` (required) — the device's stored Ed25519 public key.
    * `:ephemeral` (optional) — `{pub, priv}` X25519 (for deterministic tests);
      a fresh pair is generated when omitted.
    * `:server_nonce` (optional) — EXACTLY 32 bytes (tests); a fresh 32-byte
      `strong_rand_bytes` nonce is generated when omitted. A supplied nonce of any
      other length is rejected (`:bad_server_nonce_length`) before any signing/state.
    * `:epoch` (optional) — session epoch (default 0). Bound into the transcript hash
      and BOTH signed payloads and carried on the HELLO/INIT wire, so the device and
      server must agree on the epoch (a mismatch fails closed with `:epoch_mismatch`,
      not via silent key divergence). Must be in `0..#{0xFFFF_FFFF}`
      (else `:epoch_exhausted`).

  Returns `{:ok, hello_wire, state}` or `{:error, reason}`.
  """
  @spec responder_hello(keyword()) :: {:ok, binary(), map()} | {:error, atom()}
  def responder_hello(opts) do
    with {:ok, srv_priv} <- fetch(opts, :server_identity_private),
         {:ok, srv_pub} <- fetch(opts, :server_identity_public),
         {:ok, dev_pub} <- fetch(opts, :device_identity_public),
         {:ok, {eph_pub_s, eph_priv_s}} <- ephemeral(opts),
         {:ok, epoch} <- valid_epoch(Keyword.get(opts, :epoch, 0)),
         {:ok, server_nonce} <- server_nonce(opts) do
      server_id_fp = Primitives.sha256(srv_pub)
      device_id_fp = Primitives.sha256(dev_pub)

      resp_signed = resp_signed(server_nonce, eph_pub_s, server_id_fp, epoch)
      sig_s = Primitives.ed25519_sign(srv_priv, resp_signed)

      hello_wire =
        <<ST.magic()::binary, ST.protocol_version(), ST.type_handshake_resp(), ST.aead_chacha20_poly1305()>> <>
          lp(server_nonce) <> lp(eph_pub_s) <> lp(server_id_fp) <> <<epoch::32>> <> lp(sig_s)

      state = %{
        role: :responder,
        epoch: epoch,
        eph_pub_s: eph_pub_s,
        eph_priv_s: eph_priv_s,
        server_nonce: server_nonce,
        server_id_fp: server_id_fp,
        device_identity_public: dev_pub,
        device_id_fp: device_id_fp
      }

      {:ok, hello_wire, state}
    end
  end

  # The server nonce is the HKDF salt AND the primary anti-replay binding (§4.1/§6.1).
  # A supplied nonce MUST be exactly server_nonce_size() bytes; otherwise generate a
  # fresh strong-random one. Rejected BEFORE any key/state is produced.
  defp server_nonce(opts) do
    case Keyword.fetch(opts, :server_nonce) do
      :error -> {:ok, rand(ST.server_nonce_size())}
      {:ok, n} when is_binary(n) and byte_size(n) == 32 -> {:ok, n}
      {:ok, _} -> {:error, :bad_server_nonce_length}
    end
  end

  # ---- Initiator: consume HELLO, produce INIT, derive keys ----

  @doc """
  Initiator (device) step: parse the responder HELLO, authenticate the server,
  produce the INIT wire message, and derive the session keys.

  Options:

    * `:device_identity` — operational `IdentityProvider` handle used by production callers.
    * `:device_identity_private` / `:device_identity_public` — deterministic raw-seed
      compatibility path for pure KAT/interoperability tests when `:device_identity` is absent.
    * `:server_identity_public` (required) — the FIRMWARE-PINNED server Ed25519 pub.
    * `:device_id` (required) — opaque device identifier bytes.
    * `:ephemeral` (optional) — `{pub, priv}` X25519 (tests).
    * `:timestamp_ms` (optional) — device clock, advisory; defaults to system time.
    * `:epoch` (optional) — when supplied, pins the session epoch for deterministic
      compatibility callers. The signed HELLO is authenticated first, then a mismatch is
      rejected with `:epoch_mismatch`. When omitted, the authenticated HELLO epoch is
      adopted and bound into the INIT signature + transcript.
    * `:credential_epoch` (optional) — durable minimum credential epoch. A correctly
      signed HELLO below it is rejected with `:epoch_downgrade`. Both values must remain
      in `0..#{0xFFFF_FFFF}` (else `:epoch_exhausted`).

  Returns `{:ok, init_wire, session}` or `{:error, reason}`.
  """
  @spec initiator_init(binary(), keyword()) ::
          {:ok, binary(), Session.t()} | {:error, term()}
  def initiator_init(hello_wire, opts) do
    with {:ok, device_identity} <- initiator_identity(opts),
         dev_pub = initiator_public_key(device_identity),
         {:ok, srv_pub} <- fetch(opts, :server_identity_public),
         {:ok, device_id} <- fetch(opts, :device_id),
         {:ok, hello} <- parse_hello(hello_wire),
         :ok <- verify_server_hello(hello, srv_pub),
         {:ok, epoch} <- initiator_epoch(hello.epoch, opts),
         {:ok, {eph_pub_d, eph_priv_d}} <- ephemeral(opts),
         {:ok, shared} <- Primitives.x25519_shared(hello.eph_pub_s, eph_priv_d),
         timestamp_ms = Keyword.get_lazy(opts, :timestamp_ms, &System.system_time/0) |> normalize_ts(),
         init_signed =
           init_signed(device_id, eph_pub_d, hello.eph_pub_s, hello.server_nonce, epoch, timestamp_ms),
         {:ok, sig_d} <- sign_initiator_identity(device_identity, init_signed) do
      init_wire =
        <<ST.magic()::binary, ST.protocol_version(), ST.type_handshake_init(), ST.aead_chacha20_poly1305()>> <>
          lp(device_id) <>
          lp(eph_pub_d) <>
          lp(hello.eph_pub_s) <>
          lp(hello.server_nonce) <>
          <<epoch::32>> <>
          <<timestamp_ms::64>> <>
          lp(sig_d)

      device_id_fp = Primitives.sha256(dev_pub)

      session =
        derive_session(
          :initiator,
          shared,
          hello.server_nonce,
          hello.eph_pub_s,
          eph_pub_d,
          device_id,
          hello.server_id_fp,
          device_id_fp,
          epoch
        )

      {:ok, init_wire, session}
    end
  end

  # ---- Responder: consume INIT, derive keys ----

  @doc """
  Responder (server) finalize: parse the initiator INIT, verify it binds to THIS
  server's ephemeral + nonce, verify the device's Ed25519 signature, complete key
  agreement, and derive the session.

  Returns `{:ok, session}` or `{:error, reason}`.
  """
  @spec responder_finalize(map(), binary()) :: {:ok, Session.t()} | {:error, atom()}
  def responder_finalize(%{role: :responder} = state, init_wire) do
    with {:ok, epoch} <- valid_epoch(Map.get(state, :epoch, 0)),
         {:ok, init} <- parse_init(init_wire),
         :ok <- ensure(init.epoch == epoch, :epoch_mismatch),
         :ok <- ensure(Primitives.secure_compare(init.eph_pub_s, state.eph_pub_s), :ephemeral_mismatch),
         :ok <- ensure(Primitives.secure_compare(init.server_nonce, state.server_nonce), :nonce_mismatch),
         :ok <- verify_device_init(init, state.device_identity_public),
         {:ok, shared} <- Primitives.x25519_shared(init.eph_pub_d, state.eph_priv_s) do
      session =
        derive_session(
          :responder,
          shared,
          state.server_nonce,
          state.eph_pub_s,
          init.eph_pub_d,
          init.device_id,
          state.server_id_fp,
          state.device_id_fp,
          epoch
        )

      {:ok, session}
    end
  end

  def responder_finalize(_, _), do: {:error, :not_responder_state}

  # ---- Parsing ----

  defp parse_hello(<<"SRT1", ver, type, aead, rest::binary>>) do
    cond do
      ver != ST.protocol_version() -> {:error, :bad_version}
      type != ST.type_handshake_resp() -> {:error, :bad_type}
      aead != ST.aead_chacha20_poly1305() -> {:error, :bad_aead_id}
      true -> parse_hello_fields(rest)
    end
  end

  defp parse_hello(_), do: {:error, :bad_magic}

  defp parse_hello_fields(rest) do
    with {:ok, server_nonce, r1} <- take_lp(rest),
         {:ok, eph_pub_s, r2} <- take_lp(r1),
         {:ok, server_id_fp, <<epoch::32, r3::binary>>} <- take_lp(r2),
         {:ok, sig_s, <<>>} <- take_lp(r3) do
      {:ok,
       %{
         server_nonce: server_nonce,
         eph_pub_s: eph_pub_s,
         server_id_fp: server_id_fp,
         epoch: epoch,
         sig_s: sig_s
       }}
    else
      {:ok, _, _trailing} -> {:error, :trailing_bytes}
      {:error, _} = err -> err
      _ -> {:error, :truncated}
    end
  end

  defp parse_init(<<"SRT1", ver, type, aead, rest::binary>>) do
    cond do
      ver != ST.protocol_version() -> {:error, :bad_version}
      type != ST.type_handshake_init() -> {:error, :bad_type}
      aead != ST.aead_chacha20_poly1305() -> {:error, :bad_aead_id}
      true -> parse_init_fields(rest)
    end
  end

  defp parse_init(_), do: {:error, :bad_magic}

  defp parse_init_fields(rest) do
    with {:ok, device_id, r1} <- take_lp(rest),
         {:ok, eph_pub_d, r2} <- take_lp(r1),
         {:ok, eph_pub_s, r3} <- take_lp(r2),
         {:ok, server_nonce, <<epoch::32, timestamp_ms::64, r4::binary>>} <- take_lp(r3),
         {:ok, sig_d, <<>>} <- take_lp(r4) do
      {:ok,
       %{
         device_id: device_id,
         eph_pub_d: eph_pub_d,
         eph_pub_s: eph_pub_s,
         server_nonce: server_nonce,
         epoch: epoch,
         timestamp_ms: timestamp_ms,
         sig_d: sig_d
       }}
    else
      {:ok, _, _trailing} -> {:error, :trailing_bytes}
      {:error, _} = err -> err
      _ -> {:error, :truncated}
    end
  end

  # ---- Signature verification (reconstruct the canonical signed payloads) ----

  defp verify_server_hello(hello, server_identity_public) do
    with :ok <- ensure(byte_size(hello.server_nonce) == ST.server_nonce_size(), :bad_server_nonce_length),
         :ok <- Primitives.validate_x25519_public(hello.eph_pub_s),
         :ok <-
           ensure(
             Primitives.secure_compare(hello.server_id_fp, Primitives.sha256(server_identity_public)),
             :server_fp_mismatch
           ) do
      resp_signed = resp_signed(hello.server_nonce, hello.eph_pub_s, hello.server_id_fp, hello.epoch)

      if Primitives.ed25519_verify(server_identity_public, resp_signed, hello.sig_s) do
        :ok
      else
        {:error, :bad_server_signature}
      end
    end
  end

  defp verify_device_init(init, device_identity_public) do
    with :ok <- Primitives.validate_x25519_public(init.eph_pub_d) do
      init_signed =
        init_signed(init.device_id, init.eph_pub_d, init.eph_pub_s, init.server_nonce, init.epoch, init.timestamp_ms)

      if Primitives.ed25519_verify(device_identity_public, init_signed, init.sig_d) do
        :ok
      else
        {:error, :bad_device_signature}
      end
    end
  end

  # ---- Canonical signed payloads (shared by produce + verify) ----
  #
  # epoch is bound into BOTH payloads (and the transcript, §4.5) so the two sides must
  # agree on the epoch. The initiator authenticates the HELLO before adopting/checking
  # its epoch; any on-wire tamper of the epoch field therefore breaks the signature.

  defp resp_signed(server_nonce, eph_pub_s, server_id_fp, epoch) do
    lp(ST.magic()) <>
      <<ST.protocol_version(), ST.role_responder(), ST.aead_chacha20_poly1305()>> <>
      lp(server_nonce) <> lp(eph_pub_s) <> lp(server_id_fp) <> <<epoch::32>>
  end

  defp init_signed(device_id, eph_pub_d, eph_pub_s, server_nonce, epoch, timestamp_ms) do
    lp(ST.magic()) <>
      <<ST.protocol_version(), ST.role_initiator(), ST.aead_chacha20_poly1305()>> <>
      lp(device_id) <>
      lp(eph_pub_d) <>
      lp(eph_pub_s) <>
      lp(server_nonce) <>
      <<epoch::32>> <> <<timestamp_ms::64>>
  end

  # ---- Key derivation (identical on both sides) ----

  defp derive_session(
         role,
         shared,
         server_nonce,
         eph_pub_s,
         eph_pub_d,
         device_id,
         server_id_fp,
         device_id_fp,
         epoch
       ) do
    transcript_hash =
      Primitives.sha256(
        # epoch is bound into the transcript (v2) so the session_id + both
        # per-direction keys differ per epoch and the two sides must agree on it.
        lp(ST.magic()) <>
          <<ST.protocol_version(), ST.aead_chacha20_poly1305()>> <>
          lp(server_nonce) <>
          lp(eph_pub_s) <>
          lp(eph_pub_d) <>
          lp(device_id) <>
          lp(server_id_fp) <>
          lp(device_id_fp) <>
          <<epoch::32>>
      )

    prk = HKDF.extract(server_nonce, shared)

    # identity_fingerprint bound into info = the DEVICE identity fingerprint.
    k_d2s =
      HKDF.expand(
        prk,
        info(ST.purpose_session(), ST.dir_device_to_server(), device_id_fp, epoch, transcript_hash),
        ST.key_size()
      )

    k_s2d =
      HKDF.expand(
        prk,
        info(ST.purpose_session(), ST.dir_server_to_device(), device_id_fp, epoch, transcript_hash),
        ST.key_size()
      )

    session_id =
      HKDF.expand(
        prk,
        info(ST.purpose_session_id(), 0x00, device_id_fp, epoch, transcript_hash),
        ST.session_id_size()
      )

    {out_key, in_key} =
      case role do
        :initiator -> {k_d2s, k_s2d}
        :responder -> {k_s2d, k_d2s}
      end

    Session.new(
      role: role,
      session_id: session_id,
      epoch: epoch,
      out_key: out_key,
      in_key: in_key,
      transcript_hash: transcript_hash,
      peer_identity_fingerprint: peer_fp(role, device_id_fp, server_id_fp),
      prk: prk,
      identity_fingerprint: device_id_fp
    )
  end

  defp peer_fp(:initiator, _device_id_fp, server_id_fp), do: server_id_fp
  defp peer_fp(:responder, device_id_fp, _server_id_fp), do: device_id_fp

  @doc """
  Derive an additional domain-separated 32-byte key from a completed session, for a
  second consumer (e.g. an HTTPS-bulk-download key). Expanded from the handshake PRK
  with the same structured, transcript- and epoch-bound `info` as the session keys,
  but with a DIFFERENT `purpose` byte, so it can never collide with a session key.
  Because it expands from the shared PRK (not a per-side key), both peers derive the
  same value.

  ## Purpose-byte domain separation (v2)

  The whole `0x00..0x7F` range is RESERVED for protocol-internal derivations
  (`PURPOSE_SESSION = 0x01`, `PURPOSE_SESSION_ID = 0x03`, and any future internal
  purpose). External consumers MUST use a byte in the disjoint `0x80..0xFF` range.

  This closes a domain-separation hole: previously only `0x01` was rejected, so
  `derive_purpose_key(session, 0x03, 0x00)` reproduced the PUBLIC cleartext
  `session_id` as the first 16 bytes of a "secret" key. Every reserved internal byte
  is now refused (`:purpose_reserved`), and anything outside the external range is
  refused (`:purpose_out_of_range`).

  Returns `{:ok, key32}` or `{:error, reason}`.
  """
  @spec derive_purpose_key(Session.t(), non_neg_integer(), non_neg_integer()) ::
          {:ok, binary()} | {:error, atom()}
  def derive_purpose_key(%Session{prk: nil}, _purpose, _direction),
    do: {:error, :session_missing_prk}

  def derive_purpose_key(%Session{} = session, purpose, direction)
      when is_integer(purpose) and is_integer(direction) and direction >= 0 and direction <= 255 do
    cond do
      # Reserved protocol-internal range. Reject every byte below the external
      # boundary so no external caller can reproduce session keys, the session_id, or
      # any future internal key material.
      purpose < ST.purpose_external_min() ->
        {:error, :purpose_reserved}

      purpose > 0xFF ->
        {:error, :purpose_out_of_range}

      true ->
        key =
          HKDF.expand(
            session.prk,
            info(
              purpose,
              direction,
              session.identity_fingerprint || <<>>,
              session.epoch,
              session.transcript_hash || <<>>
            ),
            ST.key_size()
          )

        {:ok, key}
    end
  end

  def derive_purpose_key(%Session{}, _purpose, _direction), do: {:error, :bad_purpose}

  defp info(purpose, direction, identity_fp, epoch, transcript_hash) do
    lp(ST.hkdf_label()) <>
      <<ST.protocol_version(), purpose, direction, ST.aead_chacha20_poly1305()>> <>
      lp(identity_fp) <>
      <<epoch::32>> <>
      lp(transcript_hash)
  end

  # ---- small helpers ----

  defp initiator_identity(opts) do
    case Keyword.fetch(opts, :device_identity) do
      {:ok, %IdentityProvider{} = identity} ->
        {:ok, {:provider, identity}}

      {:ok, _other} ->
        {:error, :bad_device_identity}

      :error ->
        with {:ok, private_key} <- fetch(opts, :device_identity_private),
             {:ok, public_key} <- fetch(opts, :device_identity_public) do
          {:ok, {:raw_seed, private_key, public_key}}
        end
    end
  end

  defp initiator_public_key({:provider, identity}), do: IdentityProvider.public_key(identity)
  defp initiator_public_key({:raw_seed, _private_key, public_key}), do: public_key

  defp sign_initiator_identity({:provider, identity}, message), do: IdentityProvider.sign(identity, message)

  defp sign_initiator_identity({:raw_seed, private_key, _public_key}, message) do
    {:ok, Primitives.ed25519_sign(private_key, message)}
  end

  defp fetch(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, val} -> {:ok, val}
      :error -> {:error, :"missing_option_#{key}"}
    end
  end

  defp ephemeral(opts) do
    case Keyword.get(opts, :ephemeral) do
      nil -> {:ok, Primitives.generate_ephemeral_keypair()}
      {pub, priv} when is_binary(pub) and is_binary(priv) -> {:ok, {pub, priv}}
      _ -> {:error, :bad_ephemeral}
    end
  end

  defp initiator_epoch(hello_epoch, opts) do
    with {:ok, hello_epoch} <- valid_epoch(hello_epoch),
         :ok <- ensure_pinned_epoch(hello_epoch, opts),
         :ok <- ensure_minimum_credential_epoch(hello_epoch, opts) do
      {:ok, hello_epoch}
    end
  end

  defp ensure_pinned_epoch(hello_epoch, opts) do
    case Keyword.fetch(opts, :epoch) do
      :error ->
        :ok

      {:ok, pinned_epoch} ->
        with {:ok, pinned_epoch} <- valid_epoch(pinned_epoch),
             :ok <- ensure(hello_epoch == pinned_epoch, :epoch_mismatch) do
          :ok
        end
    end
  end

  defp ensure_minimum_credential_epoch(hello_epoch, opts) do
    case Keyword.fetch(opts, :credential_epoch) do
      :error ->
        :ok

      {:ok, minimum_epoch} ->
        with {:ok, minimum_epoch} <- valid_epoch(minimum_epoch),
             :ok <- ensure(hello_epoch >= minimum_epoch, :epoch_downgrade) do
          :ok
        end
    end
  end

  defp ensure(true, _reason), do: :ok
  defp ensure(false, reason), do: {:error, reason}

  # session_epoch is a u32 (in both the nonce and the HKDF info). Refuse to derive keys
  # for an epoch that would overflow u32 and alias epoch 0 -> (key, nonce) reuse.
  defp valid_epoch(epoch) when is_integer(epoch) and epoch >= 0 and epoch <= 0xFFFF_FFFF,
    do: {:ok, epoch}

  defp valid_epoch(_), do: {:error, :epoch_exhausted}

  defp rand(n), do: :crypto.strong_rand_bytes(n)

  # Coerce a possibly-large native time into a u64 by masking. timestamp is advisory.
  defp normalize_ts(ts) when is_integer(ts) and ts >= 0,
    do: ts &&& 0xFFFF_FFFF_FFFF_FFFF

  defp normalize_ts(_), do: 0
end
