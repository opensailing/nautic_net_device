defmodule RacingOrg.Tracker.Pro.WiFiManager do
  @moduledoc """
  Owns `wlan0` at runtime: applies Wi-Fi configuration (set credentials / enable /
  disable→radio-off), persists the DESIRED state to `/data` so it survives reboots
  WITHOUT reflashing, and reconciles on boot so a runtime change takes precedence
  over the compile-time default baked into `config/target.exs`.

  ## Authority / boot precedence

  The persisted owner marker in `RacingOrg.Tracker.Pro.WiFi.Store` is the runtime
  authority. On boot:

    * An exact readable marker is reconciled, including its exactly bound Desired
      State credential when one is required.
    * An exactly missing marker selects the compile default:
      `compile_default == false` rfkill-blocks the radio, while
      `compile_default == true` leaves the `target.exs` configuration in place.
    * An unreadable, corrupt, or unrecognized marker is NOT treated as missing.
      The manager leaves `wlan0` unchanged and clears its cached activation id so
      higher-level reconciliation remains fail-closed instead of guessing.

  Runtime configurations use `persist: false`; this owner marker, not VintageNet
  persistence, decides what is restored on the next boot. Rolling back to an
  exactly empty owner resets VintageNet to its compile-time defaults before
  reopening the radio when those defaults are enabled.

  ## Lifecycle

  Started ONLY on a real device target (see `RacingOrg.Tracker.Pro.Application`); it decides
  the rest internally. Never started on host/test.

  All side effects are injectable via `start_link/1` opts (defaulting to the real
  VintageNet / `RacingOrg.Tracker.Pro.WiFiPower` implementations) so the reconcile and
  apply logic is fully unit-testable on host without VintageNet present.

  ## Credential handling

  A Desired State candidate arrives with its credential wrapped in a
  `RacingOrg.Tracker.Pro.WiFiManager.Secret`, and the plaintext exists only for the
  duration of the call that applies it. It is NEVER placed in manager state, in the
  owner marker, in a desired-state journal, or in a log line.

  Reconnect durability is preserved by writing credentials to the
  `RacingOrg.Tracker.Pro.WiFi.Store` sidecar, which `Store.load/1` never returns, so the
  owner marker this manager commits stays secretless while the device keeps what it
  needs to reassociate after a reboot. Prior and candidate bindings may coexist only
  while marker authority is unresolved, then the losing choice is pruned. A marker
  whose credential is absent is adopted for its activation id but NOT applied — a
  half-applied radio is worse than an untouched one.

  Legacy `apply_config/2` records still round-trip their inline `:psk`, but their
  retry decision is derived from the exact durable owner marker rather than a
  cached process version. Same-version replay retries incomplete credential
  cleanup. A complete authenticated legacy command may repair unreadable owner
  bytes by first establishing an exact empty authority; boot and Desired State
  reconciliation never perform that speculative replacement.
  """

  use GenServer
  require Logger

  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.Section
  alias RacingOrg.Tracker.Pro.WiFi.Store
  alias RacingOrg.Tracker.Pro.WiFiManager.Secret
  alias RacingOrg.Tracker.Pro.WiFiPower

  @type desired_state :: %{
          optional(:desired_activation_id) => binary(),
          version: integer(),
          enabled: boolean(),
          ssid: String.t() | nil,
          psk: String.t() | nil
        }

  @type public_desired_state :: %{
          version: non_neg_integer(),
          enabled: boolean(),
          ssid: String.t() | nil
        }

  # The /data directory the desired Wi-Fi state is persisted under by default.
  @default_store_dir "/data/wifi"

  @connection_property ["interface", "wlan0", "connection"]

  # --- Client API ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.fetch(opts, :name) do
      {:ok, nil} -> GenServer.start_link(__MODULE__, opts)
      {:ok, name} -> GenServer.start_link(__MODULE__, opts, name: name)
      :error -> GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    end
  end

  @doc """
  Apply a desired Wi-Fi config (public API, called by J5's WSS channel handler).

  Accepts a map with string OR atom keys: `ssid`, `psk`, `enabled`, `version`.

  Idempotency is derived from the exact durable owner marker: a request whose
  `version` is already covered by that authority returns `{:ok, :unchanged}`
  (so re-pushing the same config on every reconnect does not churn the radio).
  Otherwise:

    * `enabled: true`  → reconfigure `wlan0` as a WPA-PSK client + rfkill UNBLOCK.
      `ssid` is required; without it returns `{:error, :ssid_required}` and applies
      nothing.
    * `enabled: false` → deconfigure `wlan0` + rfkill BLOCK + link down (radio off,
      battery save).

  Persists the new desired state (including `version`) and returns
  `{:ok, applied_state}`.
  """
  @spec apply_config(GenServer.server(), map()) ::
          {:ok, desired_state()} | {:ok, :unchanged} | {:error, term()}
  def apply_config(server \\ __MODULE__, config) when is_map(config) do
    try do
      GenServer.call(server, {:apply_config, config})
    catch
      :exit, _reason -> {:error, :wifi_manager_unavailable}
    end
  end

  @doc "Validate the public, nonsecret Desired State v1 Wi-Fi section."
  @spec validate_desired_config(term()) :: {:ok, public_desired_state()} | {:error, term()}
  def validate_desired_config(%{} = config) do
    with {:ok, _section} <- Section.build(:wifi, config),
         version when is_integer(version) <- fetch(config, :version, "version"),
         enabled when is_boolean(enabled) <- fetch(config, :enabled, "enabled"),
         ssid <- fetch(config, :ssid, "ssid"),
         :ok <- validate_desired_ssid(enabled, ssid) do
      {:ok, %{version: version, enabled: enabled, ssid: ssid}}
    else
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_wifi_content}
    end
  end

  def validate_desired_config(_config), do: {:error, :invalid_wifi_content}

  @doc """
  Trial a public Desired State Wi-Fi candidate with a transient credential.

  The candidate becomes authoritative only after bounded authenticated
  confirmation and an atomic owner-store write containing `activation_id`.
  """
  @spec trial_config(GenServer.server(), map(), Secret.t() | nil, binary()) ::
          {:ok, public_desired_state()} | {:error, term()}
  def trial_config(server \\ __MODULE__, config, secret, activation_id) do
    try do
      GenServer.call(server, {:trial_config, config, secret, activation_id}, :infinity)
    catch
      :exit, _reason -> {:error, :wifi_manager_unavailable}
    end
  end

  @doc "Atomically mark an explicit Wi-Fi tombstone without retaining or logging a secret."
  @spec apply_desired_tombstone(GenServer.server(), binary()) :: :ok | {:error, term()}
  def apply_desired_tombstone(server \\ __MODULE__, activation_id) do
    GenServer.call(server, {:apply_desired_tombstone, activation_id})
  end

  @doc "Re-read and reconcile the exact durable Desired State activation marker."
  @spec reconcile_desired_activation(GenServer.server(), binary()) :: :ok | {:error, term()}
  def reconcile_desired_activation(server \\ __MODULE__, activation_id) do
    GenServer.call(server, {:reconcile_desired_activation, activation_id}, :infinity)
  end

  @doc "Return the nonsecret Desired State activation marker committed by the Wi-Fi owner."
  @spec desired_activation_id(GenServer.server()) :: binary() | nil
  def desired_activation_id(server \\ __MODULE__) do
    GenServer.call(server, :desired_activation_id)
  end

  @doc "Best-effort current `wlan0` status, read via the injected `status_fun`."
  @spec current_status(GenServer.server()) :: map()
  def current_status(server \\ __MODULE__) do
    GenServer.call(server, :current_status)
  end

  # --- Server ---

  @impl true
  def init(opts) do
    state = %{
      store_dir: Keyword.get(opts, :store_dir, @default_store_dir),
      configure_fun: Keyword.get(opts, :configure_fun, &default_configure/3),
      deconfigure_fun: Keyword.get(opts, :deconfigure_fun, &default_deconfigure/1),
      reset_to_defaults_fun: Keyword.get(opts, :reset_to_defaults_fun, &default_reset_to_defaults/1),
      rfkill_block_fun: Keyword.get(opts, :rfkill_block_fun, &default_rfkill_block/0),
      rfkill_unblock_fun: Keyword.get(opts, :rfkill_unblock_fun, &default_rfkill_unblock/0),
      status_fun: Keyword.get(opts, :status_fun, &default_status/0),
      subscribe_fun: Keyword.get(opts, :subscribe_fun, &default_subscribe/1),
      confirm_fun: Keyword.get(opts, :confirm_fun, &confirmation_unavailable/0),
      trial_timeout: Keyword.get(opts, :trial_timeout, 15_000),
      authority_load_fun: Keyword.get(opts, :authority_load_fun, &Store.read_authority/1),
      store_save_fun: Keyword.get(opts, :store_save_fun, &Store.save/2),
      store_clear_fun: Keyword.get(opts, :store_clear_fun, &Store.clear/1),
      credential_load_fun: Keyword.get(opts, :credential_load_fun, &Store.credential/2),
      credential_save_fun: Keyword.get(opts, :credential_save_fun, &Store.put_credential/3),
      credential_retain_fun: Keyword.get(opts, :credential_retain_fun, &Store.retain_credential/2),
      compile_default: Keyword.get(opts, :compile_default, false),
      status_subscriber: Keyword.get(opts, :status_subscriber),
      # The version of the desired state currently applied; -1 means "nothing
      # applied yet", so any incoming version (>= 0) is newer.
      applied_version: -1,
      desired_activation_id: nil
    }

    {:ok, state, {:continue, :reconcile}}
  end

  # Boot reconciliation: persisted state wins; otherwise the compile default.
  @impl true
  def handle_continue(:reconcile, state) do
    _ = state.subscribe_fun.(@connection_property)
    {:noreply, reconcile(state)}
  end

  @impl true
  def handle_call({:apply_config, config}, _from, state) do
    {result, state} = do_apply(normalize(config), state)
    {:reply, result, state}
  end

  def handle_call({:trial_config, config, secret, activation_id}, _from, state) do
    {result, state} = do_trial(config, secret, activation_id, state)
    {:reply, result, state}
  end

  def handle_call({:apply_desired_tombstone, activation_id}, _from, state) do
    {result, state} = do_desired_tombstone(activation_id, state)
    {:reply, result, state}
  end

  def handle_call({:reconcile_desired_activation, activation_id}, _from, state) do
    {result, state} = do_reconcile_desired_activation(activation_id, state)
    {:reply, result, state}
  end

  def handle_call(:desired_activation_id, _from, state) do
    {:reply, state.desired_activation_id, state}
  end

  def handle_call(:current_status, _from, state) do
    {:reply, read_status(state), state}
  end

  # VintageNet property-change notifications (subscribed in handle_continue). For
  # J4 we just forward a status push to an optional registered subscriber; J5 will
  # use this to push status over the WSS channel.
  @impl true
  def handle_info({VintageNet, _property, _old, _new, _meta}, state) do
    notify_status(state)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Everything OTP can print about this process on a crash goes through here: the
  # state, the message being handled, the exit reason, and the recent-message log.
  # A `Secret` redacts itself under `inspect`, but a crash report is formatted with
  # `~p`, which ignores the Inspect protocol and would print the raw bytes — and a
  # legacy record's inline `:psk` is plain string in any formatter. So scrub the
  # credential material structurally rather than relying on how it gets printed.
  @impl true
  def format_status(status), do: Secret.redact(status)

  @impl true
  def terminate(_reason, _state) do
    # Nothing to flush: no credential is ever retained in state, and the durable
    # marker/sidecar were committed at the point of the trial. Defined explicitly so
    # a stray state value can never reach a shutdown log by default.
    :ok
  end

  # --- Reconcile / apply pipeline ---

  defp reconcile(state) do
    case Store.cleanup_temporary_artifacts(state.store_dir) do
      :ok -> reconcile_durable_authority(state)
      {:error, _reason} -> fail_boot_reconcile(state, "temporary artifact cleanup failed")
    end
  end

  defp reconcile_durable_authority(state) do
    case reread_authority(state) do
      {:ok, %{desired_tombstone: true} = desired} ->
        Logger.info("[WiFiManager] reconciling persisted desired-state tombstone")
        finish_boot_reconcile(desired, reconcile_authoritative_record(desired, state))

      {:ok, desired} ->
        Logger.info("[WiFiManager] reconciling persisted desired state (enabled=#{desired.enabled})")
        finish_boot_reconcile(desired, reconcile_authoritative_record(desired, state))

      :empty ->
        reconcile_empty_authority(state)

      {:error, _reason} ->
        fail_boot_reconcile(state, "owner authority is unreadable")
    end
  end

  defp reconcile_empty_authority(state) do
    case clear_reconnect_credential(state) do
      :ok -> reconcile_compile_default(state)
      {:error, _reason} -> fail_boot_reconcile(state, "orphan credential cleanup failed")
    end
  end

  defp fail_boot_reconcile(state, reason) do
    Logger.warning("[WiFiManager] #{reason}; leaving wlan0 unchanged")
    %{state | desired_activation_id: nil}
  end

  defp finish_boot_reconcile(desired, {:ok, state}) do
    %{state | desired_activation_id: Map.get(desired, :desired_activation_id)}
  end

  # Preserve the legacy boot behavior for a secretless marker whose sidecar has been
  # lost: do not touch the radio, but retain the marker identity for diagnostics. A
  # strict Desired State reconciliation still rejects it as incomplete.
  defp finish_boot_reconcile(desired, {:error, :wifi_credential_missing, state}) do
    %{state | desired_activation_id: Map.get(desired, :desired_activation_id)}
  end

  defp finish_boot_reconcile(_desired, {:error, _reason, state}), do: state

  defp do_reconcile_desired_activation(activation_id, state) do
    with :ok <- validate_activation_id(activation_id) do
      case reread_authority(state) do
        {:ok, record} -> reconcile_expected_authority(record, activation_id, state)
        :empty -> {{:error, :wifi_activation_mismatch}, %{state | desired_activation_id: nil}}
        {:error, _reason} -> indeterminate_authority(state)
      end
    else
      {:error, _reason} = error -> {error, state}
    end
  end

  defp reconcile_expected_authority(record, activation_id, state) do
    case reconcile_authoritative_record(record, state) do
      {:ok, state} ->
        actual_activation_id = Map.get(record, :desired_activation_id)
        state = %{state | desired_activation_id: actual_activation_id}

        if actual_activation_id == activation_id,
          do: {:ok, state},
          else: {{:error, :wifi_activation_mismatch}, state}

      {:error, {:credential_cleanup_failed, _reason}, state} ->
        indeterminate_authority(state)

      {:error, :wifi_authority_indeterminate, state} ->
        indeterminate_authority(state)

      {:error, reason, state} ->
        {{:error, reason}, state}
    end
  end

  defp indeterminate_authority(state) do
    {{:error, :wifi_authority_indeterminate}, %{state | desired_activation_id: nil}}
  end

  defp reconcile_authoritative_record(%{desired_tombstone: true} = desired, state) do
    disabled = tombstone_runtime_record(desired)

    case apply_desired(disabled, state) do
      {:ok, state} ->
        case clear_reconnect_credential(state) do
          :ok -> {:ok, state}
          {:error, reason} -> {:error, {:credential_cleanup_failed, reason}, state}
        end

      {{:error, reason}, state} ->
        {:error, reason, state}
    end
  end

  # A secretless owner marker keeps its credential in the store's sidecar; rejoin it
  # only while applying so the manager never retains plaintext credential material.
  defp reconcile_authoritative_record(desired, state) do
    case resolve_reconnect_credential(desired, state) do
      {:ok, resolved} ->
        case apply_desired(resolved, state) do
          {:ok, state} -> finalize_authoritative_credential(desired, state)
          {{:error, reason}, state} -> {:error, reason, state}
        end

      :missing_credential ->
        Logger.info("[WiFiManager] persisted desired state has no reconnect credential; not applying")
        {:error, :wifi_credential_missing, state}

      {:error, _reason} ->
        {:error, :wifi_authority_indeterminate, state}
    end
  end

  defp tombstone_runtime_record(desired) do
    %{version: Map.fetch!(desired, :version), enabled: false, ssid: nil}
  end

  defp finalize_authoritative_credential(%{enabled: true} = marker, state) do
    result =
      if Map.has_key?(marker, :psk) do
        clear_reconnect_credential(state)
      else
        retain_reconnect_credential(marker, state)
      end

    case result do
      :ok -> {:ok, state}
      {:error, reason} -> {:error, {:credential_cleanup_failed, reason}, state}
    end
  end

  defp finalize_authoritative_credential(_marker, state) do
    case clear_reconnect_credential(state) do
      :ok -> {:ok, state}
      {:error, reason} -> {:error, {:credential_cleanup_failed, reason}, state}
    end
  end

  defp retain_reconnect_credential(marker, state) do
    state.credential_retain_fun.(state.store_dir, credential_binding(marker))
    |> normalize_credential_result()
  rescue
    _error -> {:error, :credential_cleanup_failed}
  catch
    _kind, _reason -> {:error, :credential_cleanup_failed}
  end

  defp clear_reconnect_credential(state) do
    state.credential_save_fun.(state.store_dir, nil, %{})
    |> normalize_credential_result()
  rescue
    _error -> {:error, :credential_cleanup_failed}
  catch
    _kind, _reason -> {:error, :credential_cleanup_failed}
  end

  # An `enabled: false` marker and a legacy inline-`:psk` marker are already
  # self-sufficient; only a secretless enable needs the sidecar.
  defp resolve_reconnect_credential(%{enabled: true} = desired, state) do
    if Map.has_key?(desired, :psk) do
      {:ok, desired}
    else
      case load_credential(desired, state) do
        {:ok, secret} -> {:ok, Map.put(desired, :psk, Secret.unwrap(secret))}
        :empty -> :missing_credential
        {:error, _reason} = error -> error
      end
    end
  end

  defp resolve_reconnect_credential(desired, _state), do: {:ok, desired}

  defp load_credential(desired, state) do
    state.credential_load_fun.(state.store_dir, credential_binding(desired))
  rescue
    _error -> {:error, :credential_read_failed}
  catch
    _kind, _reason -> {:error, :credential_read_failed}
  end

  defp credential_binding(%{} = record) do
    %{
      ssid: Map.get(record, :ssid),
      desired_activation_id: Map.get(record, :desired_activation_id)
    }
  end

  # No runtime state has ever been set: honor the compile-time default.
  #   false → power the radio down at boot (mirrors the old WiFiPower behaviour).
  #   true  → leave the target.exs-configured wlan0 as-is; do not reconfigure.
  defp reconcile_compile_default(%{compile_default: false} = state) do
    Logger.info("[WiFiManager] no persisted state, compile default disabled → rfkill block")
    run(state.rfkill_block_fun, "rfkill-block")
    state
  end

  defp reconcile_compile_default(%{compile_default: true} = state) do
    Logger.info("[WiFiManager] no persisted state, compile default enabled → leaving wlan0 as configured")
    state
  end

  # Enabling requires an SSID; do not half-apply.
  defp do_apply(%{enabled: true, ssid: ssid}, state) when ssid in [nil, ""] do
    {{:error, :ssid_required}, state}
  end

  defp do_apply(%{} = desired, state) do
    case load_owner_record(state) do
      {:ok, previous} ->
        apply_legacy_against_owner(desired, previous, state)

      {:error, :wifi_authority_indeterminate} ->
        supersede_unreadable_legacy_authority(desired, state)
    end
  end

  defp apply_legacy_against_owner(desired, previous, state) do
    if stale_legacy_version?(desired, previous) do
      finalize_unchanged_legacy_owner(previous, state)
    else
      with {:ok, restore} <- restore_point(previous, state) do
        case apply_desired(desired, state) do
          {:ok, applied_state} ->
            commit_legacy_apply(persistable(desired), restore, applied_state)

          {{:error, _reason} = error, _unchanged_state} ->
            rollback_trial(error, restore, state)
        end
      else
        {:error, :wifi_authority_indeterminate} -> indeterminate_authority(state)
        {:error, _reason} = error -> {error, state}
      end
    end
  end

  defp stale_legacy_version?(%{version: version}, %{version: owner_version}) do
    version <= owner_version
  end

  defp stale_legacy_version?(_desired, :empty), do: false

  defp finalize_unchanged_legacy_owner(previous, state) do
    case finalize_authoritative_credential(previous, state) do
      {:ok, state} ->
        state = %{
          state
          | applied_version: previous.version,
            desired_activation_id: Map.get(previous, :desired_activation_id)
        }

        {{:ok, :unchanged}, state}

      {:error, _reason, state} ->
        indeterminate_authority(state)
    end
  end

  # A complete authenticated legacy command is allowed to supersede corrupt owner
  # bytes. First establish an exact empty authority and radio baseline; only then
  # apply the replacement so any later failure can roll back without guessing.
  defp supersede_unreadable_legacy_authority(desired, state) do
    case restore_owner(%{record: :empty}, state) do
      {:ok, empty_state} -> apply_legacy_against_owner(desired, :empty, empty_state)
      {{:error, _reason}, state} -> indeterminate_authority(state)
    end
  end

  defp commit_legacy_apply(persisted, restore, state) do
    case save_marker(persisted, state) do
      :ok ->
        case finalize_authoritative_credential(persisted, state) do
          {:ok, state} ->
            {{:ok, persisted}, %{state | applied_version: persisted.version, desired_activation_id: nil}}

          {:error, _reason, state} ->
            indeterminate_authority(state)
        end

      {:error, {:not_committed, reason}} ->
        rollback_trial({:error, {:persistence_failed, reason}}, restore, state)

      {:error, :wifi_authority_indeterminate} ->
        rollback_trial({:error, :wifi_authority_indeterminate}, restore, state)
    end
  end

  defp do_desired_tombstone(activation_id, state) do
    with :ok <- validate_activation_id(activation_id),
         {:ok, previous} <- load_owner_record(state),
         {:ok, restore} <- restore_point(previous, state) do
      marker =
        previous
        |> tombstone_record()
        |> Map.put(:desired_activation_id, activation_id)

      case apply_desired(tombstone_runtime_record(marker), state) do
        {:ok, disabled_state} ->
          commit_tombstone(marker, restore, disabled_state)

        {{:error, _reason} = error, _state} ->
          rollback_trial(error, restore, state)
      end
    else
      {:error, :wifi_authority_indeterminate} -> indeterminate_authority(state)
      {:error, _reason} = error -> {error, state}
    end
  rescue
    _error -> {{:error, :persistence_failed}, state}
  catch
    _kind, _reason -> {{:error, :persistence_failed}, state}
  end

  defp commit_tombstone(marker, restore, state) do
    case save_marker(marker, state) do
      :ok ->
        case clear_reconnect_credential(state) do
          :ok ->
            {:ok,
             %{
               state
               | desired_activation_id: marker.desired_activation_id,
                 applied_version: marker.version
             }}

          {:error, _reason} ->
            indeterminate_authority(state)
        end

      {:error, {:not_committed, reason}} ->
        rollback_trial({:error, {:persistence_failed, reason}}, restore, state)

      {:error, :wifi_authority_indeterminate} ->
        indeterminate_authority(state)
    end
  end

  defp tombstone_record(%{version: version}) do
    %{version: version, enabled: false, ssid: nil, desired_tombstone: true}
  end

  defp tombstone_record(:empty) do
    %{version: -1, enabled: false, ssid: nil, desired_tombstone: true}
  end

  defp do_trial(config, secret, activation_id, state) do
    with {:ok, public} <- validate_desired_config(config),
         :ok <- validate_activation_id(activation_id),
         {:ok, psk} <- validate_trial_secret(public, secret),
         {:ok, previous} <- load_owner_record(state),
         # Captured BEFORE the sidecar is overwritten, so a rollback can put the
         # prior marker's reconnect credential back exactly as it was.
         {:ok, restore} <- restore_point(previous, state) do
      candidate = Map.put(public, :psk, psk)

      case apply_desired(candidate, state) do
        {:ok, trial_state} ->
          finish_trial(public, candidate, activation_id, restore, trial_state)

        {{:error, _reason} = error, _unchanged_state} ->
          rollback_trial(error, restore, state)
      end
    else
      {:error, :wifi_authority_indeterminate} -> indeterminate_authority(state)
      {:error, _reason} = error -> {error, state}
    end
  end

  # The prior owner record plus whatever sidecar credential belonged to it. Held
  # only for the duration of the trial call, never in manager state. Disabled and
  # inline-PSK legacy records are self-sufficient, so unrelated sidecar corruption
  # must not block their replacement.
  defp restore_point(%{enabled: false} = previous, _state) do
    {:ok, %{record: previous, credential: nil}}
  end

  defp restore_point(%{} = previous, _state) when is_map_key(previous, :psk) do
    {:ok, %{record: previous, credential: nil}}
  end

  defp restore_point(%{} = previous, state) do
    case load_credential(previous, state) do
      {:ok, secret} -> {:ok, %{record: previous, credential: secret}}
      :empty -> {:ok, %{record: previous, credential: nil}}
      {:error, _reason} -> {:error, :wifi_authority_indeterminate}
    end
  end

  defp restore_point(:empty, _state), do: {:ok, %{record: :empty, credential: nil}}

  defp finish_trial(public, candidate, activation_id, previous, state) do
    case await_authenticated_confirmation(
           state.confirm_fun,
           activation_id,
           public,
           state.trial_timeout
         ) do
      :ok ->
        commit_trial(public, candidate, activation_id, previous, state)

      {:error, _reason} = error ->
        rollback_trial(error, previous, state)
    end
  rescue
    _error -> rollback_trial({:error, :persistence_failed}, previous, state)
  catch
    _kind, _reason -> rollback_trial({:error, :persistence_failed}, previous, state)
  end

  # The committed owner marker is SECRETLESS: `public` plus the activation id, and
  # nothing else. The credential goes to the store's sidecar FIRST, so a crash
  # between the two writes can only ever leave an orphan credential (inert, because
  # it is bound to a marker that was never committed) rather than a committed marker
  # the device cannot reconnect with.
  defp commit_trial(public, candidate, activation_id, previous, state) do
    marker = Map.put(public, :desired_activation_id, activation_id)

    case save_credential(candidate, marker, state) do
      :ok ->
        marker
        |> save_marker(state)
        |> case do
          :ok ->
            case finalize_authoritative_credential(marker, state) do
              {:ok, state} ->
                {{:ok, public},
                 %{
                   state
                   | desired_activation_id: activation_id,
                     applied_version: public.version
                 }}

              {:error, _reason, state} ->
                indeterminate_authority(state)
            end

          {:error, {:not_committed, reason}} ->
            rollback_trial({:error, {:persistence_failed, reason}}, previous, state)

          {:error, :wifi_authority_indeterminate} ->
            indeterminate_authority(state)
        end

      {:error, reason} ->
        rollback_trial({:error, {:persistence_failed, reason}}, previous, state)
    end
  end

  # Resolve an ambiguous marker write. A writer that fails AFTER its durable commit
  # (torn ack, fsync racing a power cut, an injected fault past the rename) reports
  # an error for an operation that actually succeeded. Rereading the strict durable
  # authority disambiguates three outcomes: exact commit, known non-commit, or an
  # unreadable authority where guessing would risk disk/radio divergence.
  defp save_marker(marker, state) do
    case safely_save_marker(marker, state) do
      :ok ->
        :ok

      {:error, {:durability_uncertain, _reason}} ->
        {:error, :wifi_authority_indeterminate}

      {:error, reason} ->
        confirm_durable_marker(marker, reason, state)

      other ->
        confirm_durable_marker(marker, other, state)
    end
  end

  defp safely_save_marker(marker, state) do
    state.store_save_fun.(state.store_dir, marker)
  rescue
    _error -> {:error, :marker_write_failed}
  catch
    _kind, _reason -> {:error, :marker_write_failed}
  end

  defp confirm_durable_marker(marker, reason, state) do
    case reread_authority(state) do
      {:ok, ^marker} ->
        Logger.info("[WiFiManager] owner-marker write reported failure; durable authority matches")
        :ok

      {:ok, _other_marker} ->
        {:error, {:not_committed, reason}}

      :empty ->
        {:error, {:not_committed, reason}}

      {:error, _authority_reason} ->
        {:error, :wifi_authority_indeterminate}
    end
  end

  defp reread_authority(state) do
    case state.authority_load_fun.(state.store_dir) do
      {:ok, %{} = record} -> {:ok, record}
      :empty -> :empty
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_authority_response}
    end
  rescue
    _error -> {:error, :authority_read_failed}
  catch
    _kind, _reason -> {:error, :authority_read_failed}
  end

  defp save_credential(%{psk: psk}, marker, state) when is_binary(psk) and psk != "" do
    normalize_credential_result(
      state.credential_save_fun.(state.store_dir, Secret.new(psk), credential_binding(marker))
    )
  end

  # A disabled candidate has no credential to stage. Keep prior choices until the
  # owner marker is known; an ambiguous write may still resolve back to that prior.
  defp save_credential(_candidate, _marker, _state), do: :ok

  defp normalize_credential_result(:ok), do: :ok
  defp normalize_credential_result({:error, reason}), do: {:error, reason}
  defp normalize_credential_result(other), do: {:error, other}

  defp rollback_trial(error, restore, state) do
    case restore_owner(restore, state) do
      {:ok, state} -> {error, state}
      {{:error, _reason}, state} -> indeterminate_authority(state)
    end
  end

  defp restore_owner(%{record: %{} = previous, credential: credential}, state) do
    if missing_secretless_credential?(previous, credential) do
      disable_unrestorable_owner(previous, state)
    else
      restore_reconnectable_owner(previous, credential, state)
    end
  end

  defp restore_owner(%{record: :empty}, state) do
    with :ok <- clear_owner_authority(state),
         :ok <- clear_reconnect_credential(state) do
      restore_compile_default(state)
    else
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp restore_compile_default(%{compile_default: true} = state) do
    with :ok <-
           call_effect(
             state.reset_to_defaults_fun,
             ["wlan0"],
             :reset_to_defaults_failed
           ),
         :ok <- call_effect(state.rfkill_unblock_fun, [], :rfkill_unblock_failed) do
      {:ok, %{state | desired_activation_id: nil, applied_version: -1}}
    else
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp restore_compile_default(state) do
    fallback = %{version: -1, enabled: false, ssid: nil, psk: nil}

    case apply_desired(fallback, state) do
      {:ok, state} -> {:ok, %{state | desired_activation_id: nil, applied_version: -1}}
      {{:error, reason}, state} -> {{:error, reason}, state}
    end
  end

  defp restore_reconnectable_owner(previous, credential, state) do
    # Put the prior credential back before its marker, preserving the invariant that
    # every committed secretless enable already has a reconnectable sidecar.
    with :ok <- restore_credential(previous, credential, state),
         :ok <- restore_marker(previous, state) do
      case previous |> restore_config(credential) |> apply_desired(state) do
        {:ok, state} ->
          case finalize_authoritative_credential(previous, state) do
            {:ok, state} ->
              {:ok,
               %{
                 state
                 | desired_activation_id: Map.get(previous, :desired_activation_id),
                   applied_version: previous.version
               }}

            {:error, reason, state} ->
              {{:error, reason}, state}
          end

        {{:error, reason}, state} ->
          {{:error, reason}, state}
      end
    else
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp disable_unrestorable_owner(previous, state) do
    with :ok <- restore_marker(previous, state),
         :ok <- clear_reconnect_credential(state) do
      disabled = %{version: previous.version, enabled: false, ssid: nil}

      case apply_desired(disabled, state) do
        {:ok, state} -> {{:error, :wifi_credential_missing}, state}
        {{:error, reason}, state} -> {{:error, reason}, state}
      end
    else
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp missing_secretless_credential?(%{enabled: true} = previous, nil) do
    not Map.has_key?(previous, :psk)
  end

  defp missing_secretless_credential?(_previous, _credential), do: false

  defp restore_marker(previous, state) do
    case save_marker(previous, state) do
      :ok -> :ok
      {:error, {:not_committed, reason}} -> {:error, {:rollback_persistence_failed, reason}}
      {:error, :wifi_authority_indeterminate} -> {:error, :wifi_authority_indeterminate}
    end
  end

  defp clear_owner_authority(state) do
    case safely_clear_owner_authority(state) do
      :ok ->
        :ok

      {:error, reason} ->
        confirm_cleared_owner_authority(reason, state)

      other ->
        confirm_cleared_owner_authority(other, state)
    end
  end

  defp safely_clear_owner_authority(state) do
    state.store_clear_fun.(state.store_dir)
  rescue
    _error -> {:error, :owner_clear_failed}
  catch
    _kind, _reason -> {:error, :owner_clear_failed}
  end

  defp confirm_cleared_owner_authority(reason, state) do
    case reread_authority(state) do
      :empty -> :ok
      {:ok, _record} -> {:error, {:rollback_persistence_failed, reason}}
      {:error, _authority_reason} -> {:error, :wifi_authority_indeterminate}
    end
  end

  # A legacy record carries its own inline `:psk`; a secretless one is rejoined with
  # its sidecar credential just for this apply.
  defp restore_config(%{} = previous, nil), do: previous

  defp restore_config(%{} = previous, credential) do
    if Map.has_key?(previous, :psk) do
      previous
    else
      Map.put(previous, :psk, Secret.unwrap(credential))
    end
  end

  defp restore_credential(previous, nil, state) do
    safely_save_reconnect_credential(nil, credential_binding(previous), state)
  end

  defp restore_credential(previous, credential, state) do
    safely_save_reconnect_credential(credential, credential_binding(previous), state)
  end

  defp safely_save_reconnect_credential(credential, binding, state) do
    state.credential_save_fun.(state.store_dir, credential, binding)
    |> normalize_credential_result()
  rescue
    _error -> {:error, :credential_write_failed}
  catch
    _kind, _reason -> {:error, :credential_write_failed}
  end

  defp load_owner_record(state) do
    case reread_authority(state) do
      {:ok, %{} = record} -> {:ok, record}
      :empty -> {:ok, :empty}
      {:error, _reason} -> {:error, :wifi_authority_indeterminate}
    end
  end

  defp await_authenticated_confirmation(fun, activation_id, public, timeout)
       when is_function(fun) and is_integer(timeout) and timeout >= 0 do
    task =
      Task.async(fn ->
        safely_confirm(fun, activation_id, public)
      end)

    case Task.yield(task, timeout) do
      {:ok, result} ->
        normalize_confirmation(result)

      {:exit, _reason} ->
        {:error, :confirmation_failed}

      nil ->
        _ = Task.shutdown(task, :brutal_kill)
        {:error, :confirmation_timeout}
    end
  end

  defp await_authenticated_confirmation(_fun, _activation_id, _public, _timeout),
    do: {:error, :confirmation_unavailable}

  defp safely_confirm(fun, activation_id, public) do
    cond do
      is_function(fun, 2) -> fun.(activation_id, public)
      is_function(fun, 1) -> fun.(activation_id)
      is_function(fun, 0) -> fun.()
      true -> {:error, :confirmation_unavailable}
    end
  rescue
    _error -> {:error, :confirmation_failed}
  catch
    _kind, _reason -> {:error, :confirmation_failed}
  end

  defp normalize_confirmation(:ok), do: :ok
  defp normalize_confirmation({:ok, _authenticated}), do: :ok
  defp normalize_confirmation({:error, reason}), do: {:error, reason}
  defp normalize_confirmation(_other), do: {:error, :confirmation_rejected}

  defp validate_activation_id(activation_id)
       when is_binary(activation_id) and byte_size(activation_id) == 32,
       do: :ok

  defp validate_activation_id(_activation_id), do: {:error, :invalid_activation_id}

  defp validate_trial_secret(%{enabled: true}, %Secret{} = secret) do
    case Secret.unwrap(secret) do
      bytes when is_binary(bytes) and bytes != "" -> {:ok, bytes}
      _other -> {:error, :wifi_secret_required}
    end
  end

  defp validate_trial_secret(%{enabled: true}, _secret), do: {:error, :wifi_secret_required}
  defp validate_trial_secret(%{enabled: false}, _secret), do: {:ok, nil}

  # Perform the side effects for a desired state. Returns {:ok | {:error, reason}, state}.
  defp apply_desired(%{enabled: true, ssid: ssid} = desired, state) when ssid not in [nil, ""] do
    config = wifi_client_config(ssid, desired.psk)

    with :ok <- call_effect(state.configure_fun, ["wlan0", config, [persist: false]], :configure_failed),
         :ok <- call_effect(state.rfkill_unblock_fun, [], :rfkill_unblock_failed) do
      {:ok, %{state | applied_version: desired.version}}
    else
      {:error, _reason} = error -> {error, state}
    end
  end

  defp apply_desired(%{enabled: true}, state) do
    {{:error, :ssid_required}, state}
  end

  defp apply_desired(%{enabled: false} = desired, state) do
    with :ok <- call_effect(state.deconfigure_fun, ["wlan0"], :deconfigure_failed),
         :ok <- call_effect(state.rfkill_block_fun, [], :rfkill_block_failed) do
      {:ok, %{state | applied_version: desired.version}}
    else
      {:error, _reason} = error -> {error, state}
    end
  end

  defp call_effect(fun, args, failure) do
    case apply(fun, args) do
      {:error, _reason} -> {:error, failure}
      _other -> :ok
    end
  rescue
    _error -> {:error, failure}
  catch
    _kind, _reason -> {:error, failure}
  end

  # --- Status ---

  defp read_status(state) do
    state.status_fun.()
  rescue
    error ->
      Logger.warning("[WiFiManager] status read failed: #{inspect(error)}")
      %{enabled: false, ssid: nil, connection: :disconnected, signal: nil}
  end

  defp notify_status(%{status_subscriber: nil}), do: :ok

  defp notify_status(%{status_subscriber: pid} = state) do
    send(pid, {:wifi_status, read_status(state)})
    :ok
  end

  # --- Normalization ---

  defp validate_desired_ssid(true, ssid) when is_binary(ssid) and ssid != "", do: :ok
  defp validate_desired_ssid(true, _ssid), do: {:error, :ssid_required}
  defp validate_desired_ssid(false, ssid) when is_binary(ssid) or is_nil(ssid), do: :ok
  defp validate_desired_ssid(false, _ssid), do: {:error, :invalid_wifi_content}

  # Accept string OR atom keys; coerce to a canonical map with the keys we use.
  defp normalize(config) do
    %{
      version: fetch(config, :version, "version") |> to_version(),
      enabled: fetch(config, :enabled, "enabled") |> to_bool(),
      ssid: fetch(config, :ssid, "ssid"),
      psk: fetch(config, :psk, "psk")
    }
  end

  defp persistable(%{version: v, enabled: e, ssid: ssid, psk: psk}) do
    %{version: v, enabled: e, ssid: ssid, psk: psk}
  end

  defp fetch(map, atom_key, string_key) do
    case Map.fetch(map, atom_key) do
      {:ok, value} -> value
      :error -> Map.get(map, string_key)
    end
  end

  defp to_version(v) when is_integer(v), do: v
  defp to_version(v) when is_binary(v), do: String.to_integer(v)
  defp to_version(nil), do: 0

  defp to_bool(true), do: true
  defp to_bool(false), do: false
  defp to_bool("true"), do: true
  defp to_bool("false"), do: false
  defp to_bool(nil), do: false

  # --- VintageNet config shape ---

  @doc """
  The `wlan0` VintageNet client config for a WPA-PSK network — same shape as
  `config/target.exs` builds for a baked-in network.
  """
  @spec wifi_client_config(String.t(), String.t() | nil) :: map()
  def wifi_client_config(ssid, psk) do
    %{
      type: VintageNetWiFi,
      vintage_net_wifi: %{
        networks: [%{key_mgmt: :wpa_psk, ssid: ssid, psk: psk}]
      },
      ipv4: %{method: :dhcp}
    }
  end

  # --- Best-effort wrapper ---

  defp run(fun, label) do
    fun.()
  rescue
    e -> Logger.warning("[WiFiManager] #{label} step failed: #{inspect(e)}")
  end

  # --- Real-target defaults (never invoked on host/test) ---
  #
  # `VintageNet` is a target-only dependency (not compiled on host/test), so these
  # defaults reach it via `apply/3`: the compiler never resolves the module on host
  # (no "undefined" warnings), and they only ever run on a real device where
  # VintageNet is present. The WiFiManager itself is never started on host/test.

  defp confirmation_unavailable, do: {:error, :confirmation_unavailable}

  defp default_configure(iface, config, opts),
    do: apply(VintageNet, :configure, [iface, config, opts])

  defp default_deconfigure(iface), do: apply(VintageNet, :deconfigure, [iface])
  defp default_reset_to_defaults(iface), do: apply(VintageNet, :reset_to_defaults, [iface])
  defp default_rfkill_block, do: WiFiPower.block()
  defp default_rfkill_unblock, do: WiFiPower.unblock()
  defp default_subscribe(property), do: apply(VintageNet, :subscribe, [property])

  defp default_status do
    enabled = match?({:ok, _}, apply(VintageNet, :get_configuration, ["wlan0"]))
    connection = apply(VintageNet, :get, [@connection_property, :disconnected])
    ssid = apply(VintageNet, :get, [["interface", "wlan0", "wifi", "current_ap", :ssid]])
    signal = apply(VintageNet, :get, [["interface", "wlan0", "wifi", "current_ap", :signal_dbm]])

    %{enabled: enabled, ssid: ssid, connection: connection, signal: signal}
  end
end
