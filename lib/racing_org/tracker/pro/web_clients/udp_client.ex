defmodule RacingOrg.Tracker.Pro.WebClients.UDPClient do
  @moduledoc """
  Sends DataSet telemetry over UDP as AEAD-only — there is NO plaintext fallback.

  A DataSet is an encoded protobuf binary (`RacingOrg.Tracker.Protobuf.DataSet`). The device
  ONLY ever puts a sealed AEAD frame on the wire:

    * If a **live** SecureTransport session exists
      (`RacingOrg.Tracker.Pro.SecureTransport.SessionHolder.live?/1`), the DataSet binary is
      sealed into a `RacingOrg.SecureTransport.Frame`-compatible AEAD frame
      (device->server key `k_d2s`, header AAD, nonce `epoch||counter`,
      ChaCha20-Poly1305) and THAT frame is what goes on the wire. The frame
      plaintext is EXACTLY the encoded DataSet — i.e. the same bytes the device
      would otherwise carry — which is precisely what the server's
      `RacingOrg.SecureUDPIngest` recovers and feeds to `DataSetIngest`.
      This is SEND-ONLY: the server does not reply with an AEAD frame on UDP
      (secure command delivery is over the P4 channel).

    * If there is **no** live session, the datagram is DROPPED (logged/audited at a
      low level). Telemetry is never sent in the clear; the device re-sends on the
      next sample once a session is live.

  Counter monotonicity and the send boundary are owned by `SessionHolder`:
  `with_send_counter/2,3` atomically reserves a unique `(epoch, counter)` plus a
  bounded send lease, then sealing and transport run in this caller. The actual
  sealing is the stateless `Frame.seal_with/5`, so concurrent sends can never reuse
  a `(key, nonce)` pair and replacement cannot overtake an authorized send. A
  crypto/seal error or stale session never crashes the telemetry pipeline: the one
  datagram is dropped (UDP is lossy and the device re-sends on the next sample).

  Legacy UDP replies on the device-initiated socket remain temporarily supported,
  but `RacingOrg.Tracker.Pro.WebClients.UDPClient.Server` forwards them only while a
  live session at the durable credential epoch is current. Full authenticated
  `control_v1` command framing remains out of scope; secure command delivery normally
  uses the WSS channel.
  """

  require Logger

  alias RacingOrg.Tracker.Pro.SecureTransport.Frame
  alias RacingOrg.Tracker.Pro.SecureTransport.SessionHolder
  alias RacingOrg.Tracker.Pro.WebClients.UDPClient.Server

  def child_spec(arg), do: Server.child_spec(arg)

  @doc """
  Seal + send one encoded DataSet (`proto_binary`) over UDP as an AEAD frame, or
  DROP it when no live session exists. Plaintext is never sent.

  Returns `:ok` (the send is fire-and-forget; UDP is lossy). Options (mainly for
  tests):

    * `:session_holder` — the `SessionHolder` server to consult
      (default `SessionHolder`).
    * `:send_fun` — 1-arity fun invoked with the FINAL (sealed) bytes to put on the
      wire (default `&Server.send/1`), so tests can capture the bytes without a
      socket.
    * `:session_generation` — optional generation captured when work was queued.
      If that generation has been replaced, the datagram is dropped before sealing.
  """
  @spec send_data_set(binary(), keyword()) :: :ok
  def send_data_set(proto_binary, opts \\ []) when is_binary(proto_binary) do
    holder = Keyword.get(opts, :session_holder, SessionHolder)
    send_fun = Keyword.get(opts, :send_fun, &Server.send/1)
    expected_generation = Keyword.get(opts, :session_generation, :current)

    case secure_send(holder, expected_generation, proto_binary, send_fun) do
      :ok -> :ok
      :no_session -> drop_without_session()
      :send_failed -> drop_failed_send()
    end
  end

  # Reserve atomically, then seal and cross the final send boundary in this caller
  # under a holder lease. A counter grant and old key can therefore never be used
  # after another session generation has become current, while holder reads remain
  # responsive to unrelated work.
  defp secure_send(holder, expected_generation, proto_binary, send_fun) do
    send_boundary = fn grant -> send_secure(proto_binary, grant, send_fun) end

    result =
      case expected_generation do
        :current ->
          SessionHolder.with_send_counter(holder, send_boundary)

        generation when is_integer(generation) and generation >= 0 ->
          SessionHolder.with_send_counter(holder, generation, send_boundary)

        _invalid ->
          {:error, :stale_session}
      end

    case result do
      {:ok, :ok} -> :ok
      {:error, :no_session} -> :no_session
      {:error, _reason} -> :send_failed
    end
  catch
    :exit, _ -> :no_session
  end

  defp send_secure(proto_binary, grant, send_fun) do
    case Frame.seal_with(grant.session_id, grant.epoch, grant.counter, grant.out_key, proto_binary) do
      {:ok, frame} ->
        send_fun.(frame)
        :ok

      {:error, reason} ->
        # A seal error (rekey/counter ceiling, AEAD failure) must not crash the
        # pipeline. Drop this datagram; the device re-sends on the next sample. We do
        # NOT silently fall back to plaintext for a sealed-session device.
        Logger.warning("Dropping telemetry datagram; secure seal failed: #{inspect(reason)}")
        :ok
    end
  end

  defp drop_without_session do
    # No live session: drop the datagram. Telemetry is AEAD-only — never leak plaintext.
    Logger.debug("Dropping telemetry datagram; no live secure transport session")
    :ok
  end

  defp drop_failed_send do
    Logger.warning("Dropping telemetry datagram; secure send boundary failed")
    :ok
  end
end
