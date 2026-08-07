defmodule RacingOrg.Tracker.Pro.SecureTransport.Session do
  @moduledoc """
  An established secure-transport session (immutable value).

  Holds the deterministic cleartext routing id, the current epoch, the two
  per-direction AEAD keys, the outbound send counter, and the inbound replay window.
  Created by `RacingOrg.Tracker.Pro.SecureTransport.Handshake`; consumed by
  `RacingOrg.Tracker.Pro.SecureTransport.Frame`.

  The ephemeral X25519 private key is deliberately NOT stored here (it is dropped
  immediately after key agreement). Only symmetric keys derived for this epoch live
  in the struct.

  Keys are role-oriented:

    * `:out_key` — the key this side uses to SEAL (its outbound direction).
    * `:in_key`  — the key this side uses to OPEN (the peer's outbound direction).

  For a device (initiator) `:out_key` is the device→server key and `:in_key` is the
  server→device key; for the server (responder) it is the reverse. This means
  `Frame.seal/open` never has to branch on role.

  `:epoch` is a **u32** (it is serialized as `u32` in both the frame nonce — see
  `Frame.nonce/2` — and the HKDF `info` — see the spec §5/§6). It MUST stay within
  `0..0xFFFF_FFFF`. The handshake refuses to derive keys for an out-of-range epoch
  (`:epoch_exhausted`) and `Frame.seal/2` refuses to seal one, mirroring the
  `:counter_exhausted`/`:rekey_required` guards, so the epoch can never silently wrap
  to 0 and reuse a (key, nonce) pair.
  """

  alias RacingOrg.Tracker.Pro.SecureTransport.ReplayWindow

  @enforce_keys [:role, :session_id, :epoch, :out_key, :in_key]
  defstruct [
    :role,
    :session_id,
    :epoch,
    :credential_epoch,
    :generation,
    :out_key,
    :in_key,
    :transcript_hash,
    :peer_identity_fingerprint,
    # The handshake PRK is retained (secret) so additional domain-separated keys for
    # OTHER purposes (e.g. an HTTPS-bulk key) can be derived identically on both sides
    # via HKDF-Expand. It is symmetric (same on both peers) and never logged/persisted.
    :prk,
    :identity_fingerprint,
    send_counter: 0,
    replay_window: nil
  ]

  @type role :: :initiator | :responder

  @type t :: %__MODULE__{
          role: role(),
          session_id: binary(),
          epoch: non_neg_integer(),
          credential_epoch: non_neg_integer(),
          generation: non_neg_integer() | nil,
          out_key: binary(),
          in_key: binary(),
          transcript_hash: binary() | nil,
          peer_identity_fingerprint: binary() | nil,
          prk: binary() | nil,
          identity_fingerprint: binary() | nil,
          send_counter: non_neg_integer(),
          replay_window: ReplayWindow.t() | nil
        }

  @doc "Build a session, initializing the inbound replay window."
  @spec new(keyword()) :: t()
  def new(fields) do
    fields = Keyword.put_new(fields, :credential_epoch, Keyword.fetch!(fields, :epoch))

    struct!(__MODULE__, fields)
    |> Map.update!(:replay_window, fn
      nil -> ReplayWindow.new()
      %ReplayWindow{} = w -> w
    end)
  end
end
