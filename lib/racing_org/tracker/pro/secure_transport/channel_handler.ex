defmodule RacingOrg.Tracker.Pro.SecureTransport.ChannelHandler do
  @moduledoc """
  PURE protocol logic for the secure-transport command channel, extracted from the
  Slipstream transport (`RacingOrg.Tracker.Pro.SecureTransport.ChannelClient`) so it can be
  unit-tested without a live socket or server.

  Three concerns, all side-effect-light and deterministic given their inputs:

    * `handshake_init/2` — given the server `"handshake_hello"` payload + the
      device's crypto inputs, run `Handshake.initiator_init/2` and produce the
      `"handshake_init"` payload to push plus the derived `Session`.
    * `handle_command/3` — given a server `"command"` payload, decode the
      `ServerReply` protobuf, apply it through `RacingOrg.Tracker.Pro.Commands` (the SAME
      command-application path as the UDP transport), and build the `"ack"` payload
      the server expects.
    * `verify_handshake_ok/2` — sanity-check the server's `"handshake_ok"`
      `session_id` matches the locally derived session.

  ## device_id binding (contract note)

  The server's `responder_finalize/2` does NOT validate the INIT's `device_id`
  field — it only binds the bytes the device sends into the handshake transcript
  (so both sides derive matching keys). The device sends its FINGERPRINT (the
  lowercase-hex `SHA-256(public_key)` routing id) as `device_id`: it is the same
  identifier the device already presents at socket connect + uses as the channel
  topic, it is deterministic, and it requires no server round-trip. Any stable
  value would interoperate (the server mirrors it), but the fingerprint is the
  natural, self-consistent choice.
  """

  require Logger

  alias RacingOrg.Tracker.Pro.Commands
  alias RacingOrg.Tracker.Pro.SecureTransport.Handshake
  alias RacingOrg.Tracker.Pro.SecureTransport.IdentityProvider
  alias RacingOrg.Tracker.Pro.SecureTransport.Session

  @ack_format_version 1

  @typedoc "Everything the handshake needs from the device's key material."
  @type handshake_inputs ::
          %{
            required(:device_identity) => IdentityProvider.t(),
            required(:server_identity_public) => binary(),
            required(:device_id) => binary(),
            optional(:epoch) => non_neg_integer(),
            optional(:credential_epoch) => non_neg_integer()
          }
          | %{
              required(:device_identity_private) => binary(),
              required(:device_identity_public) => binary(),
              required(:server_identity_public) => binary(),
              required(:device_id) => binary(),
              optional(:epoch) => non_neg_integer(),
              optional(:credential_epoch) => non_neg_integer()
            }

  @doc "The ack-format version the device emits (matches the server's `@ack_format_version`)."
  @spec ack_format_version() :: pos_integer()
  def ack_format_version, do: @ack_format_version

  # --- Handshake ---

  @doc """
  Consume the server `"handshake_hello"` payload and produce the device INIT.

  `hello_payload` is the raw channel payload map, e.g. `%{"hello" => base64}`.
  `inputs` is a `t:handshake_inputs/0`. When `:epoch` is omitted, the signed
  HELLO epoch is adopted; `:credential_epoch`, when present, is the downgrade floor.

  Returns `{:ok, init_payload, session}` where `init_payload` is the
  `%{"init" => base64}` map to push, or `{:error, reason}` (bad base64, missing
  field, or any `Handshake.initiator_init/2` failure such as
  `:server_fp_mismatch` / `:bad_server_signature`).
  """
  @spec handshake_init(map(), handshake_inputs()) ::
          {:ok, map(), Session.t()} | {:error, atom()}
  def handshake_init(hello_payload, inputs) do
    with {:ok, hello_b64} <- fetch_field(hello_payload, "hello"),
         {:ok, hello_wire} <- decode_b64(hello_b64),
         {:ok, init_wire, session} <- initiator_init(hello_wire, inputs) do
      {:ok, %{"init" => Base.encode64(init_wire)}, session}
    end
  end

  @doc """
  Verify the server `"handshake_ok"` payload's `session_id` matches the locally
  derived `session`. Returns `:ok` or `{:error, :session_id_mismatch}` /
  `{:error, :bad_session_id}`.
  """
  @spec verify_handshake_ok(map(), Session.t()) ::
          :ok | {:error, :session_id_mismatch | :bad_session_id}
  def verify_handshake_ok(payload, %Session{session_id: expected}) do
    case fetch_field(payload, "session_id") do
      {:ok, b64} ->
        case decode_b64(b64) do
          {:ok, ^expected} -> :ok
          {:ok, _other} -> {:error, :session_id_mismatch}
          {:error, _} -> {:error, :bad_session_id}
        end

      {:error, _} ->
        {:error, :bad_session_id}
    end
  end

  defp initiator_init(hello_wire, inputs) do
    opts = [
      server_identity_public: inputs.server_identity_public,
      device_id: inputs.device_id,
      timestamp_ms: System.system_time(:millisecond)
    ]

    opts = maybe_put_opt(opts, inputs, :epoch)
    opts = maybe_put_opt(opts, inputs, :credential_epoch)

    identity_opts =
      case Map.get(inputs, :device_identity) do
        %IdentityProvider{} = identity ->
          [device_identity: identity]

        nil ->
          [
            device_identity_private: inputs.device_identity_private,
            device_identity_public: inputs.device_identity_public
          ]
      end

    Handshake.initiator_init(hello_wire, identity_opts ++ opts)
  end

  # --- Commands ---

  @doc """
  Handle a server `"command"` payload by decoding the `ServerReply` protobuf and
  applying it through `RacingOrg.Tracker.Pro.Commands` (the shared, idempotent command path).

  `command_server` is the `RacingOrg.Tracker.Pro.Commands` GenServer name/pid (defaults to
  `RacingOrg.Tracker.Pro.Commands`).

  Returns:

    * `{:ack, ack_payload}` — the command applied (or was a harmless duplicate);
      `ack_payload` is `%{v: 1, acks: [%{command_id: .., assignment_version: ..}]}`
      ready to push as the `"ack"` event. Built from the device's current ACK so
      the acked `command_id` + `assignment_version` exactly match what the server's
      `normalize_acks/1` expects.
    * `{:noack, reason}` — nothing to ack (malformed payload, decode failure, or
      the command was ignored: expired / stale / not-for-this-device). The frame is
      simply not acked; the server's sweeper handles genuine expiry.

  Idempotent: a re-pushed/duplicate command does not double-apply (the Commands
  GenServer de-dupes by `command_id`) and STILL produces a correct ack so the
  server can clear it.
  """
  @spec handle_command(map(), pos_integer() | binary(), GenServer.server()) ::
          {:ack, map()} | {:noack, atom()}
  def handle_command(payload, command_id, command_server \\ Commands) do
    with {:ok, reply_b64} <- fetch_field(payload, "reply"),
         {:ok, reply_wire} <- decode_b64(reply_b64),
         {:ok, %struct{} = reply} when struct == RacingOrg.Tracker.Protobuf.ServerReply <-
           Commands.decode(reply_wire) do
      apply_and_ack(command_server, reply, command_id)
    else
      {:error, :missing_field} -> {:noack, :missing_field}
      {:error, :bad_base64} -> {:noack, :bad_base64}
      {:error, _decode_error} -> {:noack, :malformed}
      _ -> {:noack, :malformed}
    end
  end

  defp apply_and_ack(command_server, reply, command_id) do
    case Commands.apply_reply(command_server, reply) do
      :applied ->
        {:ack, build_ack_payload(command_server, command_id)}

      # A duplicate is a successful, idempotent no-op: still ack it so the server
      # can clear the command (re-push won't burn a retry server-side anyway).
      {:ignored, :duplicate} ->
        {:ack, build_ack_payload(command_server, command_id)}

      {:ignored, reason} ->
        Logger.debug("channel command #{inspect(command_id)} not applied: #{reason}")
        {:noack, reason}
    end
  end

  # Build the ack from the device's current applied ACK (a CommandAck protobuf).
  # The server's normalize_acks/1 wants %{"command_id" => .., "assignment_version"
  # => ..}; it accepts atom keys here too (Phoenix serializes them to JSON). We use
  # the command_id from the just-applied command (the one the server pushed) and
  # the assignment_version the device now holds.
  defp build_ack_payload(command_server, command_id) do
    ack = Commands.current_ack(command_server)
    assignment_version = if ack, do: ack.assignment_version, else: 0

    %{
      v: @ack_format_version,
      acks: [
        %{
          command_id: to_string(command_id),
          assignment_version: assignment_version
        }
      ]
    }
  end

  # --- shared helpers ---

  defp maybe_put_opt(opts, inputs, key) do
    case Map.fetch(inputs, key) do
      {:ok, value} -> Keyword.put(opts, key, value)
      :error -> opts
    end
  end

  defp fetch_field(payload, key) when is_map(payload) do
    case payload do
      %{^key => value} when is_binary(value) -> {:ok, value}
      _ -> {:error, :missing_field}
    end
  end

  defp fetch_field(_payload, _key), do: {:error, :missing_field}

  defp decode_b64(b64) do
    case Base.decode64(b64) do
      {:ok, bin} -> {:ok, bin}
      :error -> {:error, :bad_base64}
    end
  end
end
