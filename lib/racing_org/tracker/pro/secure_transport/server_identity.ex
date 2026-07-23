defmodule RacingOrg.Tracker.Pro.SecureTransport.ServerIdentity do
  @moduledoc """
  The PINNED server identity: the SERVER's long-term Ed25519 PUBLIC key (32 bytes)
  that the device uses to authenticate the secure-transport handshake.

  The device is the handshake INITIATOR; there is NO PKI. The server signs its
  HELLO with the server identity PRIVATE key (see the server's
  `RacingOrg.SecureTransport.ServerIdentity`), and the device authenticates the
  server by verifying that signature against THIS firmware-pinned public key. The
  device therefore needs the server's public key — and only its public key — to
  trust the server.

  ## Configuration (runtime)

  The pinned public key is read at runtime from application env:

      config :racing_org_tracker_pro, #{inspect(__MODULE__)},
        public_key: System.get_env("SECURE_TRANSPORT_SERVER_PUBLIC_KEY")

  The value is accepted as either a raw 32-byte binary or a 64-character hex string
  (lower/upper/mixed case) — whichever is ergonomic at provisioning time; the env
  var carries hex. `runtime.exs`/`target.exs` is expected to wire the env var into
  this config key.

  ## Operator responsibility (provisioning / reflash — job-6)

  The OPERATOR sets `SECURE_TRANSPORT_SERVER_PUBLIC_KEY` to the SERVER's REAL
  Ed25519 public key at provisioning/reflash time. It is the device's only
  server-trust anchor. Wiring the value into the firmware/boot config and any
  rotation handling is job-6; this module only reads and validates it.

  ## Unset is fine on host/test

  The claim/handshake jobs that NEED the pinned key are later. When unset (the
  host/test default), `fetch_public_key/0` returns
  `{:error, :server_public_key_not_configured}` and `public_key/0` RAISES with a
  clear, actionable message. Nothing here mints or defaults a key — an unpinned
  server must never be silently trusted.
  """

  @app :racing_org_tracker_pro
  @ed25519_pub_size 32

  @doc """
  Returns the pinned server public key (32 raw bytes), or `{:error, reason}` when
  it is not configured / malformed.

  `reason` is `:server_public_key_not_configured`.
  """
  @spec fetch_public_key() :: {:ok, binary()} | {:error, :server_public_key_not_configured}
  def fetch_public_key do
    case normalize(configured_value()) do
      {:ok, key} -> {:ok, key}
      :error -> {:error, :server_public_key_not_configured}
    end
  end

  @doc """
  Returns the pinned server public key (32 raw bytes), RAISING with a clear message
  when it is not configured.

  Use this from consumers that genuinely require the pin (the handshake). Prefer
  `fetch_public_key/0` where an unset value should be handled gracefully.
  """
  @spec public_key() :: binary()
  def public_key do
    case fetch_public_key() do
      {:ok, key} ->
        key

      {:error, :server_public_key_not_configured} ->
        raise """
        The pinned secure-transport SERVER public key is not configured.

        The device authenticates the server's handshake HELLO against this
        firmware-pinned Ed25519 public key. Set it to the SERVER's real public key
        at provisioning/reflash time (job-6):

            config :racing_org_tracker_pro, #{inspect(__MODULE__)},
              public_key: System.get_env("SECURE_TRANSPORT_SERVER_PUBLIC_KEY")

        The value is 32 bytes, supplied as raw bytes or a 64-char hex string.
        """
    end
  end

  @doc "Whether a valid pinned server public key is currently configured."
  @spec configured?() :: boolean()
  def configured? do
    match?({:ok, _}, fetch_public_key())
  end

  defp configured_value do
    @app
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:public_key)
  end

  # Accept a raw 32-byte binary or a 64-char hex string (either case).
  defp normalize(<<_::binary-size(@ed25519_pub_size)>> = key), do: {:ok, key}

  defp normalize(hex) when is_binary(hex) and byte_size(hex) == @ed25519_pub_size * 2 do
    case Base.decode16(hex, case: :mixed) do
      {:ok, <<_::binary-size(@ed25519_pub_size)>> = key} -> {:ok, key}
      _ -> :error
    end
  end

  defp normalize(_), do: :error
end
