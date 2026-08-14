defmodule RacingOrg.Tracker.Pro.SecureTransport.BootstrapState do
  @moduledoc """
  Durable receipt-driven bootstrap and recovery state.

  Exact signed receipts and proof transcripts are retained in `authority`,
  `previous_authority`, and `recovery`. Inspection is deliberately redacted so callers
  cannot accidentally log receipt bytes, nonces, public keys, or hardware identifiers.
  """

  @phases [
    :uninitialized,
    :registered,
    :recovery_candidate,
    :challenged,
    :committed,
    :authenticated,
    :hydrating,
    :effective,
    :blocked,
    :limbo
  ]

  @remote_reasons [
    :recovery_disabled,
    :recovery_ineligible,
    :active_session_conflict,
    :identity_conflict,
    :attempt_limit
  ]

  @local_reasons [
    :hardware_identity_unavailable,
    :hardware_identity_mismatch,
    :identity_unavailable,
    :identity_mismatch,
    :invalid_server_receipt,
    :state_persistence_failed,
    :candidate_promotion_failed,
    :transport_unavailable,
    :legacy_enrollment_required,
    :legacy_binding_required,
    :legacy_marker_invalid,
    :legacy_enrollment_failed,
    :not_configured
  ]
  @allowed_reasons @remote_reasons ++ @local_reasons

  @max_credential_epoch 0xFFFF_FFFF

  @derive {Inspect, only: [:phase, :blocked_reason, :retry_count, :legacy_marker, :verified_credential_epoch]}
  defstruct phase: :uninitialized,
            hardware_identity_digest: nil,
            authority: nil,
            verified_credential_epoch: nil,
            previous_authority: nil,
            recovery: nil,
            blocked_reason: nil,
            retry_count: 0,
            legacy_marker: false,
            legacy_registration: nil

  @type phase ::
          :uninitialized
          | :registered
          | :recovery_candidate
          | :challenged
          | :committed
          | :authenticated
          | :hydrating
          | :effective
          | :blocked
          | :limbo

  @type t :: %__MODULE__{
          phase: phase(),
          hardware_identity_digest: binary() | nil,
          authority: map() | nil,
          verified_credential_epoch: non_neg_integer() | nil,
          previous_authority: map() | nil,
          recovery: map() | nil,
          blocked_reason: atom() | nil,
          retry_count: non_neg_integer(),
          legacy_marker: boolean(),
          legacy_registration: map() | nil
        }

  @doc "All explicit durable lifecycle phases."
  @spec phases() :: [phase()]
  def phases, do: @phases

  @doc "Signed server reasons that may be retried after bounded backoff."
  @spec remote_reasons() :: [atom()]
  def remote_reasons, do: @remote_reasons

  @doc "Closed, sanitized reasons safe to persist and expose diagnostically."
  @spec allowed_reasons() :: [atom()]
  def allowed_reasons, do: @allowed_reasons

  @doc "Return the monotonic credential epoch authorized by the receipt/session high-water mark."
  @spec credential_epoch(t()) :: {:ok, non_neg_integer()} | {:error, :no_verified_authority}
  def credential_epoch(%__MODULE__{authority: %{credential_epoch: authority_epoch}} = state)
      when is_integer(authority_epoch) and authority_epoch >= 0 and authority_epoch <= @max_credential_epoch do
    verified_epoch = Map.get(state, :verified_credential_epoch)

    if is_integer(verified_epoch) and verified_epoch >= authority_epoch and
         verified_epoch <= @max_credential_epoch do
      {:ok, verified_epoch}
    else
      {:ok, authority_epoch}
    end
  end

  def credential_epoch(%__MODULE__{}), do: {:error, :no_verified_authority}

  @doc """
  Operator-facing sanitized projection of the provisioning state: a closed key
  set carrying only phases, epochs, counters, a reason category, and a
  truncated hardware-identity digest. Authority material, recovery challenges,
  and legacy registration payloads never appear in it.
  """
  @spec sanitized_status(t()) :: %{
          phase: phase(),
          credential_epoch: non_neg_integer() | nil,
          retry_count: non_neg_integer(),
          blocked_reason: atom() | nil,
          legacy: boolean(),
          hardware_identity: String.t() | nil,
          recovery_pending: boolean()
        }
  def sanitized_status(%__MODULE__{} = state) do
    %{
      phase: state.phase,
      credential_epoch: status_credential_epoch(state),
      retry_count: state.retry_count,
      blocked_reason: status_blocked_reason(state.blocked_reason),
      legacy: state.legacy_marker,
      hardware_identity: status_hardware_identity(state.hardware_identity_digest),
      recovery_pending: not is_nil(state.recovery)
    }
  end

  defp status_credential_epoch(state) do
    case credential_epoch(state) do
      {:ok, epoch} -> epoch
      {:error, _no_authority} -> nil
    end
  end

  defp status_blocked_reason(nil), do: nil
  defp status_blocked_reason(reason) when is_atom(reason), do: reason

  defp status_blocked_reason(reason)
       when is_tuple(reason) and tuple_size(reason) > 0 and is_atom(elem(reason, 0)),
       do: elem(reason, 0)

  defp status_blocked_reason(_reason), do: :blocked

  defp status_hardware_identity(nil), do: nil

  defp status_hardware_identity(digest) when is_binary(digest) do
    digest |> Base.encode16(case: :lower) |> String.slice(0, 12)
  end

  @doc "Structural validation used at the storage trust boundary."
  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{} = state) do
    state.phase in @phases and
      optional_fixed_binary?(state.hardware_identity_digest, 32) and
      valid_authority?(state.authority) and
      valid_verified_credential_epoch?(state) and
      valid_authority?(state.previous_authority) and
      valid_recovery?(state.recovery) and
      valid_reason?(state.blocked_reason) and
      is_integer(state.retry_count) and state.retry_count >= 0 and
      is_boolean(state.legacy_marker) and
      valid_legacy_registration?(state.legacy_registration)
  end

  def valid?(_state), do: false

  defp valid_verified_credential_epoch?(state) do
    case Map.get(state, :verified_credential_epoch) do
      nil ->
        true

      epoch when is_integer(epoch) and epoch >= 0 and epoch <= @max_credential_epoch ->
        case state.authority do
          %{credential_epoch: authority_epoch} when is_integer(authority_epoch) and epoch >= authority_epoch -> true
          _other -> false
        end

      _other ->
        false
    end
  end

  defp valid_authority?(nil), do: true

  defp valid_authority?(%{kind: :registration} = authority) do
    fixed_binary?(authority[:public_key], 32) and
      fixed_binary?(authority[:client_nonce], 32) and
      is_binary(authority[:receipt]) and
      fixed_binary?(authority[:logical_device_id], 16) and
      authority[:credential_epoch] == 0
  end

  defp valid_authority?(%{kind: :recovery} = authority) do
    fixed_binary?(authority[:public_key], 32) and
      fixed_binary?(authority[:challenge_client_nonce], 32) and
      is_binary(authority[:challenge_receipt]) and
      fixed_binary?(authority[:commit_signing_bytes_hash], 32) and
      is_binary(authority[:lifecycle_receipt]) and
      fixed_binary?(authority[:logical_device_id], 16) and
      is_integer(authority[:credential_epoch]) and authority[:credential_epoch] > 0
  end

  defp valid_authority?(_authority), do: false

  defp valid_recovery?(nil), do: true

  defp valid_recovery?(%{} = recovery) do
    fixed_binary?(recovery[:public_key], 32) and
      recovery[:source] in [:active, :staged] and
      optional_fixed_binary?(recovery[:challenge_client_nonce], 32) and
      optional_binary?(recovery[:challenge_receipt]) and
      is_boolean(Map.get(recovery, :commit_uncertain, false)) and
      optional_binary?(recovery[:classification_receipt])
  end

  defp valid_recovery?(_recovery), do: false

  defp valid_legacy_registration?(nil), do: true

  defp valid_legacy_registration?(%{} = registration) do
    fixed_binary?(registration[:public_key], 32) and
      fixed_binary?(registration[:client_nonce], 32)
  end

  defp valid_legacy_registration?(_registration), do: false

  defp valid_reason?(nil), do: true
  defp valid_reason?(reason), do: reason in allowed_reasons()

  defp fixed_binary?(value, size), do: is_binary(value) and byte_size(value) == size
  defp optional_fixed_binary?(nil, _size), do: true
  defp optional_fixed_binary?(value, size), do: fixed_binary?(value, size)
  defp optional_binary?(nil), do: true
  defp optional_binary?(value), do: is_binary(value)
end
