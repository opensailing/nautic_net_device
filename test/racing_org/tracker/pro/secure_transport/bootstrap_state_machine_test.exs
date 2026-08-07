defmodule RacingOrg.Tracker.Pro.SecureTransport.BootstrapStateMachineTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.RecoveryV2TestSupport, as: Support
  alias RacingOrg.Tracker.Pro.SecureTransport.BootstrapState
  alias RacingOrg.Tracker.Pro.SecureTransport.BootstrapStateMachine
  alias RacingOrg.Tracker.Pro.SecureTransport.BootstrapStateStore
  alias RacingOrg.Tracker.Pro.SecureTransport.IdentityProvider
  alias RacingOrg.Tracker.Pro.SecureTransport.KeyStore
  alias RacingOrg.Tracker.Pro.SecureTransport.Primitives

  @serial "000000001234abcd"
  @old_seed :binary.copy(<<0x11>>, 32)
  @candidate_seed :binary.copy(<<0x22>>, 32)

  defmodule ZeroArityHardwareIdentity do
    @behaviour RacingOrg.Tracker.Pro.HardwareIdentity

    @impl true
    def provider, do: "raspberry_pi_soc_serial_v1"

    @impl true
    def identifier, do: {:ok, "000000001234abcd"}
  end

  setup do
    base = Path.join(System.tmp_dir!(), "bootstrap_machine_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(base) end)

    common = [
      keystore_opts: [base_path: base, seed_generator: fn -> @candidate_seed end],
      state_store_opts: [base_path: base],
      hardware_identity_fun: fn -> {:ok, @serial} end,
      server_public_key: Support.server_public_key()
    ]

    %{base: base, common: common}
  end

  test "hardware identity read failures persist a sanitized retry without network activity", ctx do
    opts =
      Keyword.merge(ctx.common,
        hardware_identity_fun: fn -> {:error, {:serial_source_read_failed, :cpuinfo, :eacces}} end,
        challenge_fun: fn _, _ -> flunk("hardware identity must be available before network activity") end
      )

    assert {:retry, :hardware_identity_unavailable, %BootstrapState{} = state} =
             BootstrapStateMachine.reconcile(opts)

    assert state.phase == :uninitialized
    assert state.blocked_reason == :hardware_identity_unavailable
    assert state.retry_count == 1
    assert {:ok, ^state} = BootstrapStateStore.load(base_path: ctx.base)
  end

  test "accepts a behavior-compliant hardware provider that exposes identifier/0", ctx do
    opts =
      ctx.common
      |> Keyword.delete(:hardware_identity_fun)
      |> Keyword.put(:hardware_identity_provider, ZeroArityHardwareIdentity)
      |> Keyword.merge(
        challenge_fun: fn identity, serial ->
          Support.challenge_result(identity, serial, classification: :not_enrolled, reason: :none)
        end,
        register_fun: fn identity, serial -> Support.registration_result(identity, serial) end
      )

    assert {:ok, %BootstrapState{phase: :registered}} = BootstrapStateMachine.reconcile(opts)
  end

  test "fresh unknown hardware challenges first, then registers v2 with one staged identity", ctx do
    parent = self()

    challenge_fun = fn identity, serial ->
      send(parent, {:challenge_key, IdentityProvider.public_key(identity)})
      Support.challenge_result(identity, serial, classification: :not_enrolled, reason: :none)
    end

    register_fun = fn identity, serial ->
      send(parent, {:registration_key, IdentityProvider.public_key(identity)})
      Support.registration_result(identity, serial, device_id: Support.device_id())
    end

    assert {:ok, %BootstrapState{phase: :registered} = state} =
             BootstrapStateMachine.reconcile(
               ctx.common ++
                 [
                   challenge_fun: challenge_fun,
                   register_fun: register_fun,
                   commit_fun: fn _, _ -> flunk("fresh registration must not commit recovery") end
                 ]
             )

    assert_receive {:challenge_key, public_key}
    assert_receive {:registration_key, ^public_key}
    assert state.authority.kind == :registration
    assert state.authority.public_key == public_key
    assert state.authority.logical_device_id == Support.device_id()
    assert state.authority.credential_epoch == 0
    assert is_binary(state.authority.receipt)
    assert state.previous_authority == nil
    assert state.recovery == nil

    assert {:ok, active} = KeyStore.load(base_path: ctx.base)
    assert IdentityProvider.public_key(active) == public_key
    assert {:error, :candidate_not_staged} = KeyStore.load_candidate(base_path: ctx.base)
  end

  test "missing active key preserves prior authority, commits recovery, persists receipt, then promotes", ctx do
    old_identity = Support.identity(0x11)
    {:ok, old_registration} = Support.registration_result(old_identity, @serial)
    prior_authority = registration_authority(old_registration)

    assert :ok =
             BootstrapStateStore.save(
               %BootstrapState{
                 phase: :registered,
                 hardware_identity_digest:
                   BootstrapStateMachine.hardware_identity_digest("raspberry_pi_soc_serial_v1", @serial),
                 authority: prior_authority
               },
               base_path: ctx.base
             )

    challenge_fun = fn identity, serial -> Support.challenge_result(identity, serial) end

    commit_fun = fn identity, challenge_receipt ->
      Support.lifecycle_result(identity, challenge_receipt,
        device_id: prior_authority.logical_device_id,
        credential_epoch: 7
      )
    end

    assert {:ok, %BootstrapState{phase: :committed} = state} =
             BootstrapStateMachine.reconcile(ctx.common ++ [challenge_fun: challenge_fun, commit_fun: commit_fun])

    assert state.previous_authority == prior_authority
    assert state.authority.kind == :recovery
    assert state.authority.logical_device_id == prior_authority.logical_device_id
    assert state.authority.credential_epoch == 7
    assert is_binary(state.authority.challenge_receipt)
    assert is_binary(state.authority.lifecycle_receipt)
    assert byte_size(state.authority.commit_signing_bytes_hash) == 32

    assert {:ok, active} = KeyStore.load(base_path: ctx.base)
    assert IdentityProvider.public_key(active) == state.authority.public_key
    assert {:error, :candidate_not_staged} = KeyStore.load_candidate(base_path: ctx.base)
  end

  test "recovery commit for a different logical device enters limbo without promotion", ctx do
    active_identity = persist_active_identity(ctx.base, @old_seed)
    prior_identity = Support.identity(0x33)
    {:ok, prior_registration} = Support.registration_result(prior_identity, @serial)
    prior_authority = registration_authority(prior_registration)
    persist_registered_state(ctx.base, prior_authority)

    commit_fun = fn identity, challenge_receipt ->
      Support.lifecycle_result(identity, challenge_receipt,
        device_id: :binary.copy(<<0xDD>>, 16),
        credential_epoch: 7
      )
    end

    assert {:blocked, :invalid_server_receipt, %BootstrapState{phase: :limbo}} =
             BootstrapStateMachine.reconcile(
               ctx.common ++
                 [
                   challenge_fun: fn identity, serial -> Support.challenge_result(identity, serial) end,
                   commit_fun: commit_fun
                 ]
             )

    assert {:ok, active} = KeyStore.load(base_path: ctx.base)
    assert IdentityProvider.public_key(active) == IdentityProvider.public_key(active_identity)
    assert {:ok, _candidate} = KeyStore.load_candidate(base_path: ctx.base)
  end

  test "durable recovery authority rejects a lifecycle receipt for another attempt", ctx do
    identity = persist_active_identity(ctx.base, @old_seed)
    {:ok, challenge} = Support.challenge_result(identity, @serial)

    {:ok, lifecycle} =
      Support.lifecycle_result(identity, challenge.receipt,
        attempt_id: :binary.copy(<<0xAB>>, 16),
        credential_epoch: 2
      )

    authority = %{
      kind: :recovery,
      public_key: IdentityProvider.public_key(identity),
      challenge_client_nonce: challenge.request.client_nonce,
      challenge_receipt: challenge.receipt.envelope,
      commit_signing_bytes_hash: Primitives.sha256(lifecycle.request.assertion),
      lifecycle_receipt: lifecycle.receipt.envelope,
      logical_device_id: lifecycle.receipt.payload.logical_device_id,
      credential_epoch: lifecycle.receipt.payload.credential_epoch
    }

    BootstrapStateStore.save!(
      %BootstrapState{
        phase: :committed,
        hardware_identity_digest: BootstrapStateMachine.hardware_identity_digest("raspberry_pi_soc_serial_v1", @serial),
        authority: authority
      },
      base_path: ctx.base
    )

    refute BootstrapStateMachine.authorized?(ctx.common)
  end

  test "known registration recovery_required reuses one local candidate and never creates another", ctx do
    {:ok, generated} = Agent.start_link(fn -> 0 end)
    {:ok, challenges} = Agent.start_link(fn -> 0 end)

    keystore_opts =
      Keyword.put(ctx.common[:keystore_opts], :seed_generator, fn ->
        Agent.update(generated, &(&1 + 1))
        @candidate_seed
      end)

    challenge_fun = fn identity, serial ->
      call = Agent.get_and_update(challenges, fn count -> {count, count + 1} end)

      if call == 0 do
        Support.challenge_result(identity, serial, classification: :not_enrolled, reason: :none)
      else
        Support.challenge_result(identity, serial)
      end
    end

    register_fun = fn identity, serial ->
      Support.registration_result(identity, serial, outcome: :recovery_required, reason: :identity_conflict)
    end

    commit_fun = fn identity, challenge_receipt ->
      Support.lifecycle_result(identity, challenge_receipt, credential_epoch: 3)
    end

    assert {:ok, %BootstrapState{phase: :committed}} =
             BootstrapStateMachine.reconcile(
               Keyword.merge(ctx.common,
                 keystore_opts: keystore_opts,
                 challenge_fun: challenge_fun,
                 register_fun: register_fun,
                 commit_fun: commit_fun
               )
             )

    assert Agent.get(generated, & &1) == 1
    assert Agent.get(challenges, & &1) == 2
  end

  test "registration uniqueness conflicts yield to supervised backoff before reclassification", ctx do
    {:ok, calls} = Agent.start_link(fn -> %{challenge: 0, register: 0} end)

    challenge_fun = fn identity, serial ->
      Agent.update(calls, &Map.update!(&1, :challenge, fn count -> count + 1 end))
      Support.challenge_result(identity, serial, classification: :not_enrolled, reason: :none)
    end

    register_fun = fn _identity, _serial ->
      Agent.update(calls, &Map.update!(&1, :register, fn count -> count + 1 end))
      {:error, :registration_conflict}
    end

    assert {:retry, :transport_unavailable, %BootstrapState{phase: :recovery_candidate}} =
             BootstrapStateMachine.reconcile(
               ctx.common ++ [challenge_fun: challenge_fun, register_fun: register_fun]
             )

    assert Agent.get(calls, & &1) == %{challenge: 1, register: 1}
  end

  test "a lost commit response persists uncertainty and recovers only through candidate-PoP status", ctx do
    {:ok, commit_calls} = Agent.start_link(fn -> 0 end)

    challenge_fun = fn identity, serial -> Support.challenge_result(identity, serial) end

    commit_fun = fn _identity, _challenge_receipt ->
      Agent.update(commit_calls, &(&1 + 1))
      {:error, {:transport, :closed}}
    end

    first_opts =
      ctx.common ++
        [
          challenge_fun: challenge_fun,
          commit_fun: commit_fun,
          status_fun: fn _, _ -> flunk("status is used only after the uncertain commit is persisted") end
        ]

    assert {:retry, :transport_unavailable, %BootstrapState{phase: :challenged} = challenged} =
             BootstrapStateMachine.reconcile(first_opts)

    assert challenged.recovery.commit_uncertain
    assert Agent.get(commit_calls, & &1) == 1

    status_fun = fn identity, challenge_receipt ->
      Support.status_result(identity, challenge_receipt, credential_epoch: 4)
    end

    second_opts =
      ctx.common ++
        [
          commit_fun: fn _, _ -> flunk("uncertain commit must use status, not rotate or recommit") end,
          status_fun: status_fun
        ]

    assert {:ok, %BootstrapState{phase: :committed} = committed} =
             BootstrapStateMachine.reconcile(second_opts)

    assert committed.authority.credential_epoch == 4
    assert Agent.get(commit_calls, & &1) == 1
  end

  test "never authorizes challenge expiry from the tracker RTC", ctx do
    challenge_fun = fn identity, serial ->
      Support.challenge_result(identity, serial, expires_at_unix_s: 1)
    end

    commit_fun = fn identity, challenge_receipt ->
      assert challenge_receipt.payload.expires_at_unix_s == 1
      Support.lifecycle_result(identity, challenge_receipt, credential_epoch: 2)
    end

    assert {:ok, %BootstrapState{phase: :committed}} =
             BootstrapStateMachine.reconcile(ctx.common ++ [challenge_fun: challenge_fun, commit_fun: commit_fun])
  end

  test "signed blocked classifications persist only a closed sanitized reason", ctx do
    challenge_fun = fn identity, serial ->
      Support.challenge_result(identity, serial,
        classification: :blocked,
        reason: :active_session_conflict
      )
    end

    assert {:blocked, :active_session_conflict, %BootstrapState{} = state} =
             BootstrapStateMachine.reconcile(ctx.common ++ [challenge_fun: challenge_fun])

    assert state.phase == :blocked
    assert state.blocked_reason == :active_session_conflict
    assert state.retry_count == 1
    refute inspect(state) =~ @serial
    assert {:ok, ^state} = BootstrapStateStore.load(base_path: ctx.base)
  end

  test "a validly signed receipt for another request enters limbo and does not promote", ctx do
    challenge_fun = fn identity, serial ->
      Support.challenge_result(identity, serial, classification: :not_enrolled, reason: :none)
    end

    register_fun = fn identity, serial ->
      {:ok, result} = Support.registration_result(identity, serial)
      wrong = Support.tamper_request_hash(result.receipt, :binary.copy(<<0xAA>>, 32))
      {:ok, %{result | receipt: wrong}}
    end

    assert {:blocked, :invalid_server_receipt, %BootstrapState{phase: :limbo} = state} =
             BootstrapStateMachine.reconcile(ctx.common ++ [challenge_fun: challenge_fun, register_fun: register_fun])

    assert state.blocked_reason == :invalid_server_receipt
    assert {:error, :not_provisioned} = KeyStore.load(base_path: ctx.base)
    assert {:ok, _candidate} = KeyStore.load_candidate(base_path: ctx.base)
  end

  test "commit receipt persistence failure leaves the old key and challenged transcript authoritative", ctx do
    old_identity = persist_active_identity(ctx.base, @old_seed)
    prior_identity = Support.identity(0x33)
    {:ok, prior_registration} = Support.registration_result(prior_identity, @serial)
    prior_authority = registration_authority(prior_registration)
    persist_registered_state(ctx.base, prior_authority)

    {:ok, rename_count} = Agent.start_link(fn -> 0 end)

    state_store_opts = [
      base_path: ctx.base,
      fault_injector: fn
        :before_rename ->
          count = Agent.get_and_update(rename_count, fn count -> {count + 1, count + 1} end)
          if count == 3, do: {:error, :power_loss}, else: :ok

        _ ->
          :ok
      end
    ]

    assert {:retry, :state_persistence_failed, _state} =
             BootstrapStateMachine.reconcile(
               Keyword.merge(ctx.common,
                 state_store_opts: state_store_opts,
                 challenge_fun: fn identity, serial -> Support.challenge_result(identity, serial) end,
                 commit_fun: fn identity, challenge_receipt ->
                   Support.lifecycle_result(identity, challenge_receipt,
                     device_id: prior_authority.logical_device_id,
                     credential_epoch: 8
                   )
                 end
               )
             )

    assert {:ok, active} = KeyStore.load(base_path: ctx.base)
    assert IdentityProvider.public_key(active) == IdentityProvider.public_key(old_identity)
    assert {:ok, _candidate} = KeyStore.load_candidate(base_path: ctx.base)
    assert {:ok, %BootstrapState{phase: :challenged}} = BootstrapStateStore.load(base_path: ctx.base)
  end

  test "a complete candidate left by a post-rename durability error is retried after reboot", ctx do
    active_identity = persist_active_identity(ctx.base, @old_seed)
    prior_identity = Support.identity(0x33)
    {:ok, prior_registration} = Support.registration_result(prior_identity, @serial)
    prior_authority = registration_authority(prior_registration)
    persist_registered_state(ctx.base, prior_authority)

    faulted_keystore_opts = [
      base_path: ctx.base,
      seed_generator: fn -> @candidate_seed end,
      fault_injector: fn
        :renamed -> {:error, :power_loss}
        _stage -> :ok
      end
    ]

    assert {:retry, :identity_unavailable, %BootstrapState{phase: :registered} = retry_state} =
             BootstrapStateMachine.reconcile(
               Keyword.merge(ctx.common,
                 keystore_opts: faulted_keystore_opts,
                 challenge_fun: fn _, _ -> flunk("candidate must be durable before network activity") end
               )
             )

    assert retry_state.blocked_reason == :identity_unavailable
    assert {:ok, still_active} = KeyStore.load(base_path: ctx.base)
    assert IdentityProvider.public_key(still_active) == IdentityProvider.public_key(active_identity)
    assert {:ok, staged} = KeyStore.load_candidate(base_path: ctx.base)

    assert IdentityProvider.public_key(staged) ==
             Primitives.ed25519_public_from_secret(@candidate_seed)

    assert {:ok, %BootstrapState{phase: :committed} = resumed} =
             BootstrapStateMachine.reconcile(
               ctx.common ++
                 [
                   challenge_fun: fn identity, serial -> Support.challenge_result(identity, serial) end,
                   commit_fun: fn identity, challenge_receipt ->
                     Support.lifecycle_result(identity, challenge_receipt,
                       device_id: prior_authority.logical_device_id,
                       credential_epoch: 10
                     )
                   end
                 ]
             )

    assert resumed.authority.public_key == IdentityProvider.public_key(staged)
  end

  test "promotion failure leaves a verified committed receipt durable and resumes without network", ctx do
    old_identity = persist_active_identity(ctx.base, @old_seed)
    prior_identity = Support.identity(0x33)
    {:ok, prior_registration} = Support.registration_result(prior_identity, @serial)
    prior_authority = registration_authority(prior_registration)
    persist_registered_state(ctx.base, prior_authority)

    {:ok, rename_count} = Agent.start_link(fn -> 0 end)

    keystore_opts = [
      base_path: ctx.base,
      seed_generator: fn -> @candidate_seed end,
      fault_injector: fn
        :before_rename ->
          count = Agent.get_and_update(rename_count, fn count -> {count + 1, count + 1} end)
          if count == 2, do: {:error, :power_loss}, else: :ok

        _ ->
          :ok
      end
    ]

    assert {:retry, :candidate_promotion_failed, %BootstrapState{phase: :committed} = committed} =
             BootstrapStateMachine.reconcile(
               Keyword.merge(ctx.common,
                 keystore_opts: keystore_opts,
                 challenge_fun: fn identity, serial -> Support.challenge_result(identity, serial) end,
                 commit_fun: fn identity, challenge_receipt ->
                   Support.lifecycle_result(identity, challenge_receipt,
                     device_id: prior_authority.logical_device_id,
                     credential_epoch: 9
                   )
                 end
               )
             )

    assert is_binary(committed.authority.lifecycle_receipt)
    assert {:ok, active} = KeyStore.load(base_path: ctx.base)
    assert IdentityProvider.public_key(active) == IdentityProvider.public_key(old_identity)
    assert {:ok, _candidate} = KeyStore.load_candidate(base_path: ctx.base)

    no_network = [
      challenge_fun: fn _, _ -> flunk("committed restart must not challenge") end,
      commit_fun: fn _, _ -> flunk("committed restart must not commit") end,
      status_fun: fn _, _ -> flunk("committed restart must not query status") end
    ]

    assert {:ok, %BootstrapState{phase: :committed} = resumed} =
             BootstrapStateMachine.reconcile(ctx.common ++ no_network)

    assert {:ok, promoted} = KeyStore.load(base_path: ctx.base)
    assert IdentityProvider.public_key(promoted) == resumed.authority.public_key
  end

  test "valid legacy marker and matching key wait for an authenticated enrollment hook", ctx do
    identity = persist_active_identity(ctx.base, @old_seed)
    marker_path = Path.join(ctx.base, "register_marker.json")

    File.write!(
      marker_path,
      Jason.encode!(%{
        "device_id" => "legacy-device",
        "fingerprint" => IdentityProvider.fingerprint(identity),
        "status" => "assigned"
      })
    )

    no_network = [
      challenge_fun: fn _, _ -> flunk("valid legacy identity authenticates before enrollment") end,
      register_fun: fn _, _ -> flunk("legacy migration is not unauthenticated registration") end
    ]

    assert {:blocked, :legacy_enrollment_required, %BootstrapState{phase: :limbo} = state} =
             BootstrapStateMachine.reconcile(ctx.common ++ no_network)

    assert state.legacy_marker
    assert File.exists?(marker_path)

    nonce = :binary.copy(<<0x45>>, 32)

    assert {:ok, request} =
             BootstrapStateMachine.legacy_enrollment_request(ctx.common ++ [client_nonce: nonce])

    {:ok, response} = Support.registration_result(identity, @serial, client_nonce: nonce)

    assert {:ok, %BootstrapState{phase: :registered}} =
             BootstrapStateMachine.accept_legacy_enrollment(
               Support.receipt_response(response.receipt),
               ctx.common
             )

    assert request.body == response.request.body
    refute File.exists?(marker_path)
  end

  test "keyless legacy marker never falls through to fresh registration", ctx do
    File.mkdir_p!(ctx.base)

    File.write!(
      Path.join(ctx.base, "register_marker.json"),
      Jason.encode!(%{
        "device_id" => "legacy-device",
        "fingerprint" => String.duplicate("a", 64),
        "status" => "assigned"
      })
    )

    challenge_fun = fn identity, serial ->
      Support.challenge_result(identity, serial, classification: :not_enrolled, reason: :none)
    end

    assert {:blocked, :legacy_binding_required, %BootstrapState{phase: :limbo} = state} =
             BootstrapStateMachine.reconcile(
               ctx.common ++
                 [
                   challenge_fun: challenge_fun,
                   register_fun: fn _, _ -> flunk("keyless legacy hardware must await backend binding") end
                 ]
             )

    assert state.legacy_marker
    assert {:error, :not_provisioned} = KeyStore.load(base_path: ctx.base)
    assert {:ok, _candidate} = KeyStore.load_candidate(base_path: ctx.base)
  end

  test "legacy enrollment retries reuse the exact persisted proof after a lost reply", ctx do
    identity = persist_active_identity(ctx.base, @old_seed)

    File.write!(
      Path.join(ctx.base, "register_marker.json"),
      Jason.encode!(%{
        "device_id" => "legacy-device",
        "fingerprint" => IdentityProvider.fingerprint(identity),
        "status" => "assigned"
      })
    )

    assert {:blocked, :legacy_enrollment_required, %BootstrapState{phase: :limbo}} =
             BootstrapStateMachine.reconcile(
               ctx.common ++
                 [
                   challenge_fun: fn _, _ -> flunk("valid legacy identity authenticates before enrollment") end,
                   register_fun: fn _, _ -> flunk("legacy migration is not unauthenticated registration") end
                 ]
             )

    {:ok, nonce_calls} = Agent.start_link(fn -> 0 end)

    nonce_generator = fn ->
      call = Agent.get_and_update(nonce_calls, fn count -> {count, count + 1} end)
      :binary.copy(<<0x70 + call>>, 32)
    end

    opts = Keyword.put(ctx.common, :client_opts, nonce_generator: nonce_generator)

    assert {:ok, first} = BootstrapStateMachine.legacy_enrollment_request(opts)
    assert {:ok, replay} = BootstrapStateMachine.legacy_enrollment_request(opts)

    assert replay.assertion == first.assertion
    assert replay.body == first.body
    assert replay.signature == first.signature
    assert replay.client_nonce == first.client_nonce
    assert Agent.get(nonce_calls, & &1) == 1
  end

  test "authenticated readiness is durably cleared when the secure session is lost", ctx do
    identity = persist_active_identity(ctx.base, @old_seed)
    {:ok, registration} = Support.registration_result(identity, @serial)
    persist_registered_state(ctx.base, registration_authority(registration))

    assert {:ok, %BootstrapState{phase: :authenticated}} =
             BootstrapStateMachine.mark_authenticated(ctx.common)

    assert {:ok, %BootstrapState{phase: :hydrating}} =
             BootstrapStateMachine.mark_hydrating(ctx.common)

    assert {:ok, %BootstrapState{phase: :effective}} =
             BootstrapStateMachine.mark_effective(ctx.common)

    assert {:ok, %BootstrapState{phase: :registered}} =
             BootstrapStateMachine.mark_session_lost(ctx.common)

    assert {:ok, %BootstrapState{phase: :registered}} =
             BootstrapStateMachine.mark_session_lost(ctx.common)

    assert {:ok, %BootstrapState{phase: :registered}} = BootstrapStateStore.load(base_path: ctx.base)
  end

  test "authenticated, hydrating, and effective callbacks are durable fenced transitions", ctx do
    identity = persist_active_identity(ctx.base, @old_seed)
    {:ok, registration} = Support.registration_result(identity, @serial)
    persist_registered_state(ctx.base, registration_authority(registration))

    assert {:ok, %BootstrapState{phase: :authenticated}} =
             BootstrapStateMachine.mark_authenticated(ctx.common)

    assert {:ok, %BootstrapState{phase: :hydrating}} =
             BootstrapStateMachine.mark_hydrating(ctx.common)

    assert {:ok, %BootstrapState{phase: :effective}} =
             BootstrapStateMachine.mark_effective(ctx.common)

    assert {:error, :invalid_transition} = BootstrapStateMachine.mark_hydrating(ctx.common)
    assert {:ok, %BootstrapState{phase: :effective}} = BootstrapStateStore.load(base_path: ctx.base)
  end

  defp registration_authority(%{request: request, receipt: receipt}) do
    %{
      kind: :registration,
      public_key: request.candidate_public_key,
      client_nonce: request.client_nonce,
      receipt: receipt.envelope,
      logical_device_id: receipt.payload.logical_device_id,
      credential_epoch: receipt.payload.credential_epoch
    }
  end

  defp persist_registered_state(base, authority) do
    BootstrapStateStore.save!(
      %BootstrapState{
        phase: :registered,
        hardware_identity_digest: BootstrapStateMachine.hardware_identity_digest("raspberry_pi_soc_serial_v1", @serial),
        authority: authority
      },
      base_path: base
    )
  end

  defp persist_active_identity(base, seed) do
    {:ok, identity} = KeyStore.load_or_generate(base_path: base, seed_generator: fn -> seed end)
    identity
  end
end
