defmodule RacingOrg.Tracker.Pro.Commands.Ledger.Provider.ValidateFirmware do
  @moduledoc """
  Mark the running firmware valid on the owner's explicit instruction.

  Unlike the checkpoint commands this effect is IRREVERSIBLE: once Nerves records
  the running slot as validated, U-Boot will no longer revert it. Recovery
  therefore never re-runs the effect. It reads the firmware's own validation flag,
  which is the authoritative record of whether the effect landed:

    * already valid  -> `{:applied, ...}`. The flag is the effect's own receipt.
      It cannot distinguish "this command validated it" from "it was already
      valid", but both are the same terminal device state and the command's
      contract is `the running firmware is valid`, so completing is truthful.
    * not valid      -> `{:not_applied, :effect_verified_absent}`. The effect
      provably did not land, so the intent is rejected under the lease.
    * flag unreadable -> `:ambiguous`. The intent stays pending and no ACK is
      emitted rather than guessing about an irreversible effect.
  """

  use RacingOrg.Tracker.Pro.Commands.Ledger.Provider

  alias RacingOrg.Tracker.Pro.FirmwareValidator

  @impl true
  def execute(_intent, context) do
    case FirmwareValidator.validate_on_connect(validator_opts(context)) do
      :validated -> {:ok, %{outcome: :applied, detail: :validated}}
      :already_valid -> {:ok, %{outcome: :applied, detail: :already_valid}}
      :unavailable -> {:ok, %{outcome: :failed, detail: :unavailable}}
      :error -> {:ok, %{outcome: :failed, detail: :validation_failed}}
    end
  rescue
    _exception -> {:ok, %{outcome: :failed, detail: :validation_failed}}
  catch
    _kind, _reason -> {:ok, %{outcome: :failed, detail: :validation_failed}}
  end

  @impl true
  def recover(_intent, context) do
    case firmware_valid?(context) do
      {:ok, true} -> {:applied, %{outcome: :applied, detail: :already_valid}}
      {:ok, false} -> {:not_applied, :effect_verified_absent}
      :error -> :ambiguous
    end
  end

  defp firmware_valid?(context) do
    opts = validator_opts(context)

    if FirmwareValidator.validation_available?(opts) do
      {:ok, !!read_valid_flag(opts)}
    else
      :error
    end
  rescue
    _exception -> :error
  catch
    _kind, _reason -> :error
  end

  defp read_valid_flag(opts) do
    case Keyword.get(opts, :firmware_valid?) do
      fun when is_function(fun, 0) -> fun.()
      _default -> apply(Keyword.get(opts, :runtime_module, Nerves.Runtime), :firmware_valid?, [])
    end
  end

  defp validator_opts(context) when is_list(context), do: context
  defp validator_opts(%{validator_opts: opts}) when is_list(opts), do: opts
  defp validator_opts(_context), do: []
end
