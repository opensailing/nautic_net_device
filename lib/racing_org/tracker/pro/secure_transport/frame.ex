defmodule RacingOrg.Tracker.Pro.SecureTransport.Frame do
  @moduledoc """
  Wire framing and authenticated encryption over an established `Session`.

  Frame layout (see `docs/SECURE_TRANSPORT.md` §12):

      header (35 bytes) || ciphertext || tag (16 bytes)

      header = magic("SRT1") || version || type(0x10) || aead_alg_id
            || session_id(16) || epoch(u32) || counter(u64)

  The ENTIRE 35-byte header is the AEAD AAD, so any tamper (flipped magic/version/
  type/aead id, re-pointed session id, altered epoch/counter) fails the tag. The
  nonce is reconstructed from the header (`epoch || counter`) and is NOT transmitted,
  guaranteeing it matches the authenticated routing/replay metadata.

  `seal/2` advances the session send counter (refusing at the u64 ceiling and
  signalling when the rekey threshold is reached). `open/2` enforces, in order:
  structural tag/nonce length checks, epoch match, replay window, then AEAD verify;
  the replay window is committed only AFTER a successful open so a forgery cannot
  poison it.
  """

  alias RacingOrg.Tracker.Pro.SecureTransport, as: ST
  alias RacingOrg.Tracker.Pro.SecureTransport.{Primitives, ReplayWindow, Session}

  @doc """
  Seal `plaintext` into a wire frame using the session's outbound key and current
  send counter. Returns `{:ok, frame, session'}` where `session'` has the counter
  advanced, or `{:error, reason}`.

  `{:error, :counter_exhausted}` is returned at the u64 ceiling (the library refuses
  to wrap). `{:error, :rekey_required}` is returned once the send counter reaches the
  spec's `rekey_after/0` threshold — the caller MUST perform a fresh-ephemeral
  re-handshake (new epoch) rather than continue. `{:error, :epoch_exhausted}` is
  returned if the session's epoch exceeds the u32 ceiling (`epoch_max/0`): the epoch is
  a u32 in both the nonce and the HKDF info, so sealing past it would alias epoch 0 and
  reuse a (key, nonce) pair.
  """
  @spec seal(Session.t(), binary()) ::
          {:ok, binary(), Session.t()} | {:error, atom()}
  def seal(%Session{} = session, plaintext) when is_binary(plaintext) do
    counter = session.send_counter

    case seal_with(session.session_id, session.epoch, counter, session.out_key, plaintext) do
      {:ok, frame} -> {:ok, frame, %{session | send_counter: counter + 1}}
      {:error, _} = err -> err
    end
  end

  @doc """
  Stateless variant of `seal/2`: seal `plaintext` into a wire frame from the
  EXPLICIT `(session_id, epoch, counter, out_key)` with NO `Session` and NO counter
  management.

  This is what the P9-job-4 UDP telemetry path uses. `RacingOrg.Tracker.Pro.SecureTransport.SessionHolder`
  is the single owner of the send counter; `with_send_counter/2,3` hands its
  caller a `(session_id, out_key, epoch, counter)` grant under a bounded send lease,
  and this function turns that grant + the encoded DataSet into the wire frame.
  Because the counter is reserved by the holder (never re-used), this function does
  not need — and must not have — mutable state. The lease separately prevents that
  reserved old-session frame from crossing transport after replacement.

  `take_send_counter/1,2` can also supply these inputs, but those grants are
  reservation-only and must not be carried directly to a production transport
  boundary without an equivalent session lease/freshness gate.

  The produced bytes are BYTE-IDENTICAL to `seal/2` for the same inputs (the golden
  DATA frame proves it): `header(35) || ciphertext || tag(16)`, nonce `epoch||counter`,
  AAD = the full header, ChaCha20-Poly1305 under `out_key`.

  Returns `{:ok, frame}`, or `{:error, reason}` on the same ceiling/rekey guards as
  `seal/2` (`:epoch_exhausted`, `:counter_exhausted`, `:rekey_required`) or an AEAD
  failure.
  """
  @spec seal_with(binary(), non_neg_integer(), non_neg_integer(), binary(), binary()) ::
          {:ok, binary()} | {:error, atom()}
  def seal_with(<<session_id::binary-size(16)>>, epoch, counter, out_key, plaintext)
      when is_integer(epoch) and epoch >= 0 and is_integer(counter) and counter >= 0 and
             is_binary(out_key) and is_binary(plaintext) do
    cond do
      epoch > ST.epoch_max() ->
        {:error, :epoch_exhausted}

      counter >= ST.counter_max() ->
        {:error, :counter_exhausted}

      counter >= ST.rekey_after() ->
        {:error, :rekey_required}

      true ->
        header = encode_header(session_id, epoch, counter)
        nonce = nonce(epoch, counter)

        case Primitives.aead_seal(out_key, nonce, plaintext, header) do
          {:ok, ct, tag} ->
            {:ok, <<header::binary, ct::binary, tag::binary>>}

          {:error, _} = err ->
            err
        end
    end
  end

  @doc """
  Open a wire `frame` against the session. Returns `{:ok, plaintext, session'}` with
  the inbound replay window updated, or `{:error, reason}`.

  Verifies (in order): header parse + pinned constants, session-id match, epoch match
  (stale/foreign epoch rejected), tag length == 16 and nonce length == 12 (structural,
  before `:crypto`), replay window, then AEAD authentication. The replay window is
  only committed after AEAD success.
  """
  @spec open(Session.t(), binary()) ::
          {:ok, binary(), Session.t()} | {:error, atom()}
  def open(%Session{} = session, frame) when is_binary(frame) do
    with {:ok, header, ct, tag} <- split_frame(frame),
         {:ok, parsed} <- parse_header(header),
         :ok <- ensure(Primitives.secure_compare(parsed.session_id, session.session_id), :unknown_session),
         :ok <- ensure(parsed.epoch == session.epoch, :stale_epoch),
         :ok <- ReplayWindow.check(session.replay_window, parsed.counter),
         nonce <- nonce(parsed.epoch, parsed.counter),
         {:ok, plaintext} <- Primitives.aead_open(session.in_key, nonce, ct, header, tag),
         {:ok, window} <- ReplayWindow.check_and_commit(session.replay_window, parsed.counter) do
      {:ok, plaintext, %{session | replay_window: window}}
    end
  end

  @doc """
  Parse and validate a wire header (35 bytes). Useful for transports that need to
  route by `session_id` before they hold the `Session`. Returns
  `{:ok, %{session_id, epoch, counter}}` or `{:error, reason}`.
  """
  @spec parse_header(binary()) :: {:ok, map()} | {:error, atom()}
  def parse_header(<<"SRT1", ver, type, aead, session_id::binary-size(16), epoch::32, counter::64>>) do
    cond do
      ver != ST.protocol_version() -> {:error, :bad_version}
      type != ST.type_data() -> {:error, :bad_type}
      aead != ST.aead_chacha20_poly1305() -> {:error, :bad_aead_id}
      true -> {:ok, %{session_id: session_id, epoch: epoch, counter: counter}}
    end
  end

  def parse_header(_), do: {:error, :bad_header}

  @doc "Encode a 35-byte data-frame header."
  @spec encode_header(binary(), non_neg_integer(), non_neg_integer()) :: binary()
  def encode_header(<<session_id::binary-size(16)>>, epoch, counter)
      when is_integer(epoch) and epoch >= 0 and is_integer(counter) and counter >= 0 do
    <<ST.magic()::binary, ST.protocol_version(), ST.type_data(), ST.aead_chacha20_poly1305(), session_id::binary,
      epoch::32, counter::64>>
  end

  @doc "Reconstruct the 12-byte nonce from epoch (u32) and counter (u64)."
  @spec nonce(non_neg_integer(), non_neg_integer()) :: binary()
  def nonce(epoch, counter)
      when is_integer(epoch) and epoch >= 0 and is_integer(counter) and counter >= 0 do
    <<epoch::32, counter::64>>
  end

  # ---- internal ----

  defp split_frame(frame) do
    header_size = ST.header_size()
    tag_size = ST.tag_size()
    min = header_size + tag_size

    if byte_size(frame) < min do
      {:error, :frame_too_short}
    else
      ct_len = byte_size(frame) - header_size - tag_size

      <<header::binary-size(header_size), ct::binary-size(ct_len), tag::binary-size(tag_size)>> =
        frame

      {:ok, header, ct, tag}
    end
  end

  defp ensure(true, _reason), do: :ok
  defp ensure(false, reason), do: {:error, reason}
end
