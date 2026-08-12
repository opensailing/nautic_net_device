defmodule RacingOrg.Tracker.Pro.Commands.Ledger.Provider do
  @moduledoc """
  The contract every durable command provider implements.

  ## Effect

  `execute/2` runs the command's external effect exactly once. It is invoked only
  after the intent is durable, so the provider may assume that a crash between
  admission and completion leaves a recoverable record.

  Returning `{:ok, result}` means the command reached a DETERMINATE outcome. A
  determinate failure is still `{:ok, %{outcome: :failed, ...}}` — the command
  was applied and its failure is the result. `{:error, reason}` is reserved for
  an effect that provably never started, which leaves the intent for recovery.

  ## Recovery

  `recover/2` runs when a restart finds this provider's intent pending. It must
  prove one of three things and never guess:

    * `{:applied, result}` — the effect provably happened; complete the intent.
    * `{:not_applied, proof}` — the effect provably did NOT happen, where proof
      is `:effect_not_started` or `:effect_verified_absent`; reject the intent.
    * `:ambiguous` — neither can be proven; the intent stays pending and no ACK
      is emitted.

  Elapsed time is never proof. Expiry is an admission fence only.

  ## Non-application lease

  `with_non_application_lease/5` is the `Commands.Ledger.Store` contract: invoke
  the supplied transition synchronously exactly once from the process owning the
  command-specific non-application lease, and hold that lease until the
  transition returns. Providers whose effects have no external ownership to hold
  may call the transition directly, which is what `use` generates.
  """

  alias RacingOrg.Tracker.Pro.Commands.Ledger.Snapshot

  @type intent :: Snapshot.intent()
  @type proof :: :effect_not_started | :effect_verified_absent

  @callback execute(intent(), term()) :: {:ok, term()} | {:error, term()}
  @callback recover(intent(), term()) :: {:applied, term()} | {:not_applied, proof()} | :ambiguous
  @callback with_non_application_lease(intent(), proof(), atom(), term(), (-> term())) :: term()

  @doc """
  Default provider scaffolding: the lease callback runs the transition inline.

  Correct ONLY for providers whose non-application proof is established before
  the lease is taken and cannot be invalidated concurrently — every effect in
  this registry is device-local and single-writer, so no external lease exists to
  hold. A provider owning a genuinely concurrent external resource must override
  `with_non_application_lease/5` and hold that resource across the transition.
  """
  defmacro __using__(_opts) do
    quote do
      @behaviour RacingOrg.Tracker.Pro.Commands.Ledger.Provider

      @impl true
      def with_non_application_lease(_intent, proof, reason, _context, transition)
          when proof in [:effect_not_started, :effect_verified_absent] and
                 reason == :operational_gate_closed do
        transition.()
      end

      def with_non_application_lease(_intent, _proof, _reason, _context, _transition),
        do: {:error, :effect_non_application_unverified}

      defoverridable with_non_application_lease: 5
    end
  end
end
