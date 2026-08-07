defmodule RacingOrg.Tracker.Pro.SecureTransport.BootstrapStateMachine do
  @moduledoc """
  Receipt-driven bootstrap and serial-recovery application state machine.

  Reconciliation validates the current SoC serial, every persisted signed receipt and
  transcript, and the active/staged signer before taking an action. A missing, corrupt,
  or mismatched active signer stages one reusable candidate without overwriting the old
  key or authority receipt. Recovery persists the exact committed bundle before candidate
  promotion. Lost commit responses are resolved through candidate-PoP status.

  This module is synchronous and side-effect bounded so `BootProvisioner` can supervise
  retries while future channel/application phases call the explicit authenticated,
  hydrating, effective, and legacy-enrollment callbacks.
  """

  alias RacingOrg.Tracker.Pro.HardwareIdentity.RaspberryPiSoCSerial
  alias RacingOrg.Tracker.Pro.SecureTransport.BootstrapClient
  alias RacingOrg.Tracker.Pro.SecureTransport.BootstrapState
  alias RacingOrg.Tracker.Pro.SecureTransport.BootstrapStateStore
  alias RacingOrg.Tracker.Pro.SecureTransport.IdentityProvider
  alias RacingOrg.Tracker.Pro.SecureTransport.KeyStore
  alias RacingOrg.Tracker.Pro.SecureTransport.Primitives
  alias RacingOrg.Tracker.Pro.SecureTransport.RecoveryClient
  alias RacingOrg.Tracker.Pro.SecureTransport.ServerIdentity
  alias RacingOrg.Tracker.Pro.SecureTransport.TrackerContractV2, as: Contract

  @hardware_digest_domain "RacingOrg-TrackerHardwareIdentity-v1"
  @max_internal_steps 12
  @retryable_blocked_reasons BootstrapState.remote_reasons()

  @type outcome ::
          {:ok, BootstrapState.t()}
          | {:retry, atom(), BootstrapState.t()}
          | {:blocked, atom(), BootstrapState.t()}
          | {:error, atom()}

  @doc "Reconcile durable state, current hardware identity, signers, and server receipts."
  @spec reconcile(keyword()) :: outcome()
  def reconcile(opts \\ []) do
    with {:ok, server_public_key} <- server_public_key(opts),
         {:ok, state} <- BootstrapStateStore.load(state_store_opts(opts)) do
      case hardware_identity(opts) do
        {:ok, provider, serial} ->
          resolved_opts =
            opts
            |> Keyword.put(:resolved_server_public_key, server_public_key)
            |> Keyword.put(:resolved_hardware_provider, provider)

          reconcile_state(state, provider, serial, resolved_opts, 0)

        {:error, _reason} ->
          defer_retry(state, :hardware_identity_unavailable, opts)
      end
    else
      {:error, :server_public_key_not_configured} -> {:error, :not_configured}
      {:error, :not_configured} -> {:error, :not_configured}
      {:error, _reason} -> {:error, :state_persistence_failed}
    end
  end

  @doc "Domain-separated digest used to compare the current hardware identity to durable state."
  @spec hardware_identity_digest(binary(), binary()) :: binary()
  def hardware_identity_digest(provider, serial) when is_binary(provider) and is_binary(serial) do
    Primitives.sha256(@hardware_digest_domain <> lp(provider) <> lp(serial))
  end

  @doc "Return whether the current active key has verified authority to authenticate."
  @spec authorized?(keyword()) :: boolean()
  def authorized?(opts \\ []) do
    case BootstrapStateStore.load(state_store_opts(opts)) do
      {:ok, %BootstrapState{phase: :uninitialized}} ->
        valid_legacy_identity?(opts)

      {:ok, %BootstrapState{phase: :limbo, blocked_reason: :legacy_enrollment_required}} ->
        valid_legacy_identity?(opts)

      {:ok, %BootstrapState{} = state}
      when state.phase in [:registered, :committed, :authenticated, :hydrating, :effective] ->
        with {:ok, server_public_key} <- server_public_key(opts),
             {:ok, provider, serial} <- hardware_identity(opts) do
          resolved_opts = Keyword.put(opts, :resolved_server_public_key, server_public_key)

          hardware_digest_matches?(state, provider, serial) and
            match?({:ok, _}, verify_authority(state.authority, serial, resolved_opts)) and
            active_matches_authority?(state.authority, opts)
        else
          _ -> false
        end

      _other ->
        false
    end
  end

  @doc "Persist a signed-HELLO credential epoch as a monotonic downgrade fence."
  @spec adopt_credential_epoch(non_neg_integer(), keyword()) ::
          {:ok, BootstrapState.t()} | {:error, atom()}
  def adopt_credential_epoch(epoch, opts \\ [])

  def adopt_credential_epoch(epoch, opts)
      when is_integer(epoch) and epoch >= 0 and epoch <= 0xFFFF_FFFF do
    with {:ok, %BootstrapState{} = state} <- BootstrapStateStore.load(state_store_opts(opts)),
         {:ok, current_epoch} <- BootstrapState.credential_epoch(state),
         :ok <- ensure(epoch >= current_epoch, :epoch_downgrade),
         next = %{state | verified_credential_epoch: epoch},
         :ok <- persist_if_changed(state, next, opts) do
      {:ok, next}
    else
      {:error, :no_verified_authority} -> {:error, :no_verified_authority}
      {:error, :epoch_downgrade} -> {:error, :epoch_downgrade}
      {:error, _reason} -> {:error, :state_persistence_failed}
    end
  end

  def adopt_credential_epoch(_epoch, _opts), do: {:error, :epoch_exhausted}

  @doc "Persist the post-handshake authenticated phase."
  @spec mark_authenticated(keyword()) :: {:ok, BootstrapState.t()} | {:error, atom()}
  def mark_authenticated(opts \\ []), do: transition([:registered, :committed], :authenticated, opts)

  @doc "Persist the desired-state hydration phase."
  @spec mark_hydrating(keyword()) :: {:ok, BootstrapState.t()} | {:error, atom()}
  def mark_hydrating(opts \\ []), do: transition([:authenticated], :hydrating, opts)

  @doc "Persist the whole-generation effective phase."
  @spec mark_effective(keyword()) :: {:ok, BootstrapState.t()} | {:error, atom()}
  def mark_effective(opts \\ []), do: transition([:hydrating], :effective, opts)

  @doc "Clear live-session readiness while retaining the verified durable authority."
  @spec mark_session_lost(keyword()) :: {:ok, BootstrapState.t()} | {:error, atom()}
  def mark_session_lost(opts \\ []) do
    with {:ok, %BootstrapState{} = state} <- BootstrapStateStore.load(state_store_opts(opts)) do
      mark_session_lost(state, opts)
    else
      {:error, _reason} -> {:error, :state_persistence_failed}
    end
  end

  @doc false
  @spec mark_session_lost(BootstrapState.t(), keyword()) ::
          {:ok, BootstrapState.t()} | {:error, atom()}
  def mark_session_lost(%BootstrapState{} = state, opts) do
    with {:ok, next} <- session_lost_state(state),
         :ok <- persist_if_changed(state, next, opts) do
      {:ok, next}
    else
      {:error, :invalid_transition} -> {:error, :invalid_transition}
      {:error, _reason} -> {:error, :state_persistence_failed}
    end
  end

  @doc "Build and persist the registration proof for an authenticated legacy enrollment hook."
  @spec legacy_enrollment_request(keyword()) :: {:ok, map()} | {:error, atom() | term()}
  def legacy_enrollment_request(opts \\ []) do
    with {:ok, _server_public_key} <- server_public_key(opts),
         {:ok, _provider, serial} <- hardware_identity(opts),
         {:ok, %BootstrapState{} = state} <- BootstrapStateStore.load(state_store_opts(opts)),
         :ok <- ensure_legacy_enrollment_state(state),
         {:ok, identity} <- KeyStore.load(keystore_opts(opts)),
         {:ok, request, next} <- prepare_legacy_enrollment(state, identity, serial, opts),
         :ok <- persist_if_changed(state, next, opts) do
      {:ok, request}
    else
      {:error, :server_public_key_not_configured} -> {:error, :not_configured}
      {:error, reason} -> {:error, sanitize_callback_error(reason)}
    end
  end

  @doc "Verify and adopt the signed receipt returned by an authenticated legacy enrollment hook."
  @spec accept_legacy_enrollment(term(), keyword()) ::
          {:ok, BootstrapState.t()} | {:error, atom() | term()}
  def accept_legacy_enrollment(response, opts \\ []) do
    with {:ok, server_public_key} <- server_public_key(opts),
         {:ok, provider, serial} <- hardware_identity(opts),
         {:ok, %BootstrapState{} = state} <- BootstrapStateStore.load(state_store_opts(opts)),
         :ok <- ensure_legacy_enrollment_state(state),
         %{public_key: public_key, client_nonce: nonce} <- state.legacy_registration,
         {:ok, identity} <- KeyStore.load(keystore_opts(opts)),
         :ok <- secure_match(IdentityProvider.public_key(identity), public_key, :identity_mismatch),
         {:ok, request} <- BootstrapClient.prepare_registration(identity, serial, client_nonce: nonce),
         {:ok, receipt} <-
           BootstrapClient.verify_registration_response(
             request,
             response,
             server_public_key: server_public_key
           ),
         :ok <- ensure(receipt.payload.outcome == :registered, :invalid_server_receipt),
         authority = registration_authority(request, receipt),
         next = %{
           state
           | phase: :registered,
             hardware_identity_digest: hardware_identity_digest(provider, serial),
             authority: authority,
             previous_authority: nil,
             recovery: nil,
             blocked_reason: nil,
             retry_count: 0,
             legacy_marker: false,
             legacy_registration: nil
         },
         :ok <- BootstrapStateStore.save(next, state_store_opts(opts)),
         :ok <- BootstrapStateStore.remove_legacy_marker(state_store_opts(opts)) do
      {:ok, next}
    else
      {:error, :server_public_key_not_configured} -> {:error, :not_configured}
      {:error, reason} -> {:error, sanitize_callback_error(reason)}
      _ -> {:error, :legacy_enrollment_failed}
    end
  end

  defp reconcile_state(state, _provider, _serial, opts, steps) when steps >= @max_internal_steps do
    defer_retry(state, :transport_unavailable, opts)
  end

  defp reconcile_state(state, provider, serial, opts, steps) do
    digest = hardware_identity_digest(provider, serial)

    cond do
      state.phase != :uninitialized and
        is_binary(state.hardware_identity_digest) and
          not secure_equal?(state.hardware_identity_digest, digest) ->
        persist_blocked(state, :limbo, :hardware_identity_mismatch, opts)

      state.phase == :uninitialized ->
        initialize(state, digest, serial, opts, steps)

      state.phase in [:registered, :authenticated, :hydrating, :effective] ->
        reconcile_authorized_phase(state, digest, serial, opts, steps)

      state.phase == :committed ->
        reconcile_committed(state, digest, serial, opts, steps)

      state.phase == :recovery_candidate ->
        drive_recovery_candidate(state, digest, serial, opts, steps)

      state.phase == :challenged ->
        drive_challenged(state, digest, serial, opts, steps)

      state.phase == :blocked and state.blocked_reason in @retryable_blocked_reasons ->
        retry_blocked_recovery(state, digest, serial, opts, steps)

      state.phase == :limbo and state.blocked_reason == :legacy_binding_required ->
        retry_blocked_recovery(state, digest, serial, opts, steps)

      state.phase in [:blocked, :limbo] ->
        {:blocked, state.blocked_reason || :identity_unavailable, state}

      true ->
        persist_blocked(state, :limbo, :invalid_server_receipt, opts)
    end
  end

  defp initialize(state, digest, serial, opts, steps) do
    case read_legacy_marker(opts) do
      :absent ->
        begin_recovery(state, digest, serial, false, opts, steps)

      {:ok, marker} ->
        case KeyStore.load(keystore_opts(opts)) do
          {:ok, identity} ->
            if legacy_marker_matches?(marker, identity) do
              next = %{
                state
                | phase: :limbo,
                  hardware_identity_digest: digest,
                  blocked_reason: :legacy_enrollment_required,
                  legacy_marker: true,
                  retry_count: 0
              }

              persist_blocked_state(next, opts)
            else
              begin_recovery(%{state | legacy_marker: true}, digest, serial, true, opts, steps)
            end

          {:error, _reason} ->
            begin_recovery(%{state | legacy_marker: true}, digest, serial, true, opts, steps)
        end

      {:error, :invalid_marker} ->
        persist_blocked(
          %{state | hardware_identity_digest: digest, legacy_marker: true},
          :limbo,
          :legacy_marker_invalid,
          opts
        )
    end
  end

  defp reconcile_authorized_phase(state, digest, serial, opts, steps) do
    with {:ok, authority} <- verify_authority(state.authority, serial, opts) do
      state = %{state | authority: authority, hardware_identity_digest: digest}

      cond do
        active_matches_authority?(authority, opts) and is_map(state.recovery) ->
          finalize_promoted_state(state, opts)

        active_matches_authority?(authority, opts) ->
          {:ok, %{state | retry_count: 0, blocked_reason: nil}}

        state.phase == :registered and match?(%{source: :staged}, state.recovery) and
            staged_matches_public_key?(authority.public_key, opts) ->
          promote_candidate(state, opts)

        true ->
          begin_recovery(state, digest, serial, state.legacy_marker, opts, steps)
      end
    else
      {:error, _reason} -> persist_blocked(state, :limbo, :invalid_server_receipt, opts)
    end
  end

  defp reconcile_committed(state, digest, serial, opts, steps) do
    with {:ok, authority} <- verify_authority(state.authority, serial, opts) do
      state = %{state | authority: authority, hardware_identity_digest: digest}

      cond do
        active_matches_authority?(authority, opts) ->
          finalize_promoted_state(state, opts)

        staged_matches_public_key?(authority.public_key, opts) ->
          promote_candidate(state, opts)

        true ->
          begin_recovery(state, digest, serial, state.legacy_marker, opts, steps)
      end
    else
      {:error, _reason} -> persist_blocked(state, :limbo, :invalid_server_receipt, opts)
    end
  end

  defp begin_recovery(state, digest, serial, legacy_marker?, opts, steps) do
    with {:ok, identity, source} <- choose_candidate(state, legacy_marker?, opts) do
      public_key = IdentityProvider.public_key(identity)

      next = %{
        state
        | phase: :recovery_candidate,
          hardware_identity_digest: digest,
          recovery: %{
            public_key: public_key,
            source: source,
            challenge_client_nonce: nil,
            challenge_receipt: nil,
            classification_receipt: nil,
            commit_uncertain: false
          },
          blocked_reason: nil,
          legacy_marker: legacy_marker?
      }

      save_and_continue(next, serial, opts, steps)
    else
      {:error, _reason} -> defer_retry(state, :identity_unavailable, opts)
    end
  end

  defp choose_candidate(state, legacy_marker?, opts) do
    case existing_recovery_identity(state, opts) do
      {:ok, identity, source} ->
        {:ok, identity, source}

      :none ->
        choose_new_candidate(state, legacy_marker?, opts)
    end
  end

  defp choose_new_candidate(%BootstrapState{authority: nil}, false, opts) do
    case KeyStore.load(keystore_opts(opts)) do
      {:ok, identity} -> {:ok, identity, :active}
      {:error, _reason} -> stage_candidate(opts)
    end
  end

  defp choose_new_candidate(_state, _legacy_marker?, opts), do: stage_candidate(opts)

  defp stage_candidate(opts) do
    case KeyStore.stage_candidate(keystore_opts(opts)) do
      {:ok, identity} -> {:ok, identity, :staged}
      {:error, reason} -> {:error, reason}
    end
  end

  defp existing_recovery_identity(%BootstrapState{recovery: %{public_key: public_key, source: source}}, opts) do
    loader = if source == :active, do: &KeyStore.load/1, else: &KeyStore.load_candidate/1

    case loader.(keystore_opts(opts)) do
      {:ok, identity} ->
        if secure_equal?(IdentityProvider.public_key(identity), public_key) do
          {:ok, identity, source}
        else
          :none
        end

      {:error, _reason} ->
        :none
    end
  end

  defp existing_recovery_identity(_state, _opts), do: :none

  defp drive_recovery_candidate(state, digest, serial, opts, steps) do
    with {:ok, identity} <- recovery_identity(state, opts),
         {:ok, result} <- call_challenge(identity, serial, opts),
         {:ok, result} <- RecoveryClient.validate_challenge_result(identity, serial, result, receipt_opts(opts)) do
      handle_challenge_classification(state, digest, serial, identity, result, opts, steps)
    else
      {:error, reason} -> handle_client_error(state, reason, opts)
    end
  end

  defp handle_challenge_classification(state, digest, serial, identity, result, opts, steps) do
    receipt = result.receipt

    case receipt.payload.classification do
      :recoverable ->
        next = %{
          state
          | phase: :challenged,
            hardware_identity_digest: digest,
            recovery:
              Map.merge(state.recovery, %{
                challenge_client_nonce: result.request.client_nonce,
                challenge_receipt: receipt.envelope,
                classification_receipt: nil,
                commit_uncertain: false
              }),
            blocked_reason: nil
        }

        save_and_continue(next, serial, opts, steps)

      :not_enrolled ->
        if state.legacy_marker do
          next = %{
            state
            | recovery:
                Map.merge(state.recovery, %{
                  challenge_client_nonce: result.request.client_nonce,
                  classification_receipt: receipt.envelope
                })
          }

          persist_blocked(next, :limbo, :legacy_binding_required, opts)
        else
          register_candidate(state, digest, serial, identity, result, opts, steps)
        end

      :blocked ->
        next = %{
          state
          | recovery:
              Map.merge(state.recovery, %{
                challenge_client_nonce: result.request.client_nonce,
                classification_receipt: receipt.envelope
              })
        }

        persist_blocked(next, :blocked, receipt.payload.reason, opts)
    end
  end

  defp register_candidate(state, digest, serial, identity, challenge_result, opts, steps) do
    with {:ok, result} <- call_register(identity, serial, opts),
         {:ok, result} <- BootstrapClient.validate_result(identity, serial, result, receipt_opts(opts)) do
      case result.receipt.payload.outcome do
        :registered ->
          authority = registration_authority(result.request, result.receipt)

          next = %{
            state
            | phase: :registered,
              hardware_identity_digest: digest,
              authority: authority,
              previous_authority: nil,
              recovery: Map.put(state.recovery, :classification_receipt, challenge_result.receipt.envelope),
              blocked_reason: nil,
              retry_count: 0
          }

          persist_then_activate_registration(next, opts)

        :recovery_required ->
          next = %{
            state
            | phase: :recovery_candidate,
              recovery:
                Map.merge(state.recovery, %{
                  challenge_client_nonce: nil,
                  challenge_receipt: nil,
                  classification_receipt: result.receipt.envelope,
                  commit_uncertain: false
                }),
              blocked_reason: nil
          }

          case BootstrapStateStore.save(next, state_store_opts(opts)) do
            :ok -> reconcile_state(next, resolved_hardware_provider(opts), serial, opts, steps + 1)
            {:error, _reason} -> {:retry, :state_persistence_failed, bump_retry(next, :state_persistence_failed)}
          end

        :blocked ->
          persist_blocked(state, :blocked, result.receipt.payload.reason, opts)
      end
    else
      {:error, :registration_conflict} ->
        defer_retry(state, :transport_unavailable, opts)

      {:error, reason} ->
        handle_client_error(state, reason, opts)
    end
  end

  defp persist_then_activate_registration(state, opts) do
    case BootstrapStateStore.save(state, state_store_opts(opts)) do
      :ok ->
        activate_persisted_candidate(state, opts)

      {:error, _reason} ->
        {:retry, :state_persistence_failed, bump_retry(state, :state_persistence_failed)}
    end
  end

  defp activate_persisted_candidate(state, opts) do
    case state.recovery.source do
      :active -> finalize_promoted_state(state, opts)
      :staged -> promote_candidate(state, opts)
    end
  end

  defp promote_candidate(state, opts) do
    case KeyStore.promote_candidate(keystore_opts(opts)) do
      {:ok, _identity} -> finalize_promoted_state(state, opts)
      {:error, _reason} -> {:retry, :candidate_promotion_failed, bump_retry(state, :candidate_promotion_failed)}
    end
  end

  defp drive_challenged(state, _digest, serial, opts, steps) do
    with {:ok, identity} <- recovery_identity(state, opts),
         {:ok, challenge_receipt} <- verify_recovery_challenge(state, serial, opts) do
      if state.recovery.commit_uncertain do
        query_recovery_status(state, serial, identity, challenge_receipt, opts, steps)
      else
        commit_recovery(state, serial, identity, challenge_receipt, opts, steps)
      end
    else
      {:error, reason} -> handle_client_error(state, reason, opts)
    end
  end

  defp commit_recovery(state, serial, identity, challenge_receipt, opts, steps) do
    case call_commit(identity, challenge_receipt, opts) do
      {:ok, result} ->
        case RecoveryClient.validate_lifecycle_result(
               identity,
               challenge_receipt,
               result,
               receipt_opts(opts)
             ) do
          {:ok, verified} ->
            handle_lifecycle(state, serial, identity, challenge_receipt, verified, opts, steps)

          {:error, _reason} ->
            persist_blocked(state, :limbo, :invalid_server_receipt, opts)
        end

      {:error, _reason} ->
        uncertain = %{
          state
          | recovery: Map.put(state.recovery, :commit_uncertain, true)
        }

        defer_retry(uncertain, :transport_unavailable, opts)
    end
  end

  defp query_recovery_status(state, serial, identity, challenge_receipt, opts, steps) do
    case call_status(identity, challenge_receipt, opts) do
      {:ok, result} ->
        case RecoveryClient.validate_lifecycle_result(
               identity,
               challenge_receipt,
               result,
               receipt_opts(opts)
             ) do
          {:ok, verified} ->
            handle_lifecycle(state, serial, identity, challenge_receipt, verified, opts, steps)

          {:error, _reason} ->
            persist_blocked(state, :limbo, :invalid_server_receipt, opts)
        end

      {:error, _reason} ->
        defer_retry(state, :transport_unavailable, opts)
    end
  end

  defp handle_lifecycle(state, serial, identity, challenge_receipt, result, opts, steps) do
    case result.receipt.payload.lifecycle do
      :committed ->
        persist_committed(state, identity, challenge_receipt, result, opts)

      :pending ->
        next = %{state | recovery: Map.put(state.recovery, :commit_uncertain, false)}
        defer_retry(next, :transport_unavailable, opts)

      :expired ->
        next = %{
          state
          | phase: :recovery_candidate,
            recovery:
              Map.merge(state.recovery, %{
                challenge_client_nonce: nil,
                challenge_receipt: nil,
                commit_uncertain: false
              })
        }

        save_and_continue(next, serial, opts, steps)

      :blocked ->
        persist_blocked(state, :blocked, result.receipt.payload.reason, opts)
    end
  end

  defp persist_committed(%BootstrapState{} = state, identity, challenge_receipt, result, opts) do
    public_key = IdentityProvider.public_key(identity)

    with :ok <- validate_logical_device_binding(state, result.receipt.payload.logical_device_id),
         :ok <- validate_credential_epoch_advance(state, result.receipt.payload.credential_epoch),
         {:ok, commit_assertion} <-
           Contract.recovery_commit_assertion(
             challenge_receipt.payload.attempt_id,
             public_key,
             challenge_receipt.envelope_hash
           ) do
      authority = %{
        kind: :recovery,
        public_key: public_key,
        challenge_client_nonce: state.recovery.challenge_client_nonce,
        challenge_receipt: challenge_receipt.envelope,
        commit_signing_bytes_hash: Primitives.sha256(commit_assertion),
        lifecycle_receipt: result.receipt.envelope,
        logical_device_id: result.receipt.payload.logical_device_id,
        credential_epoch: result.receipt.payload.credential_epoch
      }

      next = %BootstrapState{
        state
        | phase: :committed,
          authority: authority,
          verified_credential_epoch: authority.credential_epoch,
          previous_authority: state.authority || state.previous_authority,
          blocked_reason: nil,
          retry_count: 0
      }

      case BootstrapStateStore.save(next, state_store_opts(opts)) do
        :ok ->
          activate_persisted_candidate(next, opts)

        {:error, _reason} ->
          {:retry, :state_persistence_failed, bump_retry(next, :state_persistence_failed)}
      end
    else
      {:error, _reason} -> persist_blocked(state, :limbo, :invalid_server_receipt, opts)
    end
  end

  defp validate_credential_epoch_advance(%BootstrapState{} = state, credential_epoch) do
    current_epoch =
      case BootstrapState.credential_epoch(state) do
        {:ok, epoch} -> epoch
        {:error, :no_verified_authority} -> -1
      end

    if is_integer(credential_epoch) and credential_epoch >= 0 and
         credential_epoch <= 0xFFFF_FFFF and credential_epoch >= current_epoch do
      :ok
    else
      {:error, :credential_epoch_downgrade}
    end
  end

  defp validate_logical_device_binding(%BootstrapState{} = state, logical_device_id) do
    case state.authority || state.previous_authority do
      %{logical_device_id: expected} -> secure_match(logical_device_id, expected, :logical_device_mismatch)
      nil -> :ok
    end
  end

  defp finalize_promoted_state(state, opts) do
    next = %{state | recovery: nil, blocked_reason: nil, retry_count: 0}

    case BootstrapStateStore.save(next, state_store_opts(opts)) do
      :ok -> {:ok, next}
      {:error, _reason} -> {:retry, :state_persistence_failed, bump_retry(state, :state_persistence_failed)}
    end
  end

  defp retry_blocked_recovery(state, _digest, serial, opts, steps) do
    next = %{state | phase: :recovery_candidate, blocked_reason: nil}

    save_and_continue(next, serial, opts, steps)
  end

  defp save_and_continue(next, serial, opts, steps) do
    case BootstrapStateStore.save(next, state_store_opts(opts)) do
      :ok -> reconcile_state(next, resolved_hardware_provider(opts), serial, opts, steps + 1)
      {:error, _reason} -> {:retry, :state_persistence_failed, bump_retry(next, :state_persistence_failed)}
    end
  end

  defp verify_recovery_challenge(state, serial, opts) do
    recovery = state.recovery

    with {:ok, assertion} <-
           Contract.recovery_challenge_assertion(
             serial,
             recovery.public_key,
             recovery.challenge_client_nonce
           ),
         {:ok, receipt} <- verify_receipt_envelope(recovery.challenge_receipt, opts),
         :ok <- ensure(receipt.receipt_type == :challenge, :invalid_server_receipt),
         :ok <- ensure(receipt.payload.classification == :recoverable, :invalid_server_receipt),
         :ok <-
           secure_match(
             receipt.payload.request_hash,
             Primitives.sha256(assertion),
             :invalid_server_receipt
           ) do
      {:ok, receipt}
    end
  end

  defp verify_authority(nil, _serial, _opts), do: {:error, :missing_authority}

  defp verify_authority(%{kind: :registration} = authority, serial, opts) do
    with {:ok, assertion} <-
           Contract.registration_assertion(serial, authority.public_key, authority.client_nonce),
         {:ok, receipt} <- verify_receipt_envelope(authority.receipt, opts),
         :ok <- ensure(receipt.receipt_type == :registration, :invalid_server_receipt),
         :ok <- ensure(receipt.payload.outcome == :registered, :invalid_server_receipt),
         :ok <- secure_match(receipt.payload.request_hash, Primitives.sha256(assertion), :invalid_server_receipt),
         :ok <- secure_match(receipt.payload.logical_device_id, authority.logical_device_id, :invalid_server_receipt),
         :ok <- ensure(receipt.payload.credential_epoch == authority.credential_epoch, :invalid_server_receipt) do
      {:ok,
       %{
         authority
         | receipt: receipt.envelope,
           logical_device_id: receipt.payload.logical_device_id,
           credential_epoch: receipt.payload.credential_epoch
       }}
    end
  end

  defp verify_authority(%{kind: :recovery} = authority, serial, opts) do
    with {:ok, challenge_assertion} <-
           Contract.recovery_challenge_assertion(
             serial,
             authority.public_key,
             authority.challenge_client_nonce
           ),
         {:ok, challenge} <- verify_receipt_envelope(authority.challenge_receipt, opts),
         :ok <- ensure(challenge.receipt_type == :challenge, :invalid_server_receipt),
         :ok <- ensure(challenge.payload.classification == :recoverable, :invalid_server_receipt),
         :ok <-
           secure_match(
             challenge.payload.request_hash,
             Primitives.sha256(challenge_assertion),
             :invalid_server_receipt
           ),
         {:ok, lifecycle} <- verify_receipt_envelope(authority.lifecycle_receipt, opts),
         :ok <- ensure(lifecycle.receipt_type == :lifecycle, :invalid_server_receipt),
         :ok <- ensure(lifecycle.payload.lifecycle == :committed, :invalid_server_receipt),
         :ok <-
           secure_match(
             lifecycle.payload.attempt_id,
             challenge.payload.attempt_id,
             :invalid_server_receipt
           ),
         :ok <-
           secure_match(
             lifecycle.payload.challenge_envelope_hash,
             challenge.envelope_hash,
             :invalid_server_receipt
           ),
         :ok <-
           secure_match(
             lifecycle.payload.candidate_fingerprint,
             Primitives.sha256(authority.public_key),
             :invalid_server_receipt
           ),
         {:ok, commit_assertion} <-
           Contract.recovery_commit_assertion(
             challenge.payload.attempt_id,
             authority.public_key,
             challenge.envelope_hash
           ),
         commit_hash = Primitives.sha256(commit_assertion),
         :ok <- secure_match(authority.commit_signing_bytes_hash, commit_hash, :invalid_server_receipt),
         :ok <-
           secure_match(
             lifecycle.payload.accepted_commit_signing_bytes_hash,
             commit_hash,
             :invalid_server_receipt
           ),
         :ok <-
           secure_match(
             lifecycle.payload.logical_device_id,
             authority.logical_device_id,
             :invalid_server_receipt
           ),
         :ok <- ensure(lifecycle.payload.credential_epoch == authority.credential_epoch, :invalid_server_receipt) do
      {:ok,
       %{
         authority
         | challenge_receipt: challenge.envelope,
           lifecycle_receipt: lifecycle.envelope,
           logical_device_id: lifecycle.payload.logical_device_id,
           credential_epoch: lifecycle.payload.credential_epoch
       }}
    end
  end

  defp verify_authority(_authority, _serial, _opts), do: {:error, :invalid_server_receipt}

  defp recovery_identity(%BootstrapState{recovery: %{source: :active, public_key: public_key}}, opts) do
    load_matching_identity(&KeyStore.load/1, public_key, opts)
  end

  defp recovery_identity(%BootstrapState{recovery: %{source: :staged, public_key: public_key}}, opts) do
    load_matching_identity(&KeyStore.load_candidate/1, public_key, opts)
  end

  defp recovery_identity(_state, _opts), do: {:error, :identity_unavailable}

  defp load_matching_identity(loader, public_key, opts) do
    with {:ok, identity} <- loader.(keystore_opts(opts)),
         :ok <- secure_match(IdentityProvider.public_key(identity), public_key, :identity_mismatch) do
      {:ok, identity}
    else
      _ -> {:error, :identity_unavailable}
    end
  end

  defp active_matches_authority?(%{public_key: public_key}, opts) do
    case KeyStore.load(keystore_opts(opts)) do
      {:ok, identity} -> secure_equal?(IdentityProvider.public_key(identity), public_key)
      {:error, _reason} -> false
    end
  end

  defp active_matches_authority?(_authority, _opts), do: false

  defp staged_matches_public_key?(public_key, opts) do
    case KeyStore.load_candidate(keystore_opts(opts)) do
      {:ok, identity} -> secure_equal?(IdentityProvider.public_key(identity), public_key)
      {:error, _reason} -> false
    end
  end

  defp call_challenge(identity, serial, opts) do
    case Keyword.get(opts, :challenge_fun) do
      fun when is_function(fun, 2) -> safe_client_call(fn -> fun.(identity, serial) end)
      nil -> RecoveryClient.challenge(identity, serial, client_opts(opts))
      _ -> {:error, :invalid_client_callback}
    end
  end

  defp call_register(identity, serial, opts) do
    case Keyword.get(opts, :register_fun) do
      fun when is_function(fun, 2) -> safe_client_call(fn -> fun.(identity, serial) end)
      nil -> BootstrapClient.register(identity, serial, client_opts(opts))
      _ -> {:error, :invalid_client_callback}
    end
  end

  defp call_commit(identity, challenge_receipt, opts) do
    case Keyword.get(opts, :commit_fun) do
      fun when is_function(fun, 2) -> safe_client_call(fn -> fun.(identity, challenge_receipt) end)
      nil -> RecoveryClient.commit(identity, challenge_receipt, client_opts(opts))
      _ -> {:error, :invalid_client_callback}
    end
  end

  defp call_status(identity, challenge_receipt, opts) do
    case Keyword.get(opts, :status_fun) do
      fun when is_function(fun, 2) -> safe_client_call(fn -> fun.(identity, challenge_receipt) end)
      nil -> RecoveryClient.status(identity, challenge_receipt, client_opts(opts))
      _ -> {:error, :invalid_client_callback}
    end
  end

  defp safe_client_call(fun) do
    case fun.() do
      {:ok, _result} = ok -> ok
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_client_response}
    end
  rescue
    _exception -> {:error, :client_callback_failed}
  catch
    _kind, _reason -> {:error, :client_callback_failed}
  end

  defp handle_client_error(state, reason, opts) do
    if invalid_receipt_error?(reason) do
      persist_blocked(state, :limbo, :invalid_server_receipt, opts)
    else
      defer_retry(state, :transport_unavailable, opts)
    end
  end

  defp invalid_receipt_error?({:transport, _reason}), do: false
  defp invalid_receipt_error?({:http_status, _status}), do: false
  defp invalid_receipt_error?(:client_callback_failed), do: false
  defp invalid_receipt_error?(:invalid_client_response), do: false
  defp invalid_receipt_error?(_reason), do: true

  defp defer_retry(state, reason, opts) do
    next = bump_retry(state, reason)

    case BootstrapStateStore.save(next, state_store_opts(opts)) do
      :ok -> {:retry, reason, next}
      {:error, _reason} -> {:retry, :state_persistence_failed, bump_retry(state, :state_persistence_failed)}
    end
  end

  defp persist_blocked(state, phase, reason, opts) do
    next = %{state | phase: phase, blocked_reason: reason, retry_count: state.retry_count + 1}

    case BootstrapStateStore.save(next, state_store_opts(opts)) do
      :ok -> {:blocked, reason, next}
      {:error, _reason} -> {:retry, :state_persistence_failed, bump_retry(state, :state_persistence_failed)}
    end
  end

  defp persist_blocked_state(state, opts) do
    case BootstrapStateStore.save(state, state_store_opts(opts)) do
      :ok -> {:blocked, state.blocked_reason, state}
      {:error, _reason} -> {:retry, :state_persistence_failed, bump_retry(state, :state_persistence_failed)}
    end
  end

  defp bump_retry(state, reason) do
    %{state | blocked_reason: reason, retry_count: state.retry_count + 1}
  end

  defp transition(from_phases, to_phase, opts) do
    with {:ok, %BootstrapState{} = state} <- BootstrapStateStore.load(state_store_opts(opts)),
         :ok <- ensure(state.phase in from_phases, :invalid_transition),
         next = %{state | phase: to_phase, blocked_reason: nil, retry_count: 0},
         :ok <- BootstrapStateStore.save(next, state_store_opts(opts)) do
      {:ok, next}
    else
      {:error, :invalid_transition} -> {:error, :invalid_transition}
      {:error, _reason} -> {:error, :state_persistence_failed}
    end
  end

  defp session_lost_state(%BootstrapState{phase: phase, authority: %{kind: :registration}} = state)
       when phase in [:authenticated, :hydrating, :effective],
       do: {:ok, %{state | phase: :registered, blocked_reason: nil, retry_count: 0}}

  defp session_lost_state(%BootstrapState{phase: phase, authority: %{kind: :recovery}} = state)
       when phase in [:authenticated, :hydrating, :effective],
       do: {:ok, %{state | phase: :committed, blocked_reason: nil, retry_count: 0}}

  defp session_lost_state(%BootstrapState{phase: phase} = state) when phase in [:registered, :committed],
    do: {:ok, state}

  defp session_lost_state(_state), do: {:error, :invalid_transition}

  defp persist_if_changed(state, state, _opts), do: :ok
  defp persist_if_changed(_previous, next, opts), do: BootstrapStateStore.save(next, state_store_opts(opts))

  defp hardware_identity(opts) do
    provider_module = Keyword.get(opts, :hardware_identity_provider, RaspberryPiSoCSerial)
    provider = Keyword.get_lazy(opts, :hardware_provider, fn -> provider_module.provider() end)

    result =
      case Keyword.get(opts, :hardware_identity_fun) do
        fun when is_function(fun, 0) ->
          fun.()

        nil ->
          cond do
            function_exported?(provider_module, :identifier, 1) ->
              provider_module.identifier(Keyword.get(opts, :hardware_identity_opts, []))

            function_exported?(provider_module, :identifier, 0) ->
              provider_module.identifier()

            true ->
              {:error, :invalid_hardware_identity_callback}
          end

        _ ->
          {:error, :invalid_hardware_identity_callback}
      end

    case result do
      {:ok, serial} ->
        with :ok <- Contract.validate_wire_serial(serial) do
          {:ok, provider, serial}
        end

      {:error, reason} ->
        {:error, reason}

      _other ->
        {:error, :invalid_hardware_identity_callback}
    end
  rescue
    _exception -> {:error, :hardware_identity_unavailable}
  catch
    _kind, _reason -> {:error, :hardware_identity_unavailable}
  end

  defp server_public_key(opts) do
    case Keyword.fetch(opts, :server_public_key) do
      {:ok, <<_::binary-size(32)>> = key} -> {:ok, key}
      {:ok, _invalid} -> {:error, :not_configured}
      :error -> ServerIdentity.fetch_public_key()
    end
  end

  defp read_legacy_marker(opts) do
    case BootstrapStateStore.read_legacy_marker(state_store_opts(opts)) do
      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, %{"device_id" => device_id, "fingerprint" => fingerprint}}
          when is_binary(device_id) and device_id != "" and is_binary(fingerprint) and
                 byte_size(fingerprint) == 64 ->
            case Base.decode16(fingerprint, case: :lower) do
              {:ok, <<_::binary-size(32)>>} -> {:ok, %{"device_id" => device_id, "fingerprint" => fingerprint}}
              _ -> {:error, :invalid_marker}
            end

          _ ->
            {:error, :invalid_marker}
        end

      {:error, :enoent} ->
        :absent

      {:error, _reason} ->
        {:error, :invalid_marker}
    end
  end

  defp valid_legacy_identity?(opts) do
    with {:ok, marker} <- normalize_legacy_result(read_legacy_marker(opts)),
         {:ok, identity} <- KeyStore.load(keystore_opts(opts)) do
      legacy_marker_matches?(marker, identity)
    else
      _ -> false
    end
  end

  defp normalize_legacy_result({:ok, marker}), do: {:ok, marker}
  defp normalize_legacy_result(_other), do: {:error, :invalid_marker}

  defp legacy_marker_matches?(%{"fingerprint" => fingerprint}, identity) do
    fingerprint == IdentityProvider.fingerprint(identity)
  end

  defp ensure_legacy_enrollment_state(%BootstrapState{
         phase: :limbo,
         blocked_reason: :legacy_enrollment_required,
         legacy_marker: true
       }),
       do: :ok

  defp ensure_legacy_enrollment_state(_state), do: {:error, :invalid_transition}

  defp prepare_legacy_enrollment(%BootstrapState{legacy_registration: nil} = state, identity, serial, opts) do
    with {:ok, request} <- BootstrapClient.prepare_registration(identity, serial, client_opts(opts)) do
      next = %{
        state
        | legacy_registration: %{
            public_key: request.candidate_public_key,
            client_nonce: request.client_nonce
          }
      }

      {:ok, request, next}
    end
  end

  defp prepare_legacy_enrollment(
         %BootstrapState{legacy_registration: %{public_key: public_key, client_nonce: nonce}} = state,
         identity,
         serial,
         opts
       ) do
    with :ok <- secure_match(IdentityProvider.public_key(identity), public_key, :identity_mismatch),
         {:ok, request} <-
           BootstrapClient.prepare_registration(
             identity,
             serial,
             Keyword.put(client_opts(opts), :client_nonce, nonce)
           ) do
      {:ok, request, state}
    end
  end

  defp registration_authority(request, receipt) do
    %{
      kind: :registration,
      public_key: request.candidate_public_key,
      client_nonce: request.client_nonce,
      receipt: receipt.envelope,
      logical_device_id: receipt.payload.logical_device_id,
      credential_epoch: receipt.payload.credential_epoch
    }
  end

  defp hardware_digest_matches?(state, provider, serial) do
    is_binary(state.hardware_identity_digest) and
      secure_equal?(state.hardware_identity_digest, hardware_identity_digest(provider, serial))
  end

  defp receipt_opts(opts), do: [server_public_key: Keyword.fetch!(opts, :resolved_server_public_key)]

  defp client_opts(opts) do
    opts
    |> Keyword.get(:client_opts, [])
    |> Keyword.put_new(:server_public_key, Keyword.get(opts, :resolved_server_public_key, opts[:server_public_key]))
    |> maybe_put_client_nonce(opts)
  end

  defp maybe_put_client_nonce(client_opts, opts) do
    case Keyword.fetch(opts, :client_nonce) do
      {:ok, nonce} -> Keyword.put(client_opts, :client_nonce, nonce)
      :error -> client_opts
    end
  end

  defp state_store_opts(opts) do
    Keyword.get_lazy(opts, :state_store_opts, fn ->
      opts
      |> keystore_opts()
      |> BootstrapStateStore.opts_from_keystore()
    end)
  end

  defp keystore_opts(opts), do: Keyword.get(opts, :keystore_opts, [])
  defp resolved_hardware_provider(opts), do: Keyword.fetch!(opts, :resolved_hardware_provider)

  defp verify_receipt_envelope(envelope, opts) do
    Contract.verify_receipt_envelope(envelope, Keyword.fetch!(opts, :resolved_server_public_key))
  end

  defp sanitize_callback_error(reason)
       when reason in [:invalid_transition, :identity_mismatch, :legacy_enrollment_failed],
       do: reason

  defp sanitize_callback_error(_reason), do: :legacy_enrollment_failed

  defp secure_match(left, right, error) do
    if secure_equal?(left, right), do: :ok, else: {:error, error}
  end

  defp secure_equal?(left, right)
       when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right),
       do: Primitives.secure_compare(left, right)

  defp secure_equal?(_left, _right), do: false
  defp ensure(true, _error), do: :ok
  defp ensure(false, error), do: {:error, error}
  defp lp(binary), do: <<byte_size(binary)::unsigned-big-integer-size(16), binary::binary>>
end
